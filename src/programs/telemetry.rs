/// Telemetry helpers. Shared by all programs that emit metrics.

use std::sync::Mutex;
use std::time::{Duration, Instant};

use crate::types::log_entry::LogEntry;
use crate::services::queue::QueueSender;

/// Emit a single CloudWatch-style metric to the DB queue.
pub fn emit_metric(
    db_tx: &QueueSender<LogEntry>,
    namespace: &str,
    id: &str,
    dimensions: &str,
    timestamp_ns: u64,
    metric_name: &str,
    metric_value: f64,
    metric_unit: &str,
) {
    let _ = db_tx.send(LogEntry::Telemetry {
        namespace: namespace.to_string(),
        id: id.to_string(),
        dimensions: dimensions.to_string(),
        timestamp_ns,
        metric_name: metric_name.to_string(),
        metric_value,
        metric_unit: metric_unit.to_string(),
    });
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
