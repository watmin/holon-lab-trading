/// Telemetry helpers. Shared by all programs that emit metrics.

use std::sync::Mutex;
use std::time::{Duration, Instant};

use crate::types::log_entry::LogEntry;
use crate::programs::stdlib::database::DatabaseHandle;

/// Push a single CloudWatch-style metric into a pending Vec.
/// The caller flushes the Vec to the database handle at the end of the candle loop.
pub fn emit_metric(
    pending: &mut Vec<LogEntry>,
    namespace: &str,
    id: &str,
    dimensions: &str,
    timestamp_ns: u64,
    metric_name: &str,
    metric_value: f64,
    metric_unit: &str,
) {
    pending.push(LogEntry::Telemetry {
        namespace: namespace.to_string(),
        id: id.to_string(),
        dimensions: dimensions.to_string(),
        timestamp_ns,
        metric_name: metric_name.to_string(),
        metric_value,
        metric_unit: metric_unit.to_string(),
    });
}

/// Flush pending log entries to the database handle as one batch.
pub fn flush_metrics(db: &DatabaseHandle<LogEntry>, pending: &mut Vec<LogEntry>) {
    if !pending.is_empty() {
        db.batch_send(pending.drain(..).collect());
    }
}

/// Create a rate gate that opens every `interval`.
/// An opaque `Fn() -> bool`. The driver asks "can I emit?" The gate answers.
pub fn make_rate_gate(interval: Duration) -> impl Fn() -> bool + Send + 'static {
    let last = Mutex::new(Instant::now());
    move || {
        let mut last = last.lock().unwrap();
        if last.elapsed() >= interval {
            *last = Instant::now();
            true
        } else {
            false
        }
    }
}
