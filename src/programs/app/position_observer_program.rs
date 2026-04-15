/// position_observer_program.rs — the position observer thread body.
/// Thought middleware. Receives market chains, composes with position-specific
/// facts, sends enriched chains downstream to brokers.
///
/// Does not learn. Does not predict distances. The broker is the accountability
/// unit. The position observer is the lens.

use std::collections::HashMap;
use std::sync::Arc;

use holon::kernel::scalar::ScalarEncoder;
use holon::kernel::vector::Vector;
use holon::kernel::vector_manager::VectorManager;

use crate::domain::position_observer::PositionObserver;
use crate::types::log_entry::LogEntry;
use crate::domain::lens::position_lens_facts;
use crate::encoding::encode::encode;
use crate::encoding::thought_encoder::{collect_facts, ThoughtAST};
use crate::programs::chain::{MarketPositionChain, MarketChain};
use crate::programs::stdlib::cache::CacheHandle;
use crate::programs::stdlib::console::ConsoleHandle;
use crate::encoding::scale_tracker::ScaleTracker;
use crate::services::queue::{QueueReceiver, QueueSender};

use crate::programs::telemetry::emit_metric;

/// One slot: a (receiver, sender) pair connecting one market observer to one broker.
/// input_rx is a QueueReceiver — the queue was created by the kernel.
/// The topic that fans out from the market observer writes to the queue's sender.
/// The program doesn't know about the topic. It sees a queue.
/// output_tx is a QueueSender — point-to-point to exactly one broker.
pub struct PositionSlot {
    pub input_rx: QueueReceiver<MarketChain>,
    pub output_tx: QueueSender<MarketPositionChain>,
}

// Re-export trade atom functions for backward compatibility.
pub use crate::vocab::exit::trade_atoms::{compute_trade_atoms, select_trade_atoms};

