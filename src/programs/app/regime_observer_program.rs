/// regime_observer_program.rs — the regime observer thread body.
/// Thought middleware. Receives market chains, builds regime rhythms
/// from the candle window, sends enriched chains downstream to brokers.
///
/// Does not learn. Does not predict. The broker-observer is the
/// accountability unit. The regime observer is the lens.

use std::sync::Arc;

use holon::kernel::scalar::ScalarEncoder;
use holon::kernel::vector::Vector;
use holon::kernel::vector_manager::VectorManager;

use crate::domain::regime_observer::RegimeObserver;
use crate::types::log_entry::LogEntry;
use crate::domain::lens::regime_rhythm_specs;
use crate::encoding::rhythm::build_rhythm_asts;
use crate::encoding::thought_encoder::ThoughtAST;
use crate::programs::chain::{MarketRegimeChain, MarketChain};
use crate::programs::stdlib::cache::CacheHandle;
use crate::programs::stdlib::console::ConsoleHandle;
use crate::services::queue::{QueueReceiver, QueueSender};

use crate::programs::telemetry::emit_metric;

/// One slot: a (receiver, sender) pair connecting one market observer to one broker.
pub struct RegimeSlot {
    pub input_rx: QueueReceiver<MarketChain>,
    pub output_tx: QueueSender<MarketRegimeChain>,
}

// Re-export trade atom functions for backward compatibility.
pub use crate::vocab::exit::trade_atoms::{compute_trade_atoms, select_trade_atoms};

/// Run the regime observer program. Call this inside thread::spawn.
/// Processes N slots per candle round, sequentially.
/// Returns the regime observer when all input slots disconnect.
pub fn regime_observer_program(
    slots: Vec<RegimeSlot>,
    _cache: CacheHandle<ThoughtAST, Vector>,
    _vm: VectorManager,
    _scalar: Arc<ScalarEncoder>,
    console: ConsoleHandle,
    db_tx: QueueSender<LogEntry>,
    regime_obs: RegimeObserver,
    _noise_floor: f64,
    regime_idx: usize,
) -> RegimeObserver {
    let mut candle_count = 0usize;
    let lens = regime_obs.lens;
    let (indicator_specs, circular_specs) = regime_rhythm_specs(&lens);

    'outer: loop {
        let t_total = std::time::Instant::now();
        let batch_ts = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos() as u64;
        candle_count += 1;

        let ns = "regime-observer";
        let id = format!("regime:{}:{}", lens, candle_count);
        let metric_dims = format!("{{\"lens\":\"{}\"}}", lens);

        let mut ns_slot_recv: f64 = 0.0;
        let mut ns_rhythm: f64 = 0.0;
        let mut ns_send: f64 = 0.0;
        let mut slots_processed: f64 = 0.0;
        let mut snapshot_ast = String::new();
        let mut snapshot_fact_count: usize = 0;

        // Build regime rhythms once per candle round — identical across all slots.
        // Uses the window from the first slot's chain.
        let mut regime_rhythm_asts: Option<Vec<ThoughtAST>> = None;

        for slot in &slots {
            let t0 = std::time::Instant::now();
            let chain = match slot.input_rx.recv() {
                Ok(c) => c,
                Err(_) => break 'outer,
            };
            ns_slot_recv += t0.elapsed().as_nanos() as f64;

            // Build regime rhythms from the candle window — once, reuse for all slots.
            let t0 = std::time::Instant::now();
            let regime_asts = regime_rhythm_asts.get_or_insert_with(|| {
                build_rhythm_asts(&chain.window, &indicator_specs, &circular_specs)
            });
            ns_rhythm += t0.elapsed().as_nanos() as f64;

            // Snapshot from slot 0.
            if slots_processed == 0.0 {
                snapshot_fact_count = regime_asts.len();
                let snapshot_bundle = ThoughtAST::Bundle(regime_asts.clone());
                snapshot_ast = snapshot_bundle.to_edn();
            }

            // Send MarketRegimeChain downstream.
            // The market AST (rhythm bundle) passes through untouched.
            // The regime rhythms are the regime observer's own thoughts.
            let t0 = std::time::Instant::now();
            let full = MarketRegimeChain {
                candle: chain.candle,
                window: chain.window,
                encode_count: chain.encode_count,
                market_raw: chain.market_raw,
                market_anomaly: chain.market_anomaly,
                market_ast: chain.market_ast,
                market_prediction: chain.prediction,
                market_edge: chain.edge,
                regime_facts: regime_asts.clone(),
            };
            if slot.output_tx.send(full).is_err() {
                break 'outer;
            }
            ns_send += t0.elapsed().as_nanos() as f64;

            slots_processed += 1.0;
        }

        let ns_total = t_total.elapsed().as_nanos() as f64;

        // Emit telemetry.
        emit_metric(&db_tx, ns, &id, &metric_dims, batch_ts, "slot_recv", ns_slot_recv, "Nanoseconds");
        emit_metric(&db_tx, ns, &id, &metric_dims, batch_ts, "rhythm", ns_rhythm, "Nanoseconds");
        emit_metric(&db_tx, ns, &id, &metric_dims, batch_ts, "send", ns_send, "Nanoseconds");
        emit_metric(&db_tx, ns, &id, &metric_dims, batch_ts, "slots_count", slots_processed, "Count");
        emit_metric(&db_tx, ns, &id, &metric_dims, batch_ts, "total", ns_total, "Nanoseconds");

        let us_elapsed = (ns_total / 1000.0) as u64;

        // Snapshot every candle.
        {
            let _ = db_tx.send(LogEntry::RegimeObserverSnapshot {
                candle: candle_count,
                regime_idx,
                lens: format!("{}", regime_obs.lens),
                us_elapsed,
                thought_ast: snapshot_ast.clone(),
                fact_count: snapshot_fact_count,
            });
        }

        // Diagnostic every 1000 candles.
        if candle_count % 1000 == 0 {
            console.out(format!(
                "regime-{}: candles={} rhythms={}",
                lens, candle_count, snapshot_fact_count,
            ));
        }
    }

    regime_obs
}
