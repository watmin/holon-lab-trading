/// market_observer_program.rs — the observer thread body.
/// Compiled from wat/market-observer-program.wat.
///
/// Receives candles through a queue, encodes through a lens, predicts,
/// sends results, and learns from settlement signals through a mailbox.
/// On shutdown it drains remaining learn signals and returns the observer.
/// The learned state comes home.

use std::collections::HashMap;
use std::sync::Arc;

use holon::kernel::vector::Vector;

use crate::types::candle::Candle;
use crate::types::enums::Direction;
use crate::types::log_entry::LogEntry;
use crate::domain::market_observer::MarketObserver;
use crate::domain::lens::market_lens_facts;
use crate::programs::chain::MarketChain;
use crate::programs::stdlib::cache::EncodingCacheHandle;
use crate::programs::stdlib::console::ConsoleHandle;
use crate::encoding::scale_tracker::ScaleTracker;
use crate::services::mailbox::MailboxReceiver;
use crate::services::queue::{QueueReceiver, QueueSender};
use crate::services::topic::TopicSender;
use crate::encoding::thought_encoder::ThoughtAST;
use crate::programs::telemetry::emit_metric;

/// Input to the observer: enriched candle, window snapshot, encode count.
pub struct ObsInput {
    pub candle: Candle,
    pub window: Arc<Vec<Candle>>,
    pub encode_count: usize,
}

/// Learn signal: thought vector, direction label, weight.
pub struct ObsLearn {
    pub thought: Vector,
    pub direction: Direction,
    pub weight: f64,
}

/// Drain all pending learn signals. Non-blocking.
/// Each signal resolves the observer's reckoner with reality.
fn drain_learn(
    learn_rx: &MailboxReceiver<ObsLearn>,
    observer: &mut MarketObserver,
    recalib_interval: usize,
) {
    while let Ok(signal) = learn_rx.try_recv() {
        observer.resolve(&signal.thought, signal.direction, signal.weight, recalib_interval);
    }
}

/// Run the market observer program. Call this inside thread::spawn.
/// Output fans out to M exit observers via a topic.
/// Returns the trained MarketObserver when the candle source disconnects.
pub fn market_observer_program(
    candle_rx: QueueReceiver<ObsInput>,
    result_tx: TopicSender<MarketChain>,
    learn_rx: MailboxReceiver<ObsLearn>,
    cache: EncodingCacheHandle,
    console: ConsoleHandle,
    db_tx: QueueSender<LogEntry>,
    mut observer: MarketObserver,
    observer_idx: usize,
    recalib_interval: usize,
) -> MarketObserver {
    let mut candle_count = 0usize;
    let mut scales: HashMap<String, ScaleTracker> = HashMap::new();
    let lens = observer.lens;

    while let Ok(input) = candle_rx.recv() {
        let t_total = std::time::Instant::now();
        let batch_ts = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos() as u64;
        candle_count += 1;

        let ns = "market-observer";
        let id = format!("market:{}:{}", lens, candle_count);
        let metric_dims = format!("{{\"lens\":\"{}\"}}", lens);

        // LEARN FIRST. Drain all pending signals before encoding.
        let t0 = std::time::Instant::now();
        drain_learn(&learn_rx, &mut observer, recalib_interval);
        let ns_drain = t0.elapsed().as_nanos() as f64;

        // Sample window size from observer's own time scale.
        let ws = observer.window_sampler.sample(candle_count);
        let full_len = input.window.len();
        let start = if full_len > ws { full_len - ws } else { 0 };
        let sliced = &input.window[start..];

        // Collect facts through the lens.
        let t0 = std::time::Instant::now();
        let facts = market_lens_facts(&lens, &input.candle, &sliced, &mut scales);
        let fact_count = facts.len() as f64;
        let bundle_ast = ThoughtAST::Bundle(facts);
        let snapshot_edn = bundle_ast.to_edn();
        let ns_collect = t0.elapsed().as_nanos() as f64;

        // Encode via cache: check → compute → install.
        let t0 = std::time::Instant::now();
        let thought = cache.get(&bundle_ast).expect("cache driver disconnected");
        let ns_encode = t0.elapsed().as_nanos() as f64;

        // Observe: noise subspace learns, anomaly extracted, reckoner predicts.
        let t0 = std::time::Instant::now();
        let result = observer.observe(thought);
        let ns_observe = t0.elapsed().as_nanos() as f64;

        // Capture conviction before prediction is moved.
        let conviction = result.prediction.conviction;

        // Send the chain — bounded(1), blocks until exit takes it.
        let t0 = std::time::Instant::now();
        let _ = result_tx.send(MarketChain {
            candle: input.candle,
            window: input.window,
            encode_count: input.encode_count,
            market_raw: result.raw_thought,
            market_anomaly: result.anomaly,
            market_ast: bundle_ast,
            prediction: result.prediction,
            edge: result.edge,
        });
        let ns_send = t0.elapsed().as_nanos() as f64;

        let ns_total = t_total.elapsed().as_nanos() as f64;

        // Emit telemetry.
        emit_metric(&db_tx, ns, &id, &metric_dims, batch_ts, "drain_learn", ns_drain, "Nanoseconds");
        emit_metric(&db_tx, ns, &id, &metric_dims, batch_ts, "collect_facts", ns_collect, "Nanoseconds");
        emit_metric(&db_tx, ns, &id, &metric_dims, batch_ts, "facts_count", fact_count, "Count");
        emit_metric(&db_tx, ns, &id, &metric_dims, batch_ts, "encode", ns_encode, "Nanoseconds");
        emit_metric(&db_tx, ns, &id, &metric_dims, batch_ts, "observe", ns_observe, "Nanoseconds");
        emit_metric(&db_tx, ns, &id, &metric_dims, batch_ts, "send", ns_send, "Nanoseconds");
        emit_metric(&db_tx, ns, &id, &metric_dims, batch_ts, "total", ns_total, "Nanoseconds");

        let us_elapsed = (ns_total / 1000.0) as u64;

        // Snapshot every candle.
        {
            let _ = db_tx.send(LogEntry::ObserverSnapshot {
                candle: candle_count,
                observer_idx,
                lens: format!("{}", lens),
                disc_strength: observer.reckoner.last_disc_strength(),
                conviction,
                experience: observer.experience(),
                resolved: observer.resolved,
                recalib_count: observer.reckoner.recalib_count(),
                recalib_wins: observer.recalib_wins,
                recalib_total: observer.recalib_total,
                last_prediction: format!("{:?}", observer.last_prediction),
                us_elapsed,
                thought_ast: snapshot_edn.clone(),
                fact_count: fact_count as usize,
            });
        }

        // Diagnostic every 1000 candles — to console.
        if candle_count % 1000 == 0 {
            console.out(format!(
                "{}: disc={:.4} conv={:.4} exp={:.1}",
                lens,
                observer.reckoner.last_disc_strength(),
                conviction,
                observer.experience(),
            ));
        }
    }

    // GRACEFUL SHUTDOWN. Drain learn one last time.
    drain_learn(&learn_rx, &mut observer, recalib_interval);

    // Return the observer. The experience survives.
    observer
}