/// Run the position observer program. Call this inside thread::spawn.
/// Processes N slots per candle round, sequentially.
/// Returns the position observer when all input slots disconnect.
pub fn position_observer_program(
    slots: Vec<PositionSlot>,
    cache: CacheHandle<ThoughtAST, Vector>,
    vm: VectorManager,
    scalar: Arc<ScalarEncoder>,
    console: ConsoleHandle,
    db_tx: QueueSender<LogEntry>,
    position_obs: PositionObserver,
    noise_floor: f64,
    position_idx: usize,
) -> PositionObserver {
    let mut candle_count = 0usize;
    let mut scales: HashMap<String, ScaleTracker> = HashMap::new();
    let lens = position_obs.lens;

    'outer: loop {
        let t_total = std::time::Instant::now();
        let batch_ts = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos() as u64;
        candle_count += 1;

        let ns = "position-observer";
        let id = format!("position:{}:{}", lens, candle_count);
        let metric_dims = format!("{{\"lens\":\"{}\"}}", lens);

        let mut ns_slot_recv: f64 = 0.0;
        let mut ns_collect_facts: f64 = 0.0;
        let mut ns_extract_anomaly: f64 = 0.0;
        let mut ns_extract_raw: f64 = 0.0;
        let ns_encode_bundle: f64 = 0.0;
        let ns_noise_strip: f64 = 0.0;
        let mut ns_send: f64 = 0.0;
        let mut total_anomaly_facts: f64 = 0.0;
        let mut total_raw_facts: f64 = 0.0;
        let mut slots_processed: f64 = 0.0;
        let mut snapshot_ast = String::new();
        let mut snapshot_fact_count: usize = 0;

        // Compute position-specific facts once — identical across all slots
        // (same candle, same lens, same self-assessment). Hoisted from slot loop.
        let mut base_facts_computed = false;
        let mut base_facts: Vec<ThoughtAST> = Vec::new();

        // Process each slot sequentially.
        for slot in &slots {
            let t0 = std::time::Instant::now();
            let chain = match slot.input_rx.recv() {
                Ok(c) => c,
                Err(_) => break 'outer,
            };
            ns_slot_recv += t0.elapsed().as_nanos() as f64;

            // Collect position-specific facts — compute once from first slot's candle,
            // then clone for subsequent slots.
            let t0 = std::time::Instant::now();
            if !base_facts_computed {
                base_facts = position_lens_facts(&position_obs.lens, &chain.candle, &mut scales);
                base_facts_computed = true;
            }
            let mut slot_facts = base_facts.clone();
            ns_collect_facts += t0.elapsed().as_nanos() as f64;

            // Extract from market anomaly + raw: encode facts ONCE, cosine TWICE.
            let t0 = std::time::Instant::now();
            let market_facts = collect_facts(&chain.market_ast);
            // Pre-encode all fact ASTs into vectors — one encoding pass.
            let fact_vecs: Vec<(ThoughtAST, Vector)> = market_facts
                .into_iter()
                .map(|fact| {
                    let vec = encode(&cache, &fact, &vm, &scalar);
                    (fact, vec)
                })
                .collect();
            total_anomaly_facts += fact_vecs.len() as f64;
            for (fact, ref fact_vec) in &fact_vecs {
                let presence = holon::kernel::similarity::Similarity::cosine(fact_vec, &chain.market_anomaly);
                if presence.abs() > noise_floor {
                    slot_facts.push(ThoughtAST::Bind(
                        Box::new(ThoughtAST::Atom("market".into())),
                        Box::new(fact.clone()),
                    ));
                }
            }
            ns_extract_anomaly += t0.elapsed().as_nanos() as f64;

            // Second cosine pass against market raw — same pre-encoded vectors.
            let t0 = std::time::Instant::now();
            total_raw_facts += fact_vecs.len() as f64;
            for (fact, ref fact_vec) in &fact_vecs {
                let presence = holon::kernel::similarity::Similarity::cosine(fact_vec, &chain.market_raw);
                if presence.abs() > noise_floor {
                    slot_facts.push(ThoughtAST::Bind(
                        Box::new(ThoughtAST::Atom("market-raw".into())),
                        Box::new(fact.clone()),
                    ));
                }
            }
            ns_extract_raw += t0.elapsed().as_nanos() as f64;

            // Snapshot from slot 0.
            if slots_processed == 0.0 {
                snapshot_fact_count = slot_facts.len();
                let snapshot_bundle = ThoughtAST::Bundle(slot_facts.clone());
                snapshot_ast = snapshot_bundle.to_edn();
            }

            // Send MarketPositionChain downstream — facts only, no encoding.
            // The broker encodes when it composes with anxiety.
            let t0 = std::time::Instant::now();
            let full = MarketPositionChain {
                candle: chain.candle,
                window: chain.window,
                encode_count: chain.encode_count,
                market_raw: chain.market_raw,
                market_anomaly: chain.market_anomaly,
                market_ast: chain.market_ast,
                market_prediction: chain.prediction,
                market_edge: chain.edge,
                position_facts: slot_facts,
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
        emit_metric(&db_tx, ns, &id, &metric_dims, batch_ts, "collect_facts", ns_collect_facts, "Nanoseconds");
        emit_metric(&db_tx, ns, &id, &metric_dims, batch_ts, "extract_anomaly", ns_extract_anomaly, "Nanoseconds");
        emit_metric(&db_tx, ns, &id, &metric_dims, batch_ts, "anomaly_facts_queried", total_anomaly_facts, "Count");
        emit_metric(&db_tx, ns, &id, &metric_dims, batch_ts, "extract_raw", ns_extract_raw, "Nanoseconds");
        emit_metric(&db_tx, ns, &id, &metric_dims, batch_ts, "raw_facts_queried", total_raw_facts, "Count");
        emit_metric(&db_tx, ns, &id, &metric_dims, batch_ts, "encode_bundle", ns_encode_bundle, "Nanoseconds");
        emit_metric(&db_tx, ns, &id, &metric_dims, batch_ts, "noise_strip", ns_noise_strip, "Nanoseconds");
        emit_metric(&db_tx, ns, &id, &metric_dims, batch_ts, "send", ns_send, "Nanoseconds");
        emit_metric(&db_tx, ns, &id, &metric_dims, batch_ts, "slots_count", slots_processed, "Count");
        emit_metric(&db_tx, ns, &id, &metric_dims, batch_ts, "total", ns_total, "Nanoseconds");

        let us_elapsed = (ns_total / 1000.0) as u64;

        // Snapshot every candle.
        {
            let _ = db_tx.send(LogEntry::PositionObserverSnapshot {
                candle: candle_count,
                position_idx,
                lens: format!("{}", position_obs.lens),
                us_elapsed,
                thought_ast: snapshot_ast.clone(),
                fact_count: snapshot_fact_count,
            });
        }

        // Diagnostic every 1000 candles.
        if candle_count % 1000 == 0 {
            console.out(format!(
                "position-{}: candles={}",
                lens, candle_count,
            ));
        }
    }

    position_obs
}
