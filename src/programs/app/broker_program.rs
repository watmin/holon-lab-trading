/// broker_program.rs — the broker thread body.
/// Compiled from wat/broker-program.wat.
///
/// Receives MarketPositionChains through a queue (one per position observer slot).
/// Registers paper trades, ticks them against price, resolves them,
/// and teaches both its market observer and position observer through
/// learn handles wired at construction.
/// On shutdown it returns the broker. The accounting comes home.

use std::sync::Arc;

use holon::kernel::primitives::Primitives;
use holon::kernel::scalar::ScalarEncoder;

use crate::domain::broker::Broker;
use crate::types::enums::{Direction, Outcome};
use crate::types::log_entry::LogEntry;
use crate::types::newtypes::Price;
use crate::types::pivot::{PhaseLabel, PhaseRecord};
use crate::programs::app::position_observer_program::{PositionLearn, TradeUpdate, compute_trade_atoms};
use crate::programs::app::market_observer_program::ObsLearn;
use crate::programs::chain::MarketPositionChain;
use crate::programs::stdlib::cache::EncodingCacheHandle;
use crate::programs::stdlib::console::ConsoleHandle;
use crate::programs::telemetry::emit_metric;
use crate::encoding::thought_encoder::ThoughtAST;
use crate::services::queue::{QueueReceiver, QueueSender};

