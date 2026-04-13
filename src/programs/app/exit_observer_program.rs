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
use crate::types::enums::ExitLens;
use crate::domain::exit_observer::ExitObserver;
use crate::types::log_entry::LogEntry;
use crate::domain::lens::{exit_lens_facts, exit_self_assessment_facts};
use crate::programs::chain::{MarketExitChain, MarketChain};
use crate::programs::stdlib::cache::CacheHandle;
use crate::programs::stdlib::console::ConsoleHandle;
use crate::encoding::scale_tracker::ScaleTracker;
use crate::services::mailbox::MailboxReceiver;
use crate::services::queue::{QueueReceiver, QueueSender};
use crate::trades::paper_entry::PaperEntry;

use crate::encoding::thought_encoder::{collect_facts, extract, ThoughtAST, ThoughtEncoder};
use crate::programs::telemetry::emit_metric;
use crate::to_f64;

/// Trade-state update from a broker. Contains the 10 trade atoms
/// computed from the broker's active paper. Proposal 040.
pub struct TradeUpdate {
    pub atoms: Vec<ThoughtAST>,
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

/// Compute trade atoms from a paper's state. Proposal 040.
///
/// Returns the full 10-atom vocabulary. The caller selects the subset
/// based on ExitLens (Core = first 5, Full = all 10).
pub fn compute_trade_atoms(paper: &PaperEntry, current_price: f64) -> Vec<ThoughtAST> {
    let entry = paper.entry_price.0;
    let extreme = paper.extreme;
    let excursion = ((extreme - entry) / entry).abs();
    let retracement = if excursion > 0.0001 {
        ((extreme - current_price) / (extreme - entry)).abs().min(1.0)
    } else {
        0.0
    };
    let age = paper.age as f64;

    // peak_age: candles since the extreme was last set.
    // Scan backward through price_history to find when the extreme was reached.
    let peak_age = {
        let mut pa = 0.0;
        for (i, &p) in paper.price_history.iter().enumerate().rev() {
            if (p - extreme).abs() < 1e-10 {
                pa = (paper.price_history.len() - 1 - i) as f64;
                break;
            }
        }
        pa
    };

    let signaled = if paper.signaled { 1.0 } else { 0.0 };
    let trail_distance = paper.distances.trail;
    let stop_distance = paper.distances.stop;
    let initial_risk = paper.distances.stop;
    let r_multiple = if initial_risk > 0.0001 {
        excursion / initial_risk
    } else {
        0.0
    };
    let remaining_profit = (excursion - retracement * excursion).max(0.0);
    let heat = if remaining_profit > 0.0001 {
        trail_distance / remaining_profit
    } else {
        1.0
    };
    let trail_cushion = if excursion > 0.0001 {
        ((current_price - paper.trail_level).abs() / (extreme - entry).abs()).min(1.0)
    } else {
        0.0
    };

    vec![
        // Core 5 (all three agreed)
        ThoughtAST::Log {
            name: "exit-excursion".into(),
            value: excursion.max(0.0001),
        },
        ThoughtAST::Linear {
            name: "exit-retracement".into(),
            value: retracement,
            scale: 1.0,
        },
        ThoughtAST::Log {
            name: "exit-age".into(),
            value: age.max(1.0),
        },
        ThoughtAST::Log {
            name: "exit-peak-age".into(),
            value: peak_age.max(1.0),
        },
        ThoughtAST::Linear {
            name: "exit-signaled".into(),
            value: signaled,
            scale: 1.0,
        },
        // Seykota additions
        ThoughtAST::Log {
            name: "exit-trail-distance".into(),
            value: trail_distance.max(0.0001),
        },
        ThoughtAST::Log {
            name: "exit-stop-distance".into(),
            value: stop_distance.max(0.0001),
        },
        // Van Tharp additions
        ThoughtAST::Log {
            name: "exit-r-multiple".into(),
            value: r_multiple.max(0.0001),
        },
        ThoughtAST::Linear {
            name: "exit-heat".into(),
            value: heat.min(1.0),
            scale: 1.0,
        },
        // Wyckoff addition
        ThoughtAST::Linear {
            name: "exit-trail-cushion".into(),
            value: trail_cushion,
            scale: 1.0,
        },
    ]
}

/// Select trade atoms for a given exit lens.
/// Core = first 5 (the consensus). Full = all 10 (all three voices).
pub fn select_trade_atoms(lens: &ExitLens, all_atoms: Vec<ThoughtAST>) -> Vec<ThoughtAST> {
    match lens {
        ExitLens::Core => all_atoms.into_iter().take(5).collect(),
        ExitLens::Full => all_atoms,
    }
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
    trade_rx: MailboxReceiver<TradeUpdate>,
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
        let batch_ts = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos() as u64;
        candle_count += 1;

        let ns = "exit-observer";
        let id = format!("exit:{}:{}", lens, candle_count);
        let dims = format!("{{\"lens\":\"{}\"}}", lens);

        // LEARN FIRST. Drain all pending signals before encoding.
        let t0 = std::time::Instant::now();
        drain_exit_learn(&learn_rx, &mut exit_obs);
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

        // Process each slot sequentially.
        for slot in &slots {
            let t0 = std::time::Instant::now();
            let chain = match slot.input_rx.recv() {
                Ok(c) => c,
                Err(_) => break 'outer,
            };
            ns_slot_recv += t0.elapsed().as_nanos() as f64;

            // Collect exit-specific facts through the lens.
            let t0 = std::time::Instant::now();
            let mut slot_facts = exit_lens_facts(&exit_obs.lens, &chain.candle, &mut scales);
            let self_facts = exit_self_assessment_facts(
                exit_obs.grace_rate,
                exit_obs.avg_residue,
                &mut scales,
            );
            slot_facts.extend(self_facts);
            // Add trade atoms from broker pipe (Proposal 040).
            slot_facts.extend(current_trade_atoms.clone());
            ns_collect_facts += t0.elapsed().as_nanos() as f64;

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
            ns_extract_anomaly += t0.elapsed().as_nanos() as f64;

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
            ns_extract_raw += t0.elapsed().as_nanos() as f64;

            // Encode the combined bundle.
            let t0 = std::time::Instant::now();
            let exit_bundle = ThoughtAST::Bundle(slot_facts);
            let exit_raw = encode_with_cache(&exit_bundle, &cache, &encoder);
            ns_encode_bundle += t0.elapsed().as_nanos() as f64;

            // Noise subspace learns, then strip noise.
            let t0 = std::time::Instant::now();
            exit_obs.noise_subspace.update(&to_f64(&exit_raw));
            let exit_anomaly = exit_obs.strip_noise(&exit_raw);
            ns_noise_strip += t0.elapsed().as_nanos() as f64;

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
            ns_send += t0.elapsed().as_nanos() as f64;

            slots_processed += 1.0;
        }

        let ns_total = t_total.elapsed().as_nanos() as f64;

        // Emit telemetry.
        emit_metric(&db_tx, ns, &id, &dims, batch_ts, "drain_learn", ns_drain, "Nanoseconds");
        emit_metric(&db_tx, ns, &id, &dims, batch_ts, "slot_recv", ns_slot_recv, "Nanoseconds");
        emit_metric(&db_tx, ns, &id, &dims, batch_ts, "collect_facts", ns_collect_facts, "Nanoseconds");
        emit_metric(&db_tx, ns, &id, &dims, batch_ts, "extract_anomaly", ns_extract_anomaly, "Nanoseconds");
        emit_metric(&db_tx, ns, &id, &dims, batch_ts, "anomaly_facts_queried", total_anomaly_facts, "Count");
        emit_metric(&db_tx, ns, &id, &dims, batch_ts, "extract_raw", ns_extract_raw, "Nanoseconds");
        emit_metric(&db_tx, ns, &id, &dims, batch_ts, "raw_facts_queried", total_raw_facts, "Count");
        emit_metric(&db_tx, ns, &id, &dims, batch_ts, "encode_bundle", ns_encode_bundle, "Nanoseconds");
        emit_metric(&db_tx, ns, &id, &dims, batch_ts, "noise_strip", ns_noise_strip, "Nanoseconds");
        emit_metric(&db_tx, ns, &id, &dims, batch_ts, "send", ns_send, "Nanoseconds");
        emit_metric(&db_tx, ns, &id, &dims, batch_ts, "slots_count", slots_processed, "Count");
        emit_metric(&db_tx, ns, &id, &dims, batch_ts, "total", ns_total, "Nanoseconds");

        let us_elapsed = (ns_total / 1000.0) as u64;

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
