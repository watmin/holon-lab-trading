/// Telemetry helpers. Shared by all programs that emit metrics.

use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use crate::types::log_entry::LogEntry;
use crate::programs::stdlib::database::DatabaseHandle;

/// Push a single CloudWatch-style metric into a pending Vec.
///
/// The Arc<str> arguments for namespace/id/dimensions are typically
/// built once per candle and cloned (refcount++) for each emit_metric
/// call. Only metric_name and metric_unit are usually string literals
/// — `.into()` on a `&'static str` produces a fresh Arc, but string
/// literals are cheap enough that the caller isn't expected to cache.
pub fn emit_metric(
    pending: &mut Vec<LogEntry>,
    namespace: Arc<str>,
    id: Arc<str>,
    dimensions: Arc<str>,
    timestamp_ns: u64,
    metric_name: &'static str,
    metric_value: f64,
    metric_unit: &'static str,
) {
    pending.push(LogEntry::Telemetry {
        namespace,
        id,
        dimensions,
        timestamp_ns,
        metric_name: Arc::from(metric_name),
        metric_value,
        metric_unit: Arc::from(metric_unit),
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