/// Compute portfolio biography atoms from broker's active papers + phase data.
/// Phase 3 (Proposal 044): 10 atoms describing the broker's portfolio shape.
fn compute_portfolio_biography(
    papers: &std::collections::VecDeque<crate::trades::paper_entry::PaperEntry>,
    phase_history: &[PhaseRecord],
    max_papers_seen: &mut usize,
) -> Vec<ThoughtAST> {
    let active: Vec<&crate::trades::paper_entry::PaperEntry> = papers
        .iter()
        .filter(|p| !p.resolved)
        .collect();
    let active_count = active.len();

    // Track max for portfolio-heat normalization.
    if active_count > *max_papers_seen {
        *max_papers_seen = active_count;
    }

    let mut atoms = Vec::with_capacity(10);

    // 1. Active trade count
    atoms.push(ThoughtAST::Bind(Box::new(ThoughtAST::Atom("active-trade-count".into())), Box::new(ThoughtAST::Log { value: (active_count as f64).max(1.0) })));

    // 2. Oldest active trade's phase age (phases since its entry)
    let oldest_phases = active
        .iter()
        .map(|p| {
            phase_history
                .iter()
                .filter(|r| r.start_candle >= p.entry_candle)
                .count()
        })
        .max()
        .unwrap_or(0);
    atoms.push(ThoughtAST::Bind(Box::new(ThoughtAST::Atom("oldest-trade-phases".into())), Box::new(ThoughtAST::Log { value: (oldest_phases as f64).max(1.0) })));

    // 3. Newest active trade's phase age
    let newest_phases = active
        .iter()
        .map(|p| {
            phase_history
                .iter()
                .filter(|r| r.start_candle >= p.entry_candle)
                .count()
        })
        .min()
        .unwrap_or(0);
    atoms.push(ThoughtAST::Bind(Box::new(ThoughtAST::Atom("newest-trade-phases".into())), Box::new(ThoughtAST::Log { value: (newest_phases as f64).max(1.0) })));

    // 4. Weighted average excursion across active trades
    let avg_excursion = if active_count > 0 {
        active.iter().map(|p| p.excursion()).sum::<f64>() / active_count as f64
    } else {
        0.0
    };
    atoms.push(ThoughtAST::Bind(Box::new(ThoughtAST::Atom("portfolio-excursion".into())), Box::new(ThoughtAST::Log { value: avg_excursion.abs().max(0.0001) })));

    // 5. Portfolio heat: active_count / max_seen
    let heat = if *max_papers_seen > 0 {
        active_count as f64 / *max_papers_seen as f64
    } else {
        0.0
    };
    atoms.push(ThoughtAST::Bind(Box::new(ThoughtAST::Atom("portfolio-heat".into())), Box::new(ThoughtAST::Linear { value: heat, scale: 1.0 })));

    // Phase trend scalars from the current candle's phase history.
    // 6. Valley trend: compare last two valley records' close_avg
    let valleys: Vec<&PhaseRecord> = phase_history
        .iter()
        .filter(|r| r.label == PhaseLabel::Valley)
        .collect();
    let valley_trend = if valleys.len() >= 2 {
        let last = valleys[valleys.len() - 1];
        let prev = valleys[valleys.len() - 2];
        if prev.close_avg > 0.0 {
            (last.close_avg - prev.close_avg) / prev.close_avg
        } else {
            0.0
        }
    } else {
        0.0
    };
    atoms.push(ThoughtAST::Bind(Box::new(ThoughtAST::Atom("broker-phase-valley-trend".into())), Box::new(ThoughtAST::Linear { value: valley_trend, scale: 1.0 })));

    // 7. Peak trend: compare last two peak records' close_avg
    let peaks: Vec<&PhaseRecord> = phase_history
        .iter()
        .filter(|r| r.label == PhaseLabel::Peak)
        .collect();
    let peak_trend = if peaks.len() >= 2 {
        let last = peaks[peaks.len() - 1];
        let prev = peaks[peaks.len() - 2];
        if prev.close_avg > 0.0 {
            (last.close_avg - prev.close_avg) / prev.close_avg
        } else {
            0.0
        }
    } else {
        0.0
    };
    atoms.push(ThoughtAST::Bind(Box::new(ThoughtAST::Atom("broker-phase-peak-trend".into())), Box::new(ThoughtAST::Linear { value: peak_trend, scale: 1.0 })));

    // 8. Regularity: stddev of phase durations / mean
    let regularity = if phase_history.len() >= 2 {
        let durations: Vec<f64> = phase_history.iter().map(|r| r.duration as f64).collect();
        let mean = durations.iter().sum::<f64>() / durations.len() as f64;
        if mean > 0.0 {
            let variance = durations.iter().map(|d| (d - mean).powi(2)).sum::<f64>()
                / durations.len() as f64;
            variance.sqrt() / mean
        } else {
            0.0
        }
    } else {
        0.0
    };
    atoms.push(ThoughtAST::Bind(Box::new(ThoughtAST::Atom("broker-phase-regularity".into())), Box::new(ThoughtAST::Linear { value: regularity, scale: 1.0 })));

    // 9. Entry ratio: fraction of active papers that entered during valley or transition-up
    let entry_ratio = if active_count > 0 {
        let favorable = active
            .iter()
            .filter(|p| {
                // Find the phase that was active at entry by checking which phase record
                // contains the entry candle.
                phase_history.iter().any(|r| {
                    p.entry_candle >= r.start_candle
                        && p.entry_candle <= r.end_candle
                        && (r.label == PhaseLabel::Valley
                            || (r.label == PhaseLabel::Transition
                                && r.direction == crate::types::pivot::PhaseDirection::Up))
                })
            })
            .count();
        favorable as f64 / active_count as f64
    } else {
        0.0
    };
    atoms.push(ThoughtAST::Bind(Box::new(ThoughtAST::Atom("broker-phase-entry-ratio".into())), Box::new(ThoughtAST::Linear { value: entry_ratio, scale: 1.0 })));

    // 10. Average spacing: mean duration of recent phases
    let avg_spacing = if !phase_history.is_empty() {
        phase_history.iter().map(|r| r.duration as f64).sum::<f64>()
            / phase_history.len() as f64
    } else {
        1.0
    };
    atoms.push(ThoughtAST::Bind(Box::new(ThoughtAST::Atom("broker-phase-avg-spacing".into())), Box::new(ThoughtAST::Log { value: avg_spacing.max(1.0) })));

    atoms
}

