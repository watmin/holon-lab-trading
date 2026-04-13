/// Ledger — the database configuration for this enterprise.
/// The schema and the insert dispatch. The kernel refs these.
/// The SQL lives here, not in the binary.

use rusqlite::Connection;
use crate::types::log_entry::LogEntry;

/// Create all tables for the enterprise ledger.
pub fn ledger_setup(conn: &Connection) {
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS observer_snapshots (
            candle INTEGER,
            observer_idx INTEGER,
            lens TEXT,
            disc_strength REAL,
            conviction REAL,
            experience REAL,
            resolved INTEGER,
            recalib_count INTEGER,
            recalib_wins INTEGER,
            recalib_total INTEGER,
            last_prediction TEXT
        );
        CREATE TABLE IF NOT EXISTS exit_observer_snapshots (
            candle INTEGER,
            exit_idx INTEGER,
            lens TEXT,
            trail_experience REAL,
            stop_experience REAL,
            grace_rate REAL,
            avg_residue REAL
        );",
    )
    .unwrap();
}

/// Insert a log entry into the correct table.
pub fn ledger_insert(conn: &Connection, entry: &LogEntry) {
    match entry {
        LogEntry::ObserverSnapshot {
            candle,
            observer_idx,
            lens,
            disc_strength,
            conviction,
            experience,
            resolved,
            recalib_count,
            recalib_wins,
            recalib_total,
            last_prediction,
        } => {
            conn.execute(
                "INSERT INTO observer_snapshots VALUES (?,?,?,?,?,?,?,?,?,?,?)",
                rusqlite::params![
                    candle,
                    observer_idx,
                    lens,
                    disc_strength,
                    conviction,
                    experience,
                    resolved,
                    recalib_count,
                    recalib_wins,
                    recalib_total,
                    last_prediction
                ],
            )
            .unwrap();
        }
        LogEntry::ExitObserverSnapshot {
            candle, exit_idx, lens, trail_experience,
            stop_experience, grace_rate, avg_residue,
        } => {
            conn.execute(
                "INSERT INTO exit_observer_snapshots VALUES (?,?,?,?,?,?,?)",
                rusqlite::params![
                    candle, exit_idx, lens, trail_experience,
                    stop_experience, grace_rate, avg_residue
                ],
            )
            .unwrap();
        }
        _ => {}
    }
}
