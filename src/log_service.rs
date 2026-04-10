/// log_service.rs — Log writer as a single-threaded pipe loop.
///
/// Each producer gets a log pipe at construction. The IO is declared.
/// The producer doesn't know about SQLite. It has a Sender<LogEntry>.
/// The log writer drains all pipes and writes to the DB.
///
/// One thread. N pipes. One SQLite connection. No contention.
/// The pipe IS the IO monad. The type says "I produce log events."

use std::thread::{self, JoinHandle};

use crossbeam::channel::{self, Receiver, Sender, TryRecvError};
use rusqlite::{params, Connection};

use crate::enums::Outcome;
use crate::log_entry::LogEntry;

/// A producer's log handle. Moved into the thread at construction.
/// Fire and forget. The producer writes and continues.
/// The handle IS the IO declaration. The type says "I produce log events."
pub struct LogHandle {
    emit: Sender<LogEntry>,
}

impl LogHandle {
    /// Fire and forget. The log writer drains this.
    pub fn log(&self, entry: LogEntry) {
        let _ = self.emit.send(entry);
    }
}

/// The log writer service.
pub struct LogService {
    handle: Option<JoinHandle<()>>,
    pub rows_written: std::sync::Arc<std::sync::atomic::AtomicUsize>,
}

impl LogService {
    /// Spawn the log writer thread. Returns the service + N handles.
    /// The connection is MOVED into the thread. One owner. No sharing.
    pub fn spawn(n_producers: usize, conn: Connection) -> (Self, Vec<LogHandle>) {
        let mut handles = Vec::with_capacity(n_producers);
        let mut drains: Vec<Receiver<LogEntry>> = Vec::new();

        for _ in 0..n_producers {
            let (emit, drain) = channel::unbounded::<LogEntry>();
            handles.push(LogHandle { emit });
            drains.push(drain);
        }

        let rows = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let rows_clone = rows.clone();

        let handle = thread::spawn(move || {
            let n = drains.len();
            let mut closed = vec![false; n];
            // WAL mode — readers don't block on writers. The DB is always queryable.
            conn.execute_batch("PRAGMA journal_mode=WAL;").ok();

            let mut log_stmt = conn
                .prepare_cached(
                    "INSERT INTO log (kind, broker_slot_idx, trade_id, outcome, amount, duration, reason, observers_updated)
                     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
                )
                .expect("failed to prepare log insert");

            let mut diag_stmt = conn
                .prepare_cached(
                    "INSERT OR REPLACE INTO diagnostics (candle, throughput, cache_hits, cache_misses, cache_hit_pct, cache_size, equity)
                     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
                )
                .expect("failed to prepare diagnostics insert");


            loop {
                let mut did_work = false;

                // Drain all pipes. Write what we find. One pass.
                for i in 0..n {
                    if closed[i] { continue; }
                    loop {
                        match drains[i].try_recv() {
                            Ok(entry) => {
                                write_entry(&mut log_stmt, &mut diag_stmt, &entry);
                                rows_clone.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                                did_work = true;
                            }
                            Err(TryRecvError::Empty) => break,
                            Err(TryRecvError::Disconnected) => {
                                closed[i] = true;
                                break;
                            }
                        }
                    }
                }

                // Shutdown: all pipes closed
                if closed.iter().all(|&c| c) { break; }

                // Block until ANY log pipe has data. Zero CPU when idle.
                if !did_work {
                    let mut sel = crossbeam::channel::Select::new();
                    for i in 0..n {
                        if !closed[i] { sel.recv(&drains[i]); }
                    }
                    let _ = sel.ready();
                }
            }
        });

        (
            LogService {
                handle: Some(handle),
                rows_written: rows,
            },
            handles,
        )
    }

    pub fn rows(&self) -> usize {
        self.rows_written.load(std::sync::atomic::Ordering::Relaxed)
    }

    /// Wait for the log writer to drain and exit.
    /// All LogHandles must be dropped first (cascade).
    pub fn shutdown(mut self) {
        if let Some(h) = self.handle.take() {
            let _ = h.join();
        }
    }
}

fn write_entry(
    log_stmt: &mut rusqlite::CachedStatement,
    diag_stmt: &mut rusqlite::CachedStatement,
    entry: &LogEntry,
) {
    match entry {
        LogEntry::ProposalSubmitted { broker_slot_idx, .. } => {
            log_stmt.execute(params![
                "ProposalSubmitted", *broker_slot_idx as i64,
                None::<i64>, None::<String>, None::<f64>,
                None::<i64>, None::<String>, None::<i64>
            ]).ok();
        }
        LogEntry::ProposalFunded { trade_id, broker_slot_idx, amount_reserved } => {
            log_stmt.execute(params![
                "ProposalFunded", *broker_slot_idx as i64,
                trade_id.0 as i64, None::<String>, *amount_reserved,
                None::<i64>, None::<String>, None::<i64>
            ]).ok();
        }
        LogEntry::ProposalRejected { broker_slot_idx, reason } => {
            log_stmt.execute(params![
                "ProposalRejected", *broker_slot_idx as i64,
                None::<i64>, None::<String>, None::<f64>,
                None::<i64>, reason, None::<i64>
            ]).ok();
        }
        LogEntry::TradeSettled { trade_id, outcome, amount, duration, .. } => {
            let outcome_str = match outcome {
                Outcome::Grace => "Grace",
                Outcome::Violence => "Violence",
            };
            log_stmt.execute(params![
                "TradeSettled", None::<i64>, trade_id.0 as i64,
                outcome_str, *amount, *duration as i64,
                None::<String>, None::<i64>
            ]).ok();
        }
        LogEntry::PaperResolved { broker_slot_idx, outcome, .. } => {
            let outcome_str = match outcome {
                Outcome::Grace => "Grace",
                Outcome::Violence => "Violence",
            };
            log_stmt.execute(params![
                "PaperResolved", *broker_slot_idx as i64,
                None::<i64>, outcome_str, None::<f64>,
                None::<i64>, None::<String>, None::<i64>
            ]).ok();
        }
        LogEntry::Propagated { broker_slot_idx, observers_updated } => {
            log_stmt.execute(params![
                "Propagated", *broker_slot_idx as i64,
                None::<i64>, None::<String>, None::<f64>,
                None::<i64>, None::<String>, *observers_updated as i64
            ]).ok();
        }
        LogEntry::Diagnostic { candle, throughput, cache_hits, cache_misses, cache_size, equity } => {
            let hit_pct = if *cache_hits + *cache_misses > 0 {
                100.0 * *cache_hits as f64 / (*cache_hits + *cache_misses) as f64
            } else { 0.0 };
            diag_stmt.execute(params![
                *candle as i64, throughput, *cache_hits as i64,
                *cache_misses as i64, hit_pct, *cache_size as i64, equity
            ]).ok();
        }
    }
}
