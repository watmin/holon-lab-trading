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

use crate::broker::Broker;
use crate::enums::{Direction, Outcome};
use crate::log_entry::LogEntry;
use crate::newtypes::Price;
use crate::programs::app::exit_observer_program::ExitLearn;
use crate::programs::app::market_observer_program::ObsLearn;
use crate::programs::chain::MarketExitChain;
use crate::programs::stdlib::console::ConsoleHandle;
use crate::services::mailbox::MailboxSender;
use crate::services::queue::QueueReceiver;

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
    market_learn_tx: MailboxSender<ObsLearn>,
    exit_learn_tx: MailboxSender<ExitLearn>,
    console: ConsoleHandle,
    db_tx: MailboxSender<LogEntry>,
    mut broker: Broker,
    scalar_encoder: Arc<ScalarEncoder>,
    _swap_fee: f64,
) -> Broker {
    let mut candle_count = 0usize;

    while let Ok(chain) = chain_rx.recv() {
        candle_count += 1;
        let price = chain.candle.close;

        // 1. Compose: market anomaly + exit anomaly
        let composed = Primitives::bundle(&[&chain.market_anomaly, &chain.exit_anomaly]);

        // 2. Direction from market prediction
        let direction = direction_from_prediction(&chain.market_prediction);

        // 3. Distances — TODO: MarketExitChain should carry exit_distances from the
        //    exit observer's reckoner. For now, fall back to the broker's own
        //    cascade (accumulator → default).
        let distances = broker.cascade_distances(None);

        // 4. Direction flip — close runners in old direction
        let mut flip_resolutions = Vec::new();
        if broker.gate_open() {
            if let Some(active_dir) = broker.active_direction {
                if direction != active_dir {
                    flip_resolutions = broker.close_all_runners(Price(price));
                }
            }
            broker.active_direction = Some(direction);

            // Register paper
            broker.register_paper(
                composed.clone(),
                chain.market_anomaly.clone(),
                chain.exit_anomaly.clone(),
                direction,
                Price(price),
                distances,
            );
        }

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

            // Teach market observer
            let _ = market_learn_tx.send(ObsLearn {
                thought: facts.market_thought,
                direction: facts.direction,
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
            for (thought, optimal, weight) in &resolution.exit_batch {
                let _ = exit_learn_tx.send(ExitLearn {
                    exit_thought: thought.clone(),
                    optimal: *optimal,
                    weight: *weight,
                    is_grace: true,
                    residue: *weight,
                });
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

        // 8. Console diagnostic every 1000 candles
        if candle_count % 1000 == 0 {
            let grace_rate = if broker.trade_count > 0 {
                broker.grace_count as f64 / broker.trade_count as f64
            } else {
                0.0
            };
            console.out(format!(
                "broker[{}]: trades={} grace={:.3} ev={:.2} papers={}",
                broker.slot_idx,
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