/// Extract Direction from a holon Prediction.
/// Label index 0 is Up, index 1 is Down. Default to Up when no direction.
fn direction_from_prediction(pred: &holon::memory::Prediction) -> Direction {
    if pred.direction.map_or(true, |d| d.index() == 0) {
        Direction::Up
    } else {
        Direction::Down
    }
}

/// Run the broker program. Call this inside thread::spawn.
/// Returns the trained Broker when the chain source disconnects.
pub fn broker_program(
    chain_rx: QueueReceiver<MarketPositionChain>,
    market_learn_tx: QueueSender<ObsLearn>,
    position_learn_tx: QueueSender<PositionLearn>,
    trade_tx: QueueSender<TradeUpdate>,
    cache: EncodingCacheHandle,
    console: ConsoleHandle,
    db_tx: QueueSender<LogEntry>,
    mut broker: Broker,
    scalar_encoder: Arc<ScalarEncoder>,
    _swap_fee: f64,
) -> Broker {
    let mut candle_count = 0usize;
    let mut max_papers_seen: usize = 0;

    while let Ok(chain) = chain_rx.recv() {
        let t_total = std::time::Instant::now();
        candle_count += 1;
        let price = chain.candle.close;
        let mut learn_up: f64 = 0.0;
        let mut learn_down: f64 = 0.0;
        let mut learn_grace: f64 = 0.0;
        let mut learn_violence: f64 = 0.0;
        let mut learn_at_boundary: f64 = 0.0;
        let mut learn_mid_phase: f64 = 0.0;
        let mut papers_resolved: f64 = 0.0;
        let mut papers_grace: f64 = 0.0;
        let mut papers_violence: f64 = 0.0;
        let mut total_paper_age: f64 = 0.0;
        let mut total_paper_excursion: f64 = 0.0;

        // Phase 4: detect phase boundary — small phase_duration means we just entered a new phase.
        let near_phase_boundary = chain.candle.phase_duration <= 5;

        // 1. Compose: market anomaly + position anomaly + portfolio biography
        //    Portfolio biography atoms (Phase 3, Proposal 044) describe the broker's
        //    portfolio shape. The broker's reckoner sees them in ITS composed thought.
        let portfolio_atoms = compute_portfolio_biography(
            &broker.papers,
            &chain.candle.phase_history,
            &mut max_papers_seen,
        );
        let portfolio_ast = ThoughtAST::Bundle(portfolio_atoms);
        let portfolio_vec = cache.get(&portfolio_ast).expect("cache driver disconnected");
        let composed = Primitives::bundle(&[&chain.market_anomaly, &chain.position_anomaly, &portfolio_vec]);

        // 2. Direction from market prediction
        let direction = direction_from_prediction(&chain.market_prediction);

        // 3. Distances from position observer's reckoner, cascaded through broker
        let distances = broker.cascade_distances(Some(chain.position_distances));

        // 4. Direction flip — close runners in old direction
        let mut flip_resolutions = Vec::new();
        if let Some(active_dir) = broker.active_direction {
            if direction != active_dir {
                flip_resolutions = broker.close_all_runners(Price(price));
            }
        }
        broker.active_direction = Some(direction);

        // Register paper — every candle, regardless of EV (Proposal 043).
        // Papers are free. The learning loop never dies.
        broker.register_paper(
            composed.clone(),
            chain.market_anomaly.clone(),
            chain.position_anomaly.clone(),
            direction,
            Price(price),
            distances,
            chain.encode_count,
        );

        // 5. Tick papers
        let (market_signals, mut runner_resolutions) = broker.tick_papers(Price(price));
        runner_resolutions.extend(flip_resolutions);

        // Count paper resolution stats for telemetry.
        for resolution in market_signals.iter().chain(runner_resolutions.iter()) {
            papers_resolved += 1.0;
            match resolution.outcome {
                Outcome::Grace => papers_grace += 1.0,
                Outcome::Violence => papers_violence += 1.0,
            }
            total_paper_age += resolution.duration as f64;
            total_paper_excursion += resolution.excursion;
        }

        // 6. Process all resolutions — propagate and teach observers
        for resolution in market_signals.iter().chain(runner_resolutions.iter()) {
            let facts = broker.propagate(
                &resolution.composed_thought,
                &resolution.market_thought,
                &resolution.position_thought,
                resolution.outcome,
                resolution.amount,
                resolution.prediction,
                &resolution.optimal_distances,
                &scalar_encoder,
            );

            // Teach market observer — directional accuracy, not trade outcome (Proposal 043).
            // Did the predicted direction match the actual price movement?
            // Correct: learn the predicted direction. Incorrect: learn the opposite.
            let direction_correct = match facts.direction {
                Direction::Up => price > resolution.entry_price,
                Direction::Down => price < resolution.entry_price,
            };
            let learn_direction = if direction_correct {
                facts.direction
            } else {
                match facts.direction {
                    Direction::Up => Direction::Down,
                    Direction::Down => Direction::Up,
                }
            };
            match learn_direction {
                Direction::Up => learn_up += 1.0,
                Direction::Down => learn_down += 1.0,
            }
            match resolution.outcome {
                Outcome::Grace => learn_grace += 1.0,
                Outcome::Violence => learn_violence += 1.0,
            }

            // Phase 4: modulate learn weight — phase boundary predictions are more valuable.
            let phase_weight = if near_phase_boundary {
                learn_at_boundary += 1.0;
                facts.weight * 2.0
            } else {
                learn_mid_phase += 1.0;
                facts.weight
            };

            let _ = market_learn_tx.send(ObsLearn {
                thought: facts.market_thought,
                direction: learn_direction,
                weight: phase_weight,
            });

            // Teach position observer — immediate resolution signal
            let is_grace = resolution.outcome == Outcome::Grace;
            let _ = position_learn_tx.send(PositionLearn {
                position_thought: facts.position_thought,
                optimal: facts.optimal,
                weight: facts.weight,
                is_grace,
                residue: if is_grace { resolution.excursion } else { 0.0 },
            });

            // Deferred batch training for position observer (runner histories)
            // Proposal 043: per-broker rolling percentile replaces EMA.
            for (thought, optimal, actual, excursion) in &resolution.position_batch {
                // Error ratio: geometry, not consequence
                let trail_err = (actual.trail - optimal.trail).abs()
                    / optimal.trail.max(0.0001);
                let stop_err = (actual.stop - optimal.stop).abs()
                    / optimal.stop.max(0.0001);
                let error = (trail_err + stop_err) / 2.0;

                // Push into rolling window, pop front if at capacity.
                if broker.journey_errors.len() >= crate::domain::broker::JOURNEY_WINDOW {
                    broker.journey_errors.pop_front();
                }
                broker.journey_errors.push_back(error);

                // Median of the window: copy, sort, take middle.
                // Runs once per batch training observation — not hot path.
                let median = {
                    let mut sorted: Vec<f64> = broker.journey_errors.iter().copied().collect();
                    sorted.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
                    sorted[sorted.len() / 2]
                };

                let is_grace = error < median;

                let _ = position_learn_tx.send(PositionLearn {
                    position_thought: thought.clone(),
                    optimal: *optimal,
                    weight: *excursion,
                    is_grace,
                    residue: *excursion,
                });
            }
        }

        // 6b. Send trade updates for ACTIVE papers (Proposal 040).
        // The position observer needs trade-state atoms to compose with market facts.
        for paper in &broker.papers {
            if !paper.resolved {
                let atoms = compute_trade_atoms(paper, price, &chain.candle.phase_history);
                let _ = trade_tx.send(TradeUpdate { atoms });
            }
        }

        // 7. DB snapshot every 100 candles
        if candle_count % 100 == 0 {
            let _ = db_tx.send(LogEntry::BrokerSnapshot {
                candle: candle_count,
                broker_slot_idx: broker.slot_idx,
                grace_count: broker.grace_count,
                violence_count: broker.violence_count,
                paper_count: broker.papers.len(),
                trail_experience: broker.scalar_accums.get(0).map_or(0.0, |a| a.count as f64),
                stop_experience: broker.scalar_accums.get(1).map_or(0.0, |a| a.count as f64),
                expected_value: broker.expected_value,
                avg_grace_net: broker.avg_grace_net,
                avg_violence_net: broker.avg_violence_net,
                fact_count: 0,
                thought_ast: String::new(),
            });
            // Phase snapshot — only slot 0 emits since phase is the same for all brokers.
            if broker.slot_idx == 0 {
                let _ = db_tx.send(LogEntry::PhaseSnapshot {
                    candle: candle_count,
                    phase_label: chain.candle.phase_label.to_string(),
                    phase_direction: chain.candle.phase_direction.to_string(),
                    phase_duration: chain.candle.phase_duration,
                    phase_count: chain.candle.phase_history.len(),
                    phase_history_len: chain.candle.phase_history.len(),
                });
            }
        }

        // Telemetry
        let ns_total = t_total.elapsed().as_nanos() as f64;
        let batch_ts = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos() as u64;
        let ns = "broker";
        let id = format!("broker:{}:{}", broker.slot_idx, candle_count);
        let dims = format!("{{\"slot\":{}}}", broker.slot_idx);
        emit_metric(&db_tx, ns, &id, &dims, batch_ts, "total", ns_total, "Nanoseconds");
        emit_metric(&db_tx, ns, &id, &dims, batch_ts, "learn_up_count", learn_up, "Count");
        emit_metric(&db_tx, ns, &id, &dims, batch_ts, "learn_down_count", learn_down, "Count");
        emit_metric(&db_tx, ns, &id, &dims, batch_ts, "learn_grace_count", learn_grace, "Count");
        emit_metric(&db_tx, ns, &id, &dims, batch_ts, "learn_violence_count", learn_violence, "Count");
        emit_metric(&db_tx, ns, &id, &dims, batch_ts, "learn_at_boundary", learn_at_boundary, "Count");
        emit_metric(&db_tx, ns, &id, &dims, batch_ts, "learn_mid_phase", learn_mid_phase, "Count");
        emit_metric(&db_tx, ns, &id, &dims, batch_ts, "papers_resolved", papers_resolved, "Count");
        emit_metric(&db_tx, ns, &id, &dims, batch_ts, "papers_grace", papers_grace, "Count");
        emit_metric(&db_tx, ns, &id, &dims, batch_ts, "papers_violence", papers_violence, "Count");
        let avg_paper_age = if papers_resolved > 0.0 { total_paper_age / papers_resolved } else { 0.0 };
        let avg_paper_excursion = if papers_resolved > 0.0 { total_paper_excursion / papers_resolved } else { 0.0 };
        emit_metric(&db_tx, ns, &id, &dims, batch_ts, "avg_paper_age", avg_paper_age, "Count");
        emit_metric(&db_tx, ns, &id, &dims, batch_ts, "avg_paper_excursion", avg_paper_excursion, "Count");

        // 8. Console diagnostic every 1000 candles
        if candle_count % 1000 == 0 {
            let grace_rate = if broker.trade_count > 0 {
                broker.grace_count as f64 / broker.trade_count as f64
            } else {
                0.0
            };
            console.out(format!(
                "broker[{}] {}: trades={} grace={:.3} ev={:.2} papers={}",
                broker.slot_idx,
                broker.observer_names.join("-"),
                broker.trade_count,
                grace_rate,
                broker.expected_value,
                broker.papers.len(),
            ));
        }
    }

    // On disconnect: return the broker. The accounting comes home.
    broker
}
