//! Database — generic batched SQLite writer. A program, not a service.
//! Per-client request/ack queues with confirmed batch writes.
//! The driver polls all client queues directly — no mailbox, no fan-in.
//! Clients block on ack. At most one batch per client in flight.
//!
//! The stdlib provides the loop, batching, and shutdown flush.
//! On disconnect (all handles dropped), remaining entries are flushed
//! in a final transaction before the driver thread exits.
//!
//! Telemetry uses the gate pattern: the driver accumulates counters
//! (flush_count, total_rows, total_flush_ns) and checks a `can_emit`
//! gate after each flush. When the gate opens, it calls `emit` with the
//! accumulated values and resets. On disconnect, emits remainder
//! unconditionally. Both closures are optional — the database stays generic.

use std::thread;

use rusqlite::Connection;

use crate::services::queue::{self, QueueReceiver, QueueSender};

/// Handle to the database driver thread for lifecycle management.
///
/// No Drop impl — drop order is unspecified, so joining in Drop
/// would deadlock if senders are still alive. The cascade IS the
/// shutdown guarantee: senders drop → driver drains → driver exits.
/// Call join() explicitly when you need to wait for the final flush.
pub struct DatabaseDriverHandle {
    thread: Option<thread::JoinHandle<()>>,
}

impl DatabaseDriverHandle {
    /// Block until the driver thread exits. The driver exits when
    /// all senders are dropped and the final batch is flushed.
    pub fn join(mut self) {
        if let Some(h) = self.thread.take() {
            let _ = h.join();
        }
    }
}

/// A program's handle to the database. Each program gets its own.
/// Not cloneable — one per program.
pub struct DatabaseHandle<T> {
    req_tx: QueueSender<Vec<T>>,
    ack_rx: QueueReceiver<()>,
}

impl<T: Send> DatabaseHandle<T> {
    /// Confirmed batch send. Blocks until the driver has received the data.
    pub fn batch_send(&self, entries: Vec<T>) {
        if entries.is_empty() {
            return;
        }
        let _ = self.req_tx.send(entries);
        let _ = self.ack_rx.recv(); // block until ack
    }

    /// Convenience: send a single entry, confirmed.
    pub fn send(&self, entry: T) {
        self.batch_send(vec![entry]);
    }
}

/// Create a batched SQLite database writer.
///
/// - `path`: SQLite database file path.
/// - `num_clients`: number of client handles to create.
/// - `batch_size`: entries accumulated before a transaction commit.
/// - `setup`: called once with the connection. Create tables, indices, etc.
/// - `insert`: called per entry with the connection and the entry.
/// - `can_emit`: optional rate gate — `Fn() -> bool`. When provided with `emit`,
///   the driver accumulates flush stats and emits them through the closure when
///   the gate opens. On disconnect, emits remainder unconditionally.
/// - `emit`: optional emit closure — `Fn(flush_count, total_rows, total_flush_ns)`.
///   The kernel wraps `emit_metric` inside this. The database stays generic.
///
/// Returns (Vec<DatabaseHandle>, DatabaseDriverHandle).
/// Drop all handles to trigger shutdown — the driver flushes remaining entries and exits.
pub fn database<T: Send + 'static>(
    path: &str,
    num_clients: usize,
    batch_size: usize,
    setup: impl FnOnce(&Connection) + Send + 'static,
    insert: impl Fn(&Connection, &T) + Send + 'static,
    can_emit: Box<dyn Fn() -> bool + Send>,
    emit: Box<dyn Fn(&Connection, usize, usize, u64) + Send>,
) -> (Vec<DatabaseHandle<T>>, DatabaseDriverHandle) {
    assert!(batch_size > 0, "database requires non-zero batch_size");
    assert!(num_clients > 0, "database requires at least one client");

    let mut handles = Vec::with_capacity(num_clients);
    let mut req_rxs = Vec::with_capacity(num_clients);
    let mut ack_txs = Vec::with_capacity(num_clients);

    for _ in 0..num_clients {
        let (req_tx, req_rx) = queue::queue_unbounded::<Vec<T>>();
        let (ack_tx, ack_rx) = queue::queue_unbounded::<()>();
        req_rxs.push(req_rx);
        ack_txs.push(ack_tx);
        handles.push(DatabaseHandle { req_tx, ack_rx });
    }

    let path = path.to_string();

    let thread = thread::spawn(move || {
        let conn = Connection::open(&path).expect("database: failed to open connection");
        conn.pragma_update(None, "journal_mode", "WAL")
            .expect("database: failed to set WAL mode");

        setup(&conn);

        let mut pending: Vec<T> = Vec::with_capacity(batch_size);

        // Telemetry accumulators — reset after each emission.
        let mut flush_count: usize = 0;
        let mut total_rows: usize = 0;
        let mut total_flush_ns: u64 = 0;

        let mut closed = vec![false; num_clients];

        loop {
            // Block until at least one queue has data.
            let mut sel = crossbeam::channel::Select::new();
            let mut has_live = false;
            for i in 0..num_clients {
                sel.recv(req_rxs[i].inner());
                if !closed[i] {
                    has_live = true;
                }
            }
            if !has_live {
                // All clients disconnected — flush remainder and exit.
                if !pending.is_empty() {
                    let rows = pending.len();
                    let start = std::time::Instant::now();
                    flush(&conn, &pending, &insert);
                    let duration_ns = start.elapsed().as_nanos() as u64;
                    pending.clear();

                    flush_count += 1;
                    total_rows += rows;
                    total_flush_ns += duration_ns;
                }

                // Emit remainder unconditionally — no gate check.
                if flush_count > 0 || total_rows > 0 {
                    emit(&conn, flush_count, total_rows, total_flush_ns);
                }
                break;
            }
            let _ = sel.ready();

            // Drain all pending batches from all clients.
            for i in 0..num_clients {
                if closed[i] {
                    continue;
                }
                loop {
                    match req_rxs[i].try_recv() {
                        Ok(batch) => {
                            pending.extend(batch);
                            // Ack immediately — the driver has the data.
                            let _ = ack_txs[i].send(());
                        }
                        Err(crossbeam::channel::TryRecvError::Empty) => break,
                        Err(crossbeam::channel::TryRecvError::Disconnected) => {
                            closed[i] = true;
                            break;
                        }
                    }
                }
            }

            // Flush when we have enough.
            while pending.len() >= batch_size {
                let rows = batch_size.min(pending.len());
                let batch: Vec<T> = pending.drain(..rows).collect();
                let start = std::time::Instant::now();
                flush(&conn, &batch, &insert);
                let duration_ns = start.elapsed().as_nanos() as u64;

                flush_count += 1;
                total_rows += rows;
                total_flush_ns += duration_ns;

                // Gate check.
                if can_emit() {
                    emit(&conn, flush_count, total_rows, total_flush_ns);
                    flush_count = 0;
                    total_rows = 0;
                    total_flush_ns = 0;
                }
            }
        }
    });

    (
        handles,
        DatabaseDriverHandle {
            thread: Some(thread),
        },
    )
}

