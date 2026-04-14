/// position_observer_program.rs — the position observer thread body.
/// Compiled from wat/position-observer-program.wat.
///
/// Receives MarketChains through N slots (one per market observer it pairs with).
/// Per candle round, processes all N slots sequentially. Composes market thoughts
/// with position-specific facts. Learns from distance signals through a mailbox.
/// On shutdown it drains remaining learn signals and returns the observer.
/// The learned state comes home.

use std::collections::HashMap;
use std::sync::Arc;

use holon::kernel::scalar::ScalarEncoder;
use holon::kernel::vector::Vector;
use holon::kernel::vector_manager::VectorManager;

use crate::types::distances::Distances;
use crate::domain::position_observer::PositionObserver;
use crate::types::log_entry::LogEntry;
use crate::domain::lens::position_lens_facts;
use crate::encoding::encode::encode;
use crate::encoding::thought_encoder::{collect_facts, ThoughtAST};
use crate::programs::chain::{MarketPositionChain, MarketChain};
use crate::programs::stdlib::cache::CacheHandle;
use crate::programs::stdlib::console::ConsoleHandle;
use crate::encoding::scale_tracker::ScaleTracker;
use crate::services::mailbox::MailboxReceiver;
use crate::services::queue::{QueueReceiver, QueueSender};

use crate::programs::telemetry::emit_metric;
use crate::to_f64;

/// Trade-state update from a broker. Contains the 10 trade atoms
/// computed from the broker's active paper. Proposal 040.
pub struct TradeUpdate {
    pub atoms: Vec<ThoughtAST>,
}

/// Learn signal for position observers: distance labels from broker propagation.
/// Proposal 051: continuous reckoners only. No binary Grace/Violence label.
/// Weight is always 1.0 — each observation counts once. The value teaches,
/// not the magnitude of the outcome.
pub struct PositionLearn {
    pub position_thought: Vector,
    pub optimal: Distances,
}

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

/// Drain result: counts, errors, and raw predicted/optimal values for diagnostics.
struct DrainResult {
    count: usize,
    total_trail_err: f64,
    total_stop_err: f64,
    total_predicted_trail: f64,
    total_predicted_stop: f64,
    total_optimal_trail: f64,
    total_optimal_stop: f64,
}

/// Drain all pending position learn signals. Non-blocking.
fn drain_position_learn(
    learn_rx: &MailboxReceiver<PositionLearn>,
    position_obs: &mut PositionObserver,
) -> DrainResult {
    let mut r = DrainResult {
        count: 0,
        total_trail_err: 0.0,
        total_stop_err: 0.0,
        total_predicted_trail: 0.0,
        total_predicted_stop: 0.0,
        total_optimal_trail: 0.0,
        total_optimal_stop: 0.0,
    };
    while let Ok(signal) = learn_rx.try_recv() {
        let (trail_err, stop_err, pred_trail, pred_stop, opt_trail, opt_stop) =
            position_obs.observe_distances(
                &signal.position_thought,
                &signal.optimal,
            );
        r.total_trail_err += trail_err;
        r.total_stop_err += stop_err;
        r.total_predicted_trail += pred_trail;
        r.total_predicted_stop += pred_stop;
        r.total_optimal_trail += opt_trail;
        r.total_optimal_stop += opt_stop;
        r.count += 1;
    }
    r
}

