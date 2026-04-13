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
            last_prediction TEXT,
            us_elapsed INTEGER
        );
        CREATE TABLE IF NOT EXISTS exit_observer_snapshots (
            candle INTEGER,
            exit_idx INTEGER,
            lens TEXT,
            trail_experience REAL,
            stop_experience REAL,
            grace_rate REAL,
            avg_residue REAL,
            us_elapsed INTEGER
        );
        CREATE TABLE IF NOT EXISTS telemetry (
            namespace TEXT,
            id TEXT,
            dimensions TEXT,
            timestamp_ns INTEGER,
            metric_name TEXT,
            metric_value REAL,
            metric_unit TEXT
        );",
    )
    .unwrap();
}

/// Insert a log entry into the correct table.
pub fn ledger_insert(conn: &Connection, entry: &LogEntry) {
    match entry {
        LogEntry::ObserverSnapshot {
            candle, observer_idx, lens, disc_strength, conviction,
            experience, resolved, recalib_count, recalib_wins,
            recalib_total, last_prediction, us_elapsed,
        } => {
            conn.execute(
                "INSERT INTO observer_snapshots VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
                rusqlite::params![
                    candle, observer_idx, lens, disc_strength, conviction,
                    experience, resolved, recalib_count, recalib_wins,
                    recalib_total, last_prediction, us_elapsed
                ],
            )
            .unwrap();
        }
        LogEntry::ExitObserverSnapshot {
            candle, exit_idx, lens, trail_experience,
            stop_experience, grace_rate, avg_residue, us_elapsed,
        } => {
            conn.execute(
                "INSERT INTO exit_observer_snapshots VALUES (?,?,?,?,?,?,?,?)",
                rusqlite::params![
                    candle, exit_idx, lens, trail_experience,
                    stop_experience, grace_rate, avg_residue, us_elapsed
                ],
            )
            .unwrap();
        }
        LogEntry::Telemetry {
            namespace, id, dimensions, timestamp_ns,
            metric_name, metric_value, metric_unit,
        } => {
            conn.execute(
                "INSERT INTO telemetry VALUES (?,?,?,?,?,?,?)",
                rusqlite::params![
                    namespace, id, dimensions, timestamp_ns,
                    metric_name, metric_value, metric_unit
                ],
            ).unwrap();
        }
        _ => {}
    }
}
