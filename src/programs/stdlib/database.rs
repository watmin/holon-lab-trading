//! Database — generic batched SQLite writer. A program, not a service.
//! Composed from the mailbox core service. The caller provides two closures:
//! `setup` (called once with the connection — create tables, configure)
//! and `insert` (called per entry — the caller's SQL).
//!
//! The stdlib provides the loop, batching, and shutdown flush.
//! On disconnect (all senders dropped), remaining entries are flushed
//! in a final transaction before the driver thread exits.
//!
//! The kernel creates all queues and the mailbox externally.
//! The database receives a MailboxReceiver — it does not create queues.
//!
//! Telemetry uses the gate pattern: the driver accumulates counters
//! (flush_count, total_rows, total_flush_ns) and checks a `can_emit`
//! gate after each flush. When the gate opens, it calls `emit` with the
//! accumulated values and resets. On disconnect, emits remainder
//! unconditionally. Both closures are optional — the database stays generic.

use std::thread;

use rusqlite::Connection;

use crate::services::mailbox::{MailboxReceiver, RecvError};

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


/// Create a batched SQLite database writer.
///
/// - `path`: SQLite database file path.
/// - `receiver`: the mailbox receiver (kernel creates queues + mailbox externally).
/// - `batch_size`: entries accumulated before a transaction commit.
/// - `setup`: called once with the connection. Create tables, indices, etc.
/// - `insert`: called per entry with the connection and the entry.
/// - `can_emit`: optional rate gate — `Fn() -> bool`. When provided with `emit`,
///   the driver accumulates flush stats and emits them through the closure when
///   the gate opens. On disconnect, emits remainder unconditionally.
/// - `emit`: optional emit closure — `Fn(flush_count, total_rows, total_flush_ns)`.
///   The kernel wraps `emit_metric` inside this. The database stays generic.
///
/// Returns a driver handle. Drop all senders to trigger
/// shutdown — the driver flushes remaining entries and exits.
pub fn database<T: Send + 'static>(
    path: &str,
    receiver: MailboxReceiver<T>,
    batch_size: usize,
    setup: impl FnOnce(&Connection) + Send + 'static,
    insert: impl Fn(&Connection, &T) + Send + 'static,
    can_emit: Box<dyn Fn() -> bool + Send>,
    emit: Box<dyn Fn(&Connection, usize, usize, u64) + Send>,
) -> DatabaseDriverHandle {
    assert!(batch_size > 0, "database requires non-zero batch_size");

    let path = path.to_string();

    let thread = thread::spawn(move || {
        let conn = Connection::open(&path).expect("database: failed to open connection");
        conn.pragma_update(None, "journal_mode", "WAL")
            .expect("database: failed to set WAL mode");

        setup(&conn);

        let mut batch: Vec<T> = Vec::with_capacity(batch_size);

        // Telemetry accumulators — reset after each emission.
        let mut flush_count: usize = 0;
        let mut total_rows: usize = 0;
        let mut total_flush_ns: u64 = 0;

        loop {
            match receiver.recv() {
                Ok(entry) => {
                    batch.push(entry);
                    if batch.len() >= batch_size {
                        let rows = batch.len();
                        let start = std::time::Instant::now();
                        flush(&conn, &batch, &insert);
                        let duration_ns = start.elapsed().as_nanos() as u64;
                        batch.clear();

                        // Accumulate
                        flush_count += 1;
                        total_rows += rows;
                        total_flush_ns += duration_ns;

                        // Gate check
                        if can_emit() {
                            emit(&conn, flush_count, total_rows, total_flush_ns);
                            flush_count = 0;
                            total_rows = 0;
                            total_flush_ns = 0;
                        }
                    }
                }
                Err(RecvError::Disconnected) => {
                    // Shutdown — flush remaining entries.
                    if !batch.is_empty() {
                        let rows = batch.len();
                        let start = std::time::Instant::now();
                        flush(&conn, &batch, &insert);
                        let duration_ns = start.elapsed().as_nanos() as u64;

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
            }
        }
    });

    DatabaseDriverHandle {
        thread: Some(thread),
    }
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
    use crate::services::mailbox::mailbox;
    use crate::services::queue::queue_unbounded;
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

    /// Helper: create N queues, build a mailbox, return (senders, mailbox_receiver).
    fn make_mailbox<T: Send + 'static>(
        n: usize,
    ) -> (
        Vec<crate::services::queue::QueueSender<T>>,
        crate::services::mailbox::MailboxReceiver<T>,
    ) {
        let mut txs = Vec::with_capacity(n);
        let mut rxs = Vec::with_capacity(n);
        for _ in 0..n {
            let (tx, rx) = queue_unbounded::<T>();
            txs.push(tx);
            rxs.push(rx);
        }
        let mb_rx = mailbox(rxs);
        (txs, mb_rx)
    }

    #[test]
    fn setup_function_is_called() {
        let path = format!("{}_setup", temp_db_path());
        let path_clone = path.clone();

        let (senders, mb_rx) = make_mailbox::<String>(1);
        let driver = database::<String>(
            &path,
            mb_rx,
            10,
            |conn| {
                conn.execute(
                    "CREATE TABLE test_table (id INTEGER PRIMARY KEY, value TEXT)",
                    [],
                )
                .unwrap();
            },
            |_conn, _entry| {},
            Box::new(|| true), Box::new(|_, _, _, _| {}),
        );

        // Drop senders to trigger shutdown, then join.
        drop(senders);
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

        let (senders, mb_rx) = make_mailbox::<String>(1);
        let driver = database::<String>(
            &path,
            mb_rx,
            100, // large batch so it flushes on shutdown
            |conn| {
                conn.execute("CREATE TABLE entries (value TEXT NOT NULL)", [])
                    .unwrap();
            },
            |conn, entry| {
                conn.execute("INSERT INTO entries (value) VALUES (?1)", [entry])
                    .unwrap();
            },
            Box::new(|| true), Box::new(|_, _, _, _| {}),
        );

        senders[0].send("alpha".to_string()).unwrap();
        senders[0].send("beta".to_string()).unwrap();
        senders[0].send("gamma".to_string()).unwrap();

        drop(senders);
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

        let (senders, mb_rx) = make_mailbox::<i64>(1);
        let driver = database::<i64>(
            &path,
            mb_rx,
            batch_size,
            |conn| {
                conn.execute("CREATE TABLE nums (n INTEGER NOT NULL)", [])
                    .unwrap();
            },
            |conn, entry| {
                conn.execute("INSERT INTO nums (n) VALUES (?1)", [entry])
                    .unwrap();
            },
            Box::new(|| true), Box::new(|_, _, _, _| {}),
        );

        for i in 0..total {
            senders[0].send(i).unwrap();
        }

        drop(senders);
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
        let (senders, mb_rx) = make_mailbox::<i64>(1);
        let driver = database::<i64>(
            &path,
            mb_rx,
            100,
            |conn| {
                conn.execute("CREATE TABLE items (n INTEGER NOT NULL)", [])
                    .unwrap();
            },
            |conn, entry| {
                conn.execute("INSERT INTO items (n) VALUES (?1)", [entry])
                    .unwrap();
            },
            Box::new(|| true), Box::new(|_, _, _, _| {}),
        );

        for i in 0..7 {
            senders[0].send(i).unwrap();
        }

        // Drop all senders — triggers disconnect and flush.
        drop(senders);
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

        let (senders, mb_rx) = make_mailbox::<i64>(num_producers);
        let driver = database::<i64>(
            &path,
            mb_rx,
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
            Box::new(|| true), Box::new(|_, _, _, _| {}),
        );

        // Each producer sends from its own thread.
        let handles: Vec<_> = senders
            .into_iter()
            .enumerate()
            .map(|(i, sender)| {
                thread::spawn(move || {
                    for j in 0..entries_per_producer {
                        // Encode producer ID and sequence into the value.
                        sender.send((i as i64) * 1000 + (j as i64)).unwrap();
                    }
                })
            })
            .collect();

        for h in handles {
            h.join().unwrap();
        }

        // All senders are now dropped (moved into threads which completed).
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

        let (senders, mb_rx) = make_mailbox::<i64>(1);
        let driver = database::<i64>(
            &path,
            mb_rx,
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
            senders[0].send(i).unwrap();
        }

        drop(senders);
        driver.join();

        // Gate always open: emit after each full batch (2) + shutdown remainder (1) = 3
        assert_eq!(emit_count.load(Ordering::SeqCst), 3, "expected 3 emissions");
        assert_eq!(total_rows_seen.load(Ordering::SeqCst), 12, "all 12 rows accounted for");

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

        let (senders, mb_rx) = make_mailbox::<i64>(1);
        let driver = database::<i64>(
            &path,
            mb_rx,
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
            Box::new(move |_conn, flush_count, total_rows, _flush_ns| {
                emit_count_clone.fetch_add(1, Ordering::SeqCst);
                total_rows_clone.fetch_add(total_rows, Ordering::SeqCst);
                // All 3 flushes accumulated into one emission
                assert_eq!(flush_count, 3, "all flushes accumulated");
            }),
        );

        // Send 12 entries with batch_size=5: 2 full + 1 shutdown = 3 flushes
        for i in 0..12 {
            senders[0].send(i).unwrap();
        }

        drop(senders);
        driver.join();

        // Gate never opened — only the unconditional shutdown emission
        assert_eq!(emit_count.load(Ordering::SeqCst), 1, "only shutdown emission");
        assert_eq!(total_rows_seen.load(Ordering::SeqCst), 12, "all rows in shutdown emission");

        cleanup(&path_clone);
    }
}
