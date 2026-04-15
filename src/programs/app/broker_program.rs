/// broker_program.rs — the broker thread body.
/// Compiled from wat/broker-program.wat.
///
/// Receives MarketPositionChains through a queue (one per position observer slot).
/// Submits papers to the treasury, discovers outcomes by reading treasury state,
/// and teaches both its market observer and position observer through
/// learn handles wired at construction.
/// On shutdown it returns the broker. The accounting comes home.

use std::sync::Arc;

use holon::kernel::primitives::Primitives;
use holon::kernel::scalar::ScalarEncoder;
use holon::kernel::vector::Vector;
use holon::kernel::vector_manager::VectorManager;

use crate::domain::broker::Broker;
use crate::domain::treasury::PositionState;
use crate::programs::app::treasury_program::TreasuryHandle;
use crate::types::enums::{Direction, Outcome};
use crate::types::log_entry::LogEntry;
use crate::programs::app::position_observer_program::PositionLearn;
use crate::programs::chain::MarketPositionChain;
use crate::encoding::thought_encoder::ThoughtAST;
use crate::programs::stdlib::cache::CacheHandle;
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
    chain_rx: QueueReceiver<MarketPositionChain>,
    position_learn_tx: QueueSender<PositionLearn>,
    _trade_tx: QueueSender<crate::programs::app::position_observer_program::TradeUpdate>,
    _cache: CacheHandle<ThoughtAST, Vector>,
    _vm: VectorManager,
    scalar: Arc<ScalarEncoder>,
    console: ConsoleHandle,
    db_tx: QueueSender<LogEntry>,
    mut broker: Broker,
    treasury: TreasuryHandle,
) -> Broker {
    let mut candle_count = 0usize;
    let mut active_paper_ids: Vec<u64> = Vec::new();

    while let Ok(chain) = chain_rx.recv() {
        let t_total = std::time::Instant::now();
        candle_count += 1;
        let price = chain.candle.close;
        let mut learn_grace: f64 = 0.0;
        let mut learn_violence: f64 = 0.0;

        // 1. Compose: market anomaly + position anomaly
        let composed = Primitives::bundle(&[&chain.market_anomaly, &chain.position_anomaly]);

        // 2. Direction from market prediction
        let direction = direction_from_prediction(&chain.market_prediction);
        broker.active_direction = Some(direction);

        // 3. Distances from position observer's reckoner, cascaded through broker
        let _distances = broker.cascade_distances(Some(chain.position_distances), &scalar);

        // 4. Treasury interaction — submit paper proposal based on market direction.
        let from_asset = if direction == Direction::Up { "USDC" } else { "WBTC" };
        let to_asset = if from_asset == "USDC" { "WBTC" } else { "USDC" };
        if let Some(receipt) = treasury.submit_paper(
            from_asset,
            to_asset,
            price,
        ) {
            active_paper_ids.push(receipt.position_id);
        }

        // 5. Check active papers — discover outcomes from treasury.
        active_paper_ids.retain(|&id| {
            let state = match treasury.get_paper_state(id) {
                Some(s) => s,
                None => return false,
            };

            let outcome = match state {
                PositionState::Active => return true,
                PositionState::Violence => {
                    learn_violence += 1.0;
                    Outcome::Violence
                }
                PositionState::Grace { .. } => {
                    learn_grace += 1.0;
                    Outcome::Grace
                }
            };

            // Each observation counts once. The outcome is the label.
            let weight = 1.0;
            let optimal = crate::types::distances::Distances::new(0.01, 0.01);
            let facts = broker.propagate(
                &composed,
                &chain.market_anomaly,
                &chain.position_raw,
                outcome,
                weight,
                direction,
                &optimal,
                &scalar,
            );

            // Position observer learns from broker propagation.
            let _ = position_learn_tx.send(PositionLearn {
                position_thought: facts.position_thought,
                optimal: facts.optimal,
            });

            false // resolved — remove from active list
        });

        // 6. DB snapshot every 100 candles
        if candle_count % 100 == 0 {
            let _ = db_tx.send(LogEntry::BrokerSnapshot {
                candle: candle_count,
                broker_slot_idx: broker.slot_idx,
                grace_count: broker.grace_count,
                violence_count: broker.violence_count,
                paper_count: active_paper_ids.len(),
                trail_experience: broker.trail_accum.count as f64,
                stop_experience: broker.stop_accum.count as f64,
                expected_value: broker.expected_value,
                avg_grace_net: broker.avg_grace_net,
                avg_violence_net: broker.avg_violence_net,
                fact_count: 0,
                // rune:temper(intentional) — being blind is being incapable
                thought_ast: String::new(),
            });
        }
        // Phase snapshot — every candle, only slot 0. Phases last ~6 candles,
        // every-100 misses the structure entirely.
        if broker.slot_idx == 0 {
            let _ = db_tx.send(LogEntry::PhaseSnapshot {
                candle: candle_count,
                close: price,
                phase_label: chain.candle.phase_label.to_string(),
                phase_direction: chain.candle.phase_direction.to_string(),
                phase_duration: chain.candle.phase_duration,
                phase_count: chain.candle.phase_history.len(),
                phase_history_len: chain.candle.phase_history.len(),
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
        let metric_dims = format!("{{\"slot\":{}}}", broker.slot_idx);
        emit_metric(&db_tx, ns, &id, &metric_dims, batch_ts, "total", ns_total, "Nanoseconds");
        emit_metric(&db_tx, ns, &id, &metric_dims, batch_ts, "learn_grace_count", learn_grace, "Count");
        emit_metric(&db_tx, ns, &id, &metric_dims, batch_ts, "learn_violence_count", learn_violence, "Count");

        // 7. Console diagnostic every 1000 candles
        if candle_count % 1000 == 0 {
            let grace_rate = if broker.trade_count > 0 {
                broker.grace_count as f64 / broker.trade_count as f64
            } else {
                0.0
            };
            console.out(format!(
                "broker[{}] {}: trades={} grace={:.3} ev={:.2} active_papers={}",
                broker.slot_idx,
                broker.observer_names.join("-"),
                broker.trade_count,
                grace_rate,
                broker.expected_value,
                active_paper_ids.len(),
            ));
        }
    }

    // On disconnect: return the broker. The accounting comes home.
    broker
}