/// Flush a batch: BEGIN, insert each, COMMIT.
fn flush<T>(conn: &Connection, batch: &[T], insert: &impl Fn(&Connection, &T)) {
    conn.execute_batch("BEGIN").expect("database: BEGIN failed");
    for entry in batch {
        insert(conn, entry);
    }
    conn.execute_batch("COMMIT")
        .expect("database: COMMIT failed");
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Arc;
    use std::thread;

    fn temp_db_path() -> String {
        let dir = std::env::temp_dir();
        let name = format!("holon_test_{}.db", std::process::id());
        dir.join(name).to_string_lossy().into_owned()
    }

    fn cleanup(path: &str) {
        let _ = std::fs::remove_file(path);
        let _ = std::fs::remove_file(format!("{}-wal", path));
        let _ = std::fs::remove_file(format!("{}-shm", path));
    }

    #[test]
    fn setup_function_is_called() {
        let path = format!("{}_setup", temp_db_path());
        let path_clone = path.clone();

        let (handles, driver) = database::<String>(
            &path,
            1,
            10,
            |conn| {
                conn.execute(
                    "CREATE TABLE test_table (id INTEGER PRIMARY KEY, value TEXT)",
                    [],
                )
                .unwrap();
            },
            |_conn, _entry| {},
            Box::new(|| true),
            Box::new(|_, _, _, _| {}),
        );

        // Drop handles to trigger shutdown, then join.
        drop(handles);
        driver.join();

        // Verify the table exists via a second connection.
        let conn = Connection::open(&path_clone).unwrap();
        let exists: bool = conn
            .prepare("SELECT name FROM sqlite_master WHERE type='table' AND name='test_table'")
            .unwrap()
            .exists([])
            .unwrap();
        assert!(exists, "setup function should have created the table");

        cleanup(&path_clone);
    }

    #[test]
    fn insert_function_called_per_entry() {
        let path = format!("{}_insert", temp_db_path());
        let path_clone = path.clone();

        let (handles, driver) = database::<String>(
            &path,
            1,
            100, // large batch so it flushes on shutdown
            |conn| {
                conn.execute("CREATE TABLE entries (value TEXT NOT NULL)", [])
                    .unwrap();
            },
            |conn, entry| {
                conn.execute("INSERT INTO entries (value) VALUES (?1)", [entry])
                    .unwrap();
            },
            Box::new(|| true),
            Box::new(|_, _, _, _| {}),
        );

        handles[0].send("alpha".to_string());
        handles[0].send("beta".to_string());
        handles[0].send("gamma".to_string());

        drop(handles);
        driver.join();

        let conn = Connection::open(&path_clone).unwrap();
        let count: i64 = conn
            .query_row("SELECT COUNT(*) FROM entries", [], |row| row.get(0))
            .unwrap();
        assert_eq!(count, 3, "insert should be called per entry");

        cleanup(&path_clone);
    }

    #[test]
    fn batch_commit_writes_all() {
        let path = format!("{}_batch", temp_db_path());
        let path_clone = path.clone();
        let batch_size = 5;
        let total = 12; // 2 full batches of 5, plus 2 flushed on shutdown

        let (handles, driver) = database::<i64>(
            &path,
            1,
            batch_size,
            |conn| {
                conn.execute("CREATE TABLE nums (n INTEGER NOT NULL)", [])
                    .unwrap();
            },
            |conn, entry| {
                conn.execute("INSERT INTO nums (n) VALUES (?1)", [entry])
                    .unwrap();
            },
            Box::new(|| true),
            Box::new(|_, _, _, _| {}),
        );

        for i in 0..total {
            handles[0].send(i);
        }

        drop(handles);
        driver.join();

        let conn = Connection::open(&path_clone).unwrap();
        let count: i64 = conn
            .query_row("SELECT COUNT(*) FROM nums", [], |row| row.get(0))
            .unwrap();
        assert_eq!(count, total, "all entries should be committed");

        // Verify the actual values.
        let sum: i64 = conn
            .query_row("SELECT SUM(n) FROM nums", [], |row| row.get(0))
            .unwrap();
        let expected_sum: i64 = (0..total).sum();
        assert_eq!(sum, expected_sum);

        cleanup(&path_clone);
    }

    #[test]
    fn shutdown_flush_remaining() {
        let path = format!("{}_flush", temp_db_path());
        let path_clone = path.clone();

        // Batch size 100 — nothing will auto-flush. Everything flushes on shutdown.
        let (handles, driver) = database::<i64>(
            &path,
            1,
            100,
            |conn| {
                conn.execute("CREATE TABLE items (n INTEGER NOT NULL)", [])
                    .unwrap();
            },
            |conn, entry| {
                conn.execute("INSERT INTO items (n) VALUES (?1)", [entry])
                    .unwrap();
            },
            Box::new(|| true),
            Box::new(|_, _, _, _| {}),
        );

        for i in 0..7 {
            handles[0].send(i);
        }

        // Drop all handles — triggers disconnect and flush.
        drop(handles);
        driver.join();

        let conn = Connection::open(&path_clone).unwrap();
        let count: i64 = conn
            .query_row("SELECT COUNT(*) FROM items", [], |row| row.get(0))
            .unwrap();
        assert_eq!(count, 7, "shutdown must flush remaining entries");

        cleanup(&path_clone);
    }

    #[test]
    fn multiple_producers_all_arrive() {
        let path = format!("{}_multi", temp_db_path());
        let path_clone = path.clone();
        let num_producers = 4;
        let entries_per_producer = 25;

        let (handles, driver) = database::<i64>(
            &path,
            num_producers,
            10,
            |conn| {
                conn.execute("CREATE TABLE data (producer INTEGER, seq INTEGER)", [])
                    .unwrap();
            },
            |conn, entry| {
                let producer = entry / 1000;
                let seq = entry % 1000;
                conn.execute(
                    "INSERT INTO data (producer, seq) VALUES (?1, ?2)",
                    [producer, seq],
                )
                .unwrap();
            },
            Box::new(|| true),
            Box::new(|_, _, _, _| {}),
        );

        // Each producer sends from its own thread.
        let producer_handles: Vec<_> = handles
            .into_iter()
            .enumerate()
            .map(|(i, handle)| {
                thread::spawn(move || {
                    for j in 0..entries_per_producer {
                        // Encode producer ID and sequence into the value.
                        handle.send((i as i64) * 1000 + (j as i64));
                    }
                })
            })
            .collect();

        for h in producer_handles {
            h.join().unwrap();
        }

        // All handles are now dropped (moved into threads which completed).
        driver.join();

        let conn = Connection::open(&path_clone).unwrap();
        let count: i64 = conn
            .query_row("SELECT COUNT(*) FROM data", [], |row| row.get(0))
            .unwrap();
        let expected = (num_producers * entries_per_producer) as i64;
        assert_eq!(count, expected, "all entries from all producers must arrive");

        // Verify each producer contributed the right number.
        for i in 0..num_producers {
            let producer_count: i64 = conn
                .query_row(
                    "SELECT COUNT(*) FROM data WHERE producer = ?1",
                    [i as i64],
                    |row| row.get(0),
                )
                .unwrap();
            assert_eq!(producer_count, entries_per_producer as i64);
        }

        cleanup(&path_clone);
    }

    #[test]
    fn gate_telemetry_emits_accumulated() {
        let path = format!("{}_gate", temp_db_path());
        let path_clone = path.clone();

        let emit_count = Arc::new(AtomicUsize::new(0));
        let emit_count_clone = Arc::clone(&emit_count);
        let total_rows_seen = Arc::new(AtomicUsize::new(0));
        let total_rows_clone = Arc::clone(&total_rows_seen);

        let (handles, driver) = database::<i64>(
            &path,
            1,
            5,
            |conn| {
                conn.execute("CREATE TABLE items (n INTEGER NOT NULL)", [])
                    .unwrap();
            },
            |conn, entry| {
                conn.execute("INSERT INTO items (n) VALUES (?1)", [entry])
                    .unwrap();
            },
            // Gate always open — emit on every flush
            Box::new(|| true),
            Box::new(move |_conn, flush_count, total_rows, total_flush_ns| {
                assert!(flush_count > 0);
                assert!(total_rows > 0);
                assert!(total_flush_ns > 0);
                emit_count_clone.fetch_add(1, Ordering::SeqCst);
                total_rows_clone.fetch_add(total_rows, Ordering::SeqCst);
            }),
        );

        // Send 12 entries with batch_size=5: 2 full flushes + 1 shutdown flush
        for i in 0..12 {
            handles[0].send(i);
        }

        drop(handles);
        driver.join();

        // All 12 rows must be accounted for.
        assert_eq!(
            total_rows_seen.load(Ordering::SeqCst),
            12,
            "all 12 rows accounted for"
        );
        // At least one emission must have happened.
        assert!(
            emit_count.load(Ordering::SeqCst) >= 1,
            "expected at least 1 emission"
        );

        cleanup(&path_clone);
    }

    #[test]
    fn gate_closed_accumulates_then_emits_on_shutdown() {
        let path = format!("{}_gate_closed", temp_db_path());
        let path_clone = path.clone();

        let emit_count = Arc::new(AtomicUsize::new(0));
        let emit_count_clone = Arc::clone(&emit_count);
        let total_rows_seen = Arc::new(AtomicUsize::new(0));
        let total_rows_clone = Arc::clone(&total_rows_seen);

        let (handles, driver) = database::<i64>(
            &path,
            1,
            5,
            |conn| {
                conn.execute("CREATE TABLE items (n INTEGER NOT NULL)", [])
                    .unwrap();
            },
            |conn, entry| {
                conn.execute("INSERT INTO items (n) VALUES (?1)", [entry])
                    .unwrap();
            },
            // Gate never opens — accumulates everything, emits only on shutdown
            Box::new(|| false),
            Box::new(move |_conn, _flush_count, total_rows, _flush_ns| {
                emit_count_clone.fetch_add(1, Ordering::SeqCst);
                total_rows_clone.fetch_add(total_rows, Ordering::SeqCst);
            }),
        );

        // Send 12 entries with batch_size=5
        for i in 0..12 {
            handles[0].send(i);
        }

        drop(handles);
        driver.join();

        // Gate never opened — only the unconditional shutdown emission
        assert_eq!(
            emit_count.load(Ordering::SeqCst),
            1,
            "only shutdown emission"
        );
        assert_eq!(
            total_rows_seen.load(Ordering::SeqCst),
            12,
            "all rows in shutdown emission"
        );

        cleanup(&path_clone);
    }

    #[test]
    fn batch_send_writes_all() {
        let path = format!("{}_batch_send", temp_db_path());
        let path_clone = path.clone();

        let (handles, driver) = database::<i64>(
            &path,
            1,
            100,
            |conn| {
                conn.execute("CREATE TABLE items (n INTEGER NOT NULL)", [])
                    .unwrap();
            },
            |conn, entry| {
                conn.execute("INSERT INTO items (n) VALUES (?1)", [entry])
                    .unwrap();
            },
            Box::new(|| true),
            Box::new(|_, _, _, _| {}),
        );

        // Send a batch of 10 entries at once.
        let entries: Vec<i64> = (0..10).collect();
        handles[0].batch_send(entries);

        drop(handles);
        driver.join();

        let conn = Connection::open(&path_clone).unwrap();
        let count: i64 = conn
            .query_row("SELECT COUNT(*) FROM items", [], |row| row.get(0))
            .unwrap();
        assert_eq!(count, 10, "batch_send should write all entries");

        cleanup(&path_clone);
    }
}
