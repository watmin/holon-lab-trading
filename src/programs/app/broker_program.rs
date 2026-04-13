/// broker_program.rs — the broker thread body.
/// Compiled from wat/broker-program.wat.
///
/// Receives MarketExitChains through a queue (one per exit observer slot).
/// Registers paper trades, ticks them against price, resolves them,
/// and teaches both its market observer and exit observer through
/// learn handles wired at construction.
/// On shutdown it returns the broker. The accounting comes home.

use std::sync::Arc;

use holon::kernel::primitives::Primitives;
use holon::kernel::scalar::ScalarEncoder;

use crate::domain::broker::Broker;
use crate::types::enums::{Direction, Outcome};
use crate::types::log_entry::LogEntry;
use crate::types::newtypes::Price;
use crate::programs::app::exit_observer_program::{ExitLearn, TradeUpdate, compute_trade_atoms};
use crate::programs::app::market_observer_program::ObsLearn;
use crate::programs::chain::MarketExitChain;
use crate::programs::stdlib::console::ConsoleHandle;
use crate::programs::telemetry::emit_metric;
use crate::services::queue::{QueueReceiver, QueueSender};

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
    chain_rx: QueueReceiver<MarketExitChain>,
    market_learn_tx: QueueSender<ObsLearn>,
    exit_learn_tx: QueueSender<ExitLearn>,
    trade_tx: QueueSender<TradeUpdate>,
    console: ConsoleHandle,
    db_tx: QueueSender<LogEntry>,
    mut broker: Broker,
    scalar_encoder: Arc<ScalarEncoder>,
    _swap_fee: f64,
) -> Broker {
    let mut candle_count = 0usize;

    while let Ok(chain) = chain_rx.recv() {
        let t_total = std::time::Instant::now();
        candle_count += 1;
        let price = chain.candle.close;
        let mut learn_up: f64 = 0.0;
        let mut learn_down: f64 = 0.0;
        let mut learn_grace: f64 = 0.0;
        let mut learn_violence: f64 = 0.0;

        // 1. Compose: market anomaly + exit anomaly
        let composed = Primitives::bundle(&[&chain.market_anomaly, &chain.exit_anomaly]);

        // 2. Direction from market prediction
        let direction = direction_from_prediction(&chain.market_prediction);

        // 3. Distances from exit observer's reckoner, cascaded through broker
        let distances = broker.cascade_distances(Some(chain.exit_distances));

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
            chain.exit_anomaly.clone(),
            direction,
            Price(price),
            distances,
        );

        // 5. Tick papers
        let (market_signals, mut runner_resolutions) = broker.tick_papers(Price(price));
        runner_resolutions.extend(flip_resolutions);

        // 6. Process all resolutions — propagate and teach observers
        for resolution in market_signals.iter().chain(runner_resolutions.iter()) {
            let facts = broker.propagate(
                &resolution.composed_thought,
                &resolution.market_thought,
                &resolution.exit_thought,
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
            let _ = market_learn_tx.send(ObsLearn {
                thought: facts.market_thought,
                direction: learn_direction,
                weight: facts.weight,
            });

            // Teach exit observer — immediate resolution signal
            let is_grace = resolution.outcome == Outcome::Grace;
            let _ = exit_learn_tx.send(ExitLearn {
                exit_thought: facts.exit_thought,
                optimal: facts.optimal,
                weight: facts.weight,
                is_grace,
                residue: if is_grace { resolution.excursion } else { 0.0 },
            });

            // Deferred batch training for exit observer (runner histories)
            // Proposal 043: per-broker rolling percentile replaces EMA.
            for (thought, optimal, actual, excursion) in &resolution.exit_batch {
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

                let _ = exit_learn_tx.send(ExitLearn {
                    exit_thought: thought.clone(),
                    optimal: *optimal,
                    weight: *excursion,
                    is_grace,
                    residue: *excursion,
                });
            }
        }

        // 6b. Send trade updates for ACTIVE papers (Proposal 040).
        // The exit observer needs trade-state atoms to compose with market facts.
        for paper in &broker.papers {
            if !paper.resolved {
                let atoms = compute_trade_atoms(paper, price);
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
