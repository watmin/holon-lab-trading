//! Database — generic batched SQLite writer. A program, not a service.
//! Composed from the mailbox core service. The caller provides two closures:
//! `setup` (called once with the connection — create tables, configure)
//! and `insert` (called per entry — the caller's SQL).
//!
//! The stdlib provides the loop, batching, and shutdown flush.
//! On disconnect (all senders dropped), remaining entries are flushed
//! in a final transaction before the driver thread exits.

use std::thread;

use rusqlite::Connection;

use crate::services::mailbox::{self, MailboxSender, RecvError};

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
/// - `num_producers`: number of independent senders (one per producer).
/// - `batch_size`: entries accumulated before a transaction commit.
/// - `setup`: called once with the connection. Create tables, indices, etc.
/// - `insert`: called per entry with the connection and the entry.
///
/// Returns N senders and a driver handle. Drop all senders to trigger
/// shutdown — the driver flushes remaining entries and exits.
pub fn database<T: Send + 'static>(
    path: &str,
    num_producers: usize,
    batch_size: usize,
    setup: impl FnOnce(&Connection) + Send + 'static,
    insert: impl Fn(&Connection, &T) + Send + 'static,
) -> (Vec<MailboxSender<T>>, DatabaseDriverHandle) {
    assert!(batch_size > 0, "database requires non-zero batch_size");

    let (senders, rx) = mailbox::mailbox::<T>(num_producers);
    let path = path.to_string();

    let thread = thread::spawn(move || {
        let conn = Connection::open(&path).expect("database: failed to open connection");
        conn.pragma_update(None, "journal_mode", "WAL")
            .expect("database: failed to set WAL mode");

        setup(&conn);

        let mut batch: Vec<T> = Vec::with_capacity(batch_size);

        loop {
            match rx.recv() {
                Ok(entry) => {
                    batch.push(entry);
                    if batch.len() >= batch_size {
                        flush(&conn, &batch, &insert);
                        batch.clear();
                    }
                }
                Err(RecvError::Disconnected) => {
                    // Shutdown — flush remaining entries.
                    if !batch.is_empty() {
                        flush(&conn, &batch, &insert);
                    }
                    break;
                }
            }
        }
    });

    (
        senders,
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

        let (senders, driver) = database::<String>(
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

        let (senders, driver) = database::<String>(
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

        let (senders, driver) = database::<i64>(
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
        let (senders, driver) = database::<i64>(
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

        let (senders, driver) = database::<i64>(
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
}
