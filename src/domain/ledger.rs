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
            us_elapsed INTEGER,
            thought_ast TEXT,
            fact_count INTEGER
        );
        CREATE TABLE IF NOT EXISTS position_observer_snapshots (
            candle INTEGER,
            position_idx INTEGER,
            lens TEXT,
            us_elapsed INTEGER,
            thought_ast TEXT,
            fact_count INTEGER
        );
        CREATE TABLE IF NOT EXISTS broker_snapshots (
            candle INTEGER,
            broker_slot_idx INTEGER,
            grace_count INTEGER,
            violence_count INTEGER,
            paper_count INTEGER,
            expected_value REAL,
            fact_count INTEGER,
            thought_ast TEXT
        );
        CREATE TABLE IF NOT EXISTS phase_snapshots (
            candle INTEGER,
            close REAL,
            phase_label TEXT,
            phase_direction TEXT,
            phase_duration INTEGER,
            phase_count INTEGER,
            phase_history_len INTEGER
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
            thought_ast, fact_count,
        } => {
            conn.execute(
                "INSERT INTO observer_snapshots VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                rusqlite::params![
                    candle, observer_idx, lens, disc_strength, conviction,
                    experience, resolved, recalib_count, recalib_wins,
                    recalib_total, last_prediction, us_elapsed,
                    thought_ast, fact_count
                ],
            )
            .unwrap();
        }
        LogEntry::PositionObserverSnapshot {
            candle, position_idx, lens,
            us_elapsed, thought_ast, fact_count,
        } => {
            conn.execute(
                "INSERT INTO position_observer_snapshots VALUES (?,?,?,?,?,?)",
                rusqlite::params![
                    candle, position_idx, lens,
                    us_elapsed, thought_ast, fact_count
                ],
            )
            .unwrap();
        }
        LogEntry::BrokerSnapshot {
            candle, broker_slot_idx, grace_count, violence_count, paper_count,
            expected_value, fact_count, thought_ast,
        } => {
            conn.execute(
                "INSERT INTO broker_snapshots VALUES (?,?,?,?,?,?,?,?)",
                rusqlite::params![
                    candle, broker_slot_idx, grace_count, violence_count, paper_count,
                    expected_value, fact_count, thought_ast
                ],
            )
            .unwrap();
        }
        LogEntry::PhaseSnapshot {
            candle, close, phase_label, phase_direction, phase_duration,
            phase_count, phase_history_len,
        } => {
            conn.execute(
                "INSERT INTO phase_snapshots VALUES (?,?,?,?,?,?,?)",
                rusqlite::params![
                    candle, close, phase_label, phase_direction, phase_duration,
                    phase_count, phase_history_len
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