/// Run the position observer program. Call this inside thread::spawn.
/// Processes N slots per candle round, sequentially.
/// Returns the trained position observer when all input slots disconnect.
pub fn position_observer_program(
    slots: Vec<PositionSlot>,
    learn_rx: MailboxReceiver<PositionLearn>,
    trade_rx: MailboxReceiver<TradeUpdate>,
    cache: CacheHandle<ThoughtAST, Vector>,
    vm: VectorManager,
    scalar: Arc<ScalarEncoder>,
    console: ConsoleHandle,
    db_tx: QueueSender<LogEntry>,
    mut position_obs: PositionObserver,
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

        // LEARN FIRST. Drain all pending signals before encoding.
        let t0 = std::time::Instant::now();
        let drain = drain_position_learn(&learn_rx, &mut position_obs);
        let learn_count = drain.count;
        let trail_err_sum = drain.total_trail_err;
        let stop_err_sum = drain.total_stop_err;
        let ns_drain = t0.elapsed().as_nanos() as f64;

        // Drain trade state updates — absorb current trade atoms.
        // Latest wins: the most recent TradeUpdate replaces any prior.
        let mut current_trade_atoms: Vec<ThoughtAST> = Vec::new();
        while let Ok(update) = trade_rx.try_recv() {
            current_trade_atoms = select_trade_atoms(&lens, update.atoms);
        }

        let mut ns_slot_recv: f64 = 0.0;
        let mut ns_collect_facts: f64 = 0.0;
        let mut ns_extract_anomaly: f64 = 0.0;
        let mut ns_extract_raw: f64 = 0.0;
        let mut ns_encode_bundle: f64 = 0.0;
        let mut ns_noise_strip: f64 = 0.0;
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
                base_facts.extend(current_trade_atoms.clone());
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

            // Encode the combined bundle.
            let t0 = std::time::Instant::now();
            // Capture fact count from slot 0 for the snapshot — use slot_facts.len()
            // directly instead of re-walking the AST with collect_facts().
            let slot_fact_count = slot_facts.len();
            let position_bundle = ThoughtAST::Bundle(slot_facts);

            if slots_processed == 0.0 {
                snapshot_fact_count = slot_fact_count;
                // rune:temper(intentional) — being blind is being incapable. Full thought logging every candle.
                snapshot_ast = position_bundle.to_edn();
            }

            let position_raw = encode(&cache, &position_bundle, &vm, &scalar);
            ns_encode_bundle += t0.elapsed().as_nanos() as f64;

            // Noise subspace learns, then strip noise — single to_f64 conversion.
            let t0 = std::time::Instant::now();
            let position_f64 = to_f64(&position_raw);
            position_obs.noise_subspace.update(&position_f64);
            let position_anomaly = Vector::from_f64(&position_obs.noise_subspace.anomalous_component(&position_f64));
            ns_noise_strip += t0.elapsed().as_nanos() as f64;

            // Distances from reckoner, or crutches if not experienced yet.
            // Proposal 053 Variant A: reckoner queries on raw thought, not anomaly.
            // The noise subspace still updates (above). The anomaly still computes
            // for the chain downstream. The reckoner just stops seeing it.
            let position_distances = position_obs.reckoner_distances(&position_raw)
                .unwrap_or(position_obs.default_distances);

            // Send MarketPositionChain downstream.
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
                position_raw,
                position_anomaly,
                position_ast: position_bundle,
                position_distances,
            };
            if slot.output_tx.send(full).is_err() {
                break 'outer;
            }
            ns_send += t0.elapsed().as_nanos() as f64;

            slots_processed += 1.0;
        }

        let ns_total = t_total.elapsed().as_nanos() as f64;

        // Emit telemetry.
        emit_metric(&db_tx, ns, &id, &metric_dims, batch_ts, "drain_learn", ns_drain, "Nanoseconds");
        emit_metric(&db_tx, ns, &id, &metric_dims, batch_ts, "learn_drained", learn_count as f64, "Count");
        if learn_count > 0 {
            let n = learn_count as f64;
            let avg_trail_err = trail_err_sum / n;
            let avg_stop_err = stop_err_sum / n;
            emit_metric(&db_tx, ns, &id, &metric_dims, batch_ts, "avg_trail_error", avg_trail_err, "Count");
            emit_metric(&db_tx, ns, &id, &metric_dims, batch_ts, "avg_stop_error", avg_stop_err, "Count");
            // Raw values — resolve the unknowns
            emit_metric(&db_tx, ns, &id, &metric_dims, batch_ts, "avg_predicted_trail", drain.total_predicted_trail / n, "Count");
            emit_metric(&db_tx, ns, &id, &metric_dims, batch_ts, "avg_predicted_stop", drain.total_predicted_stop / n, "Count");
            emit_metric(&db_tx, ns, &id, &metric_dims, batch_ts, "avg_optimal_trail", drain.total_optimal_trail / n, "Count");
            emit_metric(&db_tx, ns, &id, &metric_dims, batch_ts, "avg_optimal_stop", drain.total_optimal_stop / n, "Count");
        }
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
                trail_experience: position_obs.trail_reckoner.experience(),
                stop_experience: position_obs.stop_reckoner.experience(),
                us_elapsed,
                thought_ast: snapshot_ast.clone(),
                fact_count: snapshot_fact_count,
            });
        }

        // Diagnostic every 1000 candles.
        if candle_count % 1000 == 0 {
            console.out(format!(
                "position-{}: trail_exp={:.1} stop_exp={:.1} candles={}",
                lens, position_obs.trail_reckoner.experience(), position_obs.stop_reckoner.experience(), candle_count,
            ));
        }
    }

    // GRACEFUL SHUTDOWN. Drain learn one last time.
    let _ = drain_position_learn(&learn_rx, &mut position_obs);

    position_obs
}
