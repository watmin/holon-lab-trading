/// exit_observer_program.rs — the exit observer thread body.
/// Compiled from wat/exit-observer-program.wat.
///
/// Receives MarketChains through N slots (one per market observer it pairs with).
/// Per candle round, processes all N slots sequentially. Composes market thoughts
/// with exit-specific facts. Learns from distance signals through a mailbox.
/// On shutdown it drains remaining learn signals and returns the observer.
/// The learned state comes home.

use std::collections::HashMap;
use std::sync::Arc;

use holon::kernel::vector::Vector;

use crate::types::distances::Distances;
use crate::domain::exit_observer::ExitObserver;
use crate::types::log_entry::LogEntry;
use crate::orchestration::post::{exit_lens_facts, exit_self_assessment_facts};
use crate::programs::chain::{MarketExitChain, MarketChain};
use crate::programs::stdlib::cache::CacheHandle;
use crate::programs::stdlib::console::ConsoleHandle;
use crate::encoding::scale_tracker::ScaleTracker;
use crate::services::mailbox::MailboxReceiver;
use crate::services::queue::{QueueReceiver, QueueSender};

use crate::encoding::thought_encoder::{collect_facts, extract, ThoughtAST, ThoughtEncoder};
use crate::to_f64;

/// Emit a single CloudWatch-style metric to the DB queue.
fn emit_metric(
    db_tx: &QueueSender<LogEntry>,
    namespace: &str,
    id: &str,
    dimensions: &str,
    metric_name: &str,
    metric_value: f64,
    metric_unit: &str,
) {
    let timestamp_ns = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos() as u64;
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

/// Learn signal for exit observers: distance labels from broker propagation.
pub struct ExitLearn {
    pub exit_thought: Vector,
    pub optimal: Distances,
    pub weight: f64,
    pub is_grace: bool,
    pub residue: f64,
}

/// One slot: a (receiver, sender) pair connecting one market observer to one broker.
/// input_rx is a QueueReceiver — the queue was created by the kernel.
/// The topic that fans out from the market observer writes to the queue's sender.
/// The program doesn't know about the topic. It sees a queue.
/// output_tx is a QueueSender — point-to-point to exactly one broker.
pub struct ExitSlot {
    pub input_rx: QueueReceiver<MarketChain>,
    pub output_tx: QueueSender<MarketExitChain>,
}

/// Encode with cache protocol: check -> compute -> install.
fn encode_with_cache(
    ast: &ThoughtAST,
    cache: &CacheHandle<ThoughtAST, Vector>,
    encoder: &ThoughtEncoder,
) -> Vector {
    if let Some(cached) = cache.get(ast) {
        return cached;
    }
    let (vec, misses) = encoder.encode(ast);
    cache.set(ast.clone(), vec.clone());
    for (sub_ast, sub_vec) in misses {
        cache.set(sub_ast, sub_vec);
    }
    vec
}

/// Drain all pending exit learn signals. Non-blocking.
fn drain_exit_learn(
    learn_rx: &MailboxReceiver<ExitLearn>,
    exit_obs: &mut ExitObserver,
) {
    while let Ok(signal) = learn_rx.try_recv() {
        exit_obs.observe_distances(
            &signal.exit_thought,
            &signal.optimal,
            signal.weight,
            signal.is_grace,
            signal.residue,
        );
    }
}

/// Run the exit observer program. Call this inside thread::spawn.
/// Processes N slots per candle round, sequentially.
/// Returns the trained ExitObserver when all input slots disconnect.
pub fn exit_observer_program(
    slots: Vec<ExitSlot>,
    learn_rx: MailboxReceiver<ExitLearn>,
    cache: CacheHandle<ThoughtAST, Vector>,
    console: ConsoleHandle,
    db_tx: QueueSender<LogEntry>,
    mut exit_obs: ExitObserver,
    encoder: Arc<ThoughtEncoder>,
    noise_floor: f64,
    exit_idx: usize,
) -> ExitObserver {
    let mut candle_count = 0usize;
    let mut scales: HashMap<String, ScaleTracker> = HashMap::new();
    let lens = exit_obs.lens;

    'outer: loop {
        let t_total = std::time::Instant::now();
        candle_count += 1;

        let ns = "exit-observer";
        let id = format!("exit:{}:{}", lens, candle_count);
        let dims = format!("{{\"lens\":\"{}\"}}", lens);

        // LEARN FIRST. Drain all pending signals before encoding.
        let t0 = std::time::Instant::now();
        drain_exit_learn(&learn_rx, &mut exit_obs);
        let us_drain = t0.elapsed().as_micros() as f64;

        let mut us_slot_recv: f64 = 0.0;
        let mut us_collect_facts: f64 = 0.0;
        let mut us_extract_anomaly: f64 = 0.0;
        let mut us_extract_raw: f64 = 0.0;
        let mut us_encode_bundle: f64 = 0.0;
        let mut us_noise_strip: f64 = 0.0;
        let mut us_send: f64 = 0.0;
        let mut total_anomaly_facts: f64 = 0.0;
        let mut total_raw_facts: f64 = 0.0;
        let mut slots_processed: f64 = 0.0;

        // Process each slot sequentially.
        for slot in &slots {
            let t0 = std::time::Instant::now();
            let chain = match slot.input_rx.recv() {
                Ok(c) => c,
                Err(_) => break 'outer,
            };
            us_slot_recv += t0.elapsed().as_micros() as f64;

            // Collect exit-specific facts through the lens.
            let t0 = std::time::Instant::now();
            let mut slot_facts = exit_lens_facts(&exit_obs.lens, &chain.candle, &mut scales);
            let self_facts = exit_self_assessment_facts(
                exit_obs.grace_rate,
                exit_obs.avg_residue,
                &mut scales,
            );
            slot_facts.extend(self_facts);
            us_collect_facts += t0.elapsed().as_micros() as f64;

            // Extract from market anomaly: unbind individual facts, keep those above noise floor.
            let t0 = std::time::Instant::now();
            let market_facts = collect_facts(&chain.market_ast);
            let extracted_anomaly = extract(
                &chain.market_anomaly,
                &market_facts,
                |ast| encode_with_cache(ast, &cache, &encoder),
            );
            total_anomaly_facts += market_facts.len() as f64;
            for (fact, presence) in extracted_anomaly {
                if presence.abs() > noise_floor {
                    slot_facts.push(ThoughtAST::Bind(
                        Box::new(ThoughtAST::Atom("market".into())),
                        Box::new(fact),
                    ));
                }
            }
            us_extract_anomaly += t0.elapsed().as_micros() as f64;

            // Extract from market raw: same pattern, different source binding.
            let t0 = std::time::Instant::now();
            let extracted_raw = extract(
                &chain.market_raw,
                &market_facts,
                |ast| encode_with_cache(ast, &cache, &encoder),
            );
            total_raw_facts += market_facts.len() as f64;
            for (fact, presence) in extracted_raw {
                if presence.abs() > noise_floor {
                    slot_facts.push(ThoughtAST::Bind(
                        Box::new(ThoughtAST::Atom("market-raw".into())),
                        Box::new(fact),
                    ));
                }
            }
            us_extract_raw += t0.elapsed().as_micros() as f64;

            // Encode the combined bundle.
            let t0 = std::time::Instant::now();
            let exit_bundle = ThoughtAST::Bundle(slot_facts);
            let exit_raw = encode_with_cache(&exit_bundle, &cache, &encoder);
            us_encode_bundle += t0.elapsed().as_micros() as f64;

            // Noise subspace learns, then strip noise.
            let t0 = std::time::Instant::now();
            exit_obs.noise_subspace.update(&to_f64(&exit_raw));
            let exit_anomaly = exit_obs.strip_noise(&exit_raw);
            us_noise_strip += t0.elapsed().as_micros() as f64;

            // Distances from reckoner, or crutches if not experienced yet.
            let exit_distances = exit_obs.reckoner_distances(&exit_anomaly)
                .unwrap_or(exit_obs.default_distances);

            // Send MarketExitChain downstream.
            let t0 = std::time::Instant::now();
            let full = MarketExitChain {
                candle: chain.candle,
                window: chain.window,
                encode_count: chain.encode_count,
                market_raw: chain.market_raw,
                market_anomaly: chain.market_anomaly,
                market_ast: chain.market_ast,
                market_prediction: chain.prediction,
                market_edge: chain.edge,
                exit_raw,
                exit_anomaly,
                exit_ast: exit_bundle,
                exit_distances,
            };
            if slot.output_tx.send(full).is_err() {
                break 'outer;
            }
            us_send += t0.elapsed().as_micros() as f64;

            slots_processed += 1.0;
        }

        let us_total = t_total.elapsed().as_micros() as f64;

        // Emit telemetry.
        emit_metric(&db_tx, ns, &id, &dims, "drain_learn", us_drain, "Microseconds");
        emit_metric(&db_tx, ns, &id, &dims, "slot_recv", us_slot_recv, "Microseconds");
        emit_metric(&db_tx, ns, &id, &dims, "collect_facts", us_collect_facts, "Microseconds");
        emit_metric(&db_tx, ns, &id, &dims, "extract_anomaly", us_extract_anomaly, "Microseconds");
        emit_metric(&db_tx, ns, &id, &dims, "extract_anomaly_facts", total_anomaly_facts, "Count");
        emit_metric(&db_tx, ns, &id, &dims, "extract_raw", us_extract_raw, "Microseconds");
        emit_metric(&db_tx, ns, &id, &dims, "extract_raw_facts", total_raw_facts, "Count");
        emit_metric(&db_tx, ns, &id, &dims, "encode_bundle", us_encode_bundle, "Microseconds");
        emit_metric(&db_tx, ns, &id, &dims, "noise_strip", us_noise_strip, "Microseconds");
        emit_metric(&db_tx, ns, &id, &dims, "send", us_send, "Microseconds");
        emit_metric(&db_tx, ns, &id, &dims, "slots_processed", slots_processed, "Count");
        emit_metric(&db_tx, ns, &id, &dims, "total", us_total, "Microseconds");

        let us_elapsed = us_total as u64;

        // Snapshot every candle.
        {
            let _ = db_tx.send(LogEntry::ExitObserverSnapshot {
                candle: candle_count,
                exit_idx,
                lens: format!("{}", exit_obs.lens),
                trail_experience: exit_obs.trail_reckoner.experience(),
                stop_experience: exit_obs.stop_reckoner.experience(),
                grace_rate: exit_obs.grace_rate,
                avg_residue: exit_obs.avg_residue,
                us_elapsed,
            });
        }

        // Diagnostic every 1000 candles.
        if candle_count % 1000 == 0 {
            console.out(format!(
                "exit-{}: grace_rate={:.3} avg_residue={:.4} candles={}",
                lens, exit_obs.grace_rate, exit_obs.avg_residue, candle_count,
            ));
        }
    }

    // GRACEFUL SHUTDOWN. Drain learn one last time.
    drain_exit_learn(&learn_rx, &mut exit_obs);

    exit_obs
}
