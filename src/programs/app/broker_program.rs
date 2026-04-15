/// broker_program.rs — the broker thread body.
///
/// Receives MarketPositionChains through a queue.
/// Submits papers to the treasury, discovers outcomes by reading.
/// Encodes anxiety atoms from active position receipts.
/// Owns gate 4: the Exit/Hold reckoner (to be built).
/// On shutdown it returns the broker. The accounting comes home.

use std::sync::Arc;

use holon::kernel::scalar::ScalarEncoder;
use holon::kernel::vector::Vector;
use holon::kernel::vector_manager::VectorManager;

use crate::domain::broker::Broker;
use crate::domain::treasury::{PositionReceipt, PositionState};
use crate::programs::app::treasury_program::TreasuryHandle;
use crate::types::enums::{Direction, Outcome};
use crate::types::log_entry::LogEntry;
use crate::programs::app::position_observer_program::PositionLearn;
use crate::programs::chain::MarketPositionChain;
use crate::encoding::encode::encode;
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

/// Compute anxiety atoms for one active receipt. Pure function.
/// All data from the receipt and the current candle. No placeholders.
fn anxiety_atoms(receipt: &PositionReceipt, current_candle: usize, current_price: f64) -> Vec<ThoughtAST> {
    let age = (current_candle.saturating_sub(receipt.entry_candle)) as f64;
    let total_life = (receipt.deadline.saturating_sub(receipt.entry_candle)) as f64;
    let remaining = (receipt.deadline.saturating_sub(current_candle)) as f64;
    let time_pressure = if total_life > 0.0 { age / total_life } else { 1.0 };
    let current_value = receipt.units_acquired * current_price;
    let unrealized = (current_value - receipt.amount) / receipt.amount;

    vec![
        ThoughtAST::Bind(
            Box::new(ThoughtAST::Atom("candles-remaining".into())),
            Box::new(ThoughtAST::Log { value: remaining.max(1.0) }),
        ),
        ThoughtAST::Bind(
            Box::new(ThoughtAST::Atom("time-pressure".into())),
            Box::new(ThoughtAST::Linear { value: time_pressure, scale: 1.0 }),
        ),
        ThoughtAST::Bind(
            Box::new(ThoughtAST::Atom("unrealized-residue".into())),
            Box::new(ThoughtAST::Linear { value: unrealized, scale: 1.0 }),
        ),
        ThoughtAST::Bind(
            Box::new(ThoughtAST::Atom("paper-age".into())),
            Box::new(ThoughtAST::Log { value: age.max(1.0) }),
        ),
    ]
}

/// Run the broker program. Call this inside thread::spawn.
/// Returns the trained Broker when the chain source disconnects.
pub fn broker_program(
    chain_rx: QueueReceiver<MarketPositionChain>,
    position_learn_tx: QueueSender<PositionLearn>,
    cache: CacheHandle<ThoughtAST, Vector>,
    vm: VectorManager,
    scalar: Arc<ScalarEncoder>,
    console: ConsoleHandle,
    db_tx: QueueSender<LogEntry>,
    mut broker: Broker,
    treasury: TreasuryHandle,
) -> Broker {
    let mut candle_count = 0usize;
    let mut active_receipts: Vec<PositionReceipt> = Vec::new();

    while let Ok(chain) = chain_rx.recv() {
        let t_total = std::time::Instant::now();
        candle_count += 1;
        let price = chain.candle.close;
        let mut learn_grace: f64 = 0.0;
        let mut learn_violence: f64 = 0.0;

        // 1. Direction from market prediction
        let direction = direction_from_prediction(&chain.market_prediction);
        broker.active_direction = Some(direction);

        // 2. Treasury — submit paper proposal based on market direction.
        let from_asset = if direction == Direction::Up { "USDC" } else { "WBTC" };
        let to_asset = if from_asset == "USDC" { "WBTC" } else { "USDC" };
        if let Some(receipt) = treasury.submit_paper(from_asset, to_asset, price) {
            active_receipts.push(receipt);
        }

        // 3. Check active papers — discover outcomes from treasury.
        active_receipts.retain(|receipt| {
            let state = match treasury.get_paper_state(receipt.position_id) {
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

            // Record the outcome — counts and grace rate.
            broker.record_outcome(outcome);

            // Position observer learns from the position facts encoded as a vector.
            let position_bundle = ThoughtAST::Bundle(chain.position_facts.clone());
            let position_vec = encode(&cache, &position_bundle, &vm, &scalar);
            let optimal = crate::types::distances::Distances::new(0.01, 0.01);
            let _ = position_learn_tx.send(PositionLearn {
                position_thought: position_vec,
                optimal,
            });

            false // resolved — remove
        });

        // 4. Encode anxiety atoms from active receipts.
        // The broker thinks about its positions. The thoughts are
        // encoded via cache and available for gate 4 (to be built).
        let mut all_anxiety: Vec<ThoughtAST> = Vec::new();
        for receipt in &active_receipts {
            all_anxiety.extend(anxiety_atoms(receipt, candle_count, price));
        }
        all_anxiety.push(ThoughtAST::Bind(
            Box::new(ThoughtAST::Atom("active-positions".into())),
            Box::new(ThoughtAST::Log { value: (active_receipts.len() as f64).max(1.0) }),
        ));
        let anxiety_fact_count = all_anxiety.len();
        let anxiety_bundle = ThoughtAST::Bundle(all_anxiety);
        let anxiety_edn = anxiety_bundle.to_edn();
        let _anxiety_vec = encode(&cache, &anxiety_bundle, &vm, &scalar);

        // 5. DB snapshot every 100 candles
        if candle_count % 100 == 0 {
            let _ = db_tx.send(LogEntry::BrokerSnapshot {
                candle: candle_count,
                broker_slot_idx: broker.slot_idx,
                grace_count: broker.grace_count,
                violence_count: broker.violence_count,
                paper_count: active_receipts.len(),
                expected_value: broker.expected_value,
                fact_count: anxiety_fact_count,
                thought_ast: anxiety_edn.clone(),
            });
        }

        // Phase snapshot — every candle, only slot 0.
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
        emit_metric(&db_tx, ns, &id, &metric_dims, batch_ts, "active_receipts", active_receipts.len() as f64, "Count");

        // Console diagnostic every 1000 candles
        if candle_count % 1000 == 0 {
            let grace_rate = if broker.trade_count > 0 {
                broker.grace_count as f64 / broker.trade_count as f64
            } else {
                0.0
            };
            console.out(format!(
                "broker[{}] {}: trades={} grace={:.3} ev={:.2} active={}",
                broker.slot_idx,
                broker.observer_names.join("-"),
                broker.trade_count,
                grace_rate,
                broker.expected_value,
                active_receipts.len(),
            ));
        }
    }

    // On disconnect: return the broker. The accounting comes home.
    broker
}
