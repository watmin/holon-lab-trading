/// broker_program.rs — the broker thread body.
///
/// Receives MarketPositionChains through a queue.
/// Submits papers to the treasury, discovers outcomes by reading.
/// Encodes anxiety atoms from active position receipts.
/// Gate 4: the Hold/Exit reckoner. Learns from anxiety. Proposes exits.
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

/// Build the broker's thought AST: position observer facts + portfolio anxiety.
/// Returns the AST so it can be encoded AND logged without recomputing.
fn broker_thought_ast(
    position_facts: &[ThoughtAST],
    active_receipts: &[PositionReceipt],
    current_candle: usize,
    current_price: f64,
) -> ThoughtAST {
    let mut facts: Vec<ThoughtAST> = position_facts.to_vec();

    let n = active_receipts.len() as f64;
    if !active_receipts.is_empty() {
        let avg_age: f64 = active_receipts.iter()
            .map(|r| (current_candle.saturating_sub(r.entry_candle)) as f64)
            .sum::<f64>() / n;
        let avg_time_pressure: f64 = active_receipts.iter()
            .map(|r| {
                let total = (r.deadline.saturating_sub(r.entry_candle)) as f64;
                let age = (current_candle.saturating_sub(r.entry_candle)) as f64;
                if total > 0.0 { age / total } else { 1.0 }
            })
            .sum::<f64>() / n;
        let avg_unrealized: f64 = active_receipts.iter()
            .map(|r| {
                let value = r.units_acquired * current_price;
                (value - r.amount) / r.amount
            })
            .sum::<f64>() / n;

        facts.push(ThoughtAST::Bind(
            Box::new(ThoughtAST::Atom("avg-paper-age".into())),
            Box::new(ThoughtAST::Log { value: avg_age.max(1.0) }),
        ));
        facts.push(ThoughtAST::Bind(
            Box::new(ThoughtAST::Atom("avg-time-pressure".into())),
            Box::new(ThoughtAST::Linear { value: avg_time_pressure, scale: 1.0 }),
        ));
        facts.push(ThoughtAST::Bind(
            Box::new(ThoughtAST::Atom("avg-unrealized-residue".into())),
            Box::new(ThoughtAST::Linear { value: avg_unrealized, scale: 1.0 }),
        ));
        facts.push(ThoughtAST::Bind(
            Box::new(ThoughtAST::Atom("active-positions".into())),
            Box::new(ThoughtAST::Log { value: n }),
        ));
    }

    ThoughtAST::Bundle(facts)
}

/// Run the broker program. Call this inside thread::spawn.
/// Returns the trained Broker when the chain source disconnects.
pub fn broker_program(
    chain_rx: QueueReceiver<MarketPositionChain>,
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

    // Gate 4 labels.
    let hold_label = holon::memory::Label::from_index(0);
    let exit_label = holon::memory::Label::from_index(1);

    while let Ok(chain) = chain_rx.recv() {
        let t_total = std::time::Instant::now();
        candle_count += 1;
        let price = chain.candle.close;
        let mut learn_grace: f64 = 0.0;
        let mut learn_violence: f64 = 0.0;
        let mut exit_proposals: f64 = 0.0;
        let mut exit_approved: f64 = 0.0;

        // 1. Direction from market prediction
        let direction = direction_from_prediction(&chain.market_prediction);
        broker.active_direction = Some(direction);

        // 2. Treasury — submit paper proposal based on market direction.
        let t0 = std::time::Instant::now();
        let (from_asset, to_asset) = if direction == Direction::Up {
            (&chain.candle.source_asset.name, &chain.candle.target_asset.name)
        } else {
            (&chain.candle.target_asset.name, &chain.candle.source_asset.name)
        };
        if let Some(receipt) = treasury.submit_paper(from_asset, to_asset, price) {
            active_receipts.push(receipt);
        }
        let ns_submit = t0.elapsed().as_nanos() as f64;

        // 3. Gate 4 — one question: do I need to get out right now?
        let t0 = std::time::Instant::now();
        let thought_ast = broker_thought_ast(&chain.position_facts, &active_receipts, candle_count, price);
        let broker_thought = encode(&cache, &thought_ast, &vm, &scalar);
        let gate_pred = broker.gate_reckoner.predict(&broker_thought);
        let wants_exit = gate_pred.direction.map_or(false, |d| d.index() == 1)
            && broker.gate_reckoner.experience() > 0.0;
        let ns_gate = t0.elapsed().as_nanos() as f64;

        // If exit: submit for all active papers. Treasury judges each one.
        let t0 = std::time::Instant::now();
        if wants_exit {
            for receipt in &active_receipts {
                exit_proposals += 1.0;
                if treasury.submit_exit(receipt.position_id, price).is_some() {
                    exit_approved += 1.0;
                }
            }
        }
        let ns_exit_submit = t0.elapsed().as_nanos() as f64;

        // 4. Check active papers — discover outcomes from treasury.
        let t0 = std::time::Instant::now();
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

            // Gate 4 learns: this moment's thought led to this outcome.
            // Grace → Hold was right. Violence → should have exited.
            let label = match outcome {
                Outcome::Grace => hold_label,
                Outcome::Violence => exit_label,
            };
            broker.gate_reckoner.observe(&broker_thought, label, 1.0);

            // Feed the curve.
            let predicted_hold = gate_pred.direction.map_or(true, |d| d.index() == 0);
            let correct = match outcome {
                Outcome::Grace => predicted_hold,
                Outcome::Violence => !predicted_hold,
            };
            broker.gate_reckoner.resolve(gate_pred.conviction, correct);

            false // resolved — remove
        });
        let ns_retain = t0.elapsed().as_nanos() as f64;

        // 5. Snapshot — same AST, just serialize.
        let t0 = std::time::Instant::now();
        let snapshot_edn = thought_ast.to_edn();
        let ns_snapshot = t0.elapsed().as_nanos() as f64;

        // 6. DB snapshot every 100 candles
        if candle_count % 100 == 0 {
            let _ = db_tx.send(LogEntry::BrokerSnapshot {
                candle: candle_count,
                broker_slot_idx: broker.slot_idx,
                grace_count: broker.grace_count,
                violence_count: broker.violence_count,
                paper_count: active_receipts.len(),
                expected_value: broker.expected_value,
                fact_count: chain.position_facts.len(),
                thought_ast: snapshot_edn.clone(),
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
        emit_metric(&db_tx, ns, &id, &metric_dims, batch_ts, "submit_paper", ns_submit, "Nanoseconds");
        emit_metric(&db_tx, ns, &id, &metric_dims, batch_ts, "gate4", ns_gate, "Nanoseconds");
        emit_metric(&db_tx, ns, &id, &metric_dims, batch_ts, "snapshot", ns_snapshot, "Nanoseconds");
        emit_metric(&db_tx, ns, &id, &metric_dims, batch_ts, "exit_submit", ns_exit_submit, "Nanoseconds");
        emit_metric(&db_tx, ns, &id, &metric_dims, batch_ts, "retain", ns_retain, "Nanoseconds");
        emit_metric(&db_tx, ns, &id, &metric_dims, batch_ts, "wants_exit", if wants_exit { 1.0 } else { 0.0 }, "Count");
        emit_metric(&db_tx, ns, &id, &metric_dims, batch_ts, "learn_grace_count", learn_grace, "Count");
        emit_metric(&db_tx, ns, &id, &metric_dims, batch_ts, "learn_violence_count", learn_violence, "Count");
        emit_metric(&db_tx, ns, &id, &metric_dims, batch_ts, "active_receipts", active_receipts.len() as f64, "Count");
        emit_metric(&db_tx, ns, &id, &metric_dims, batch_ts, "exit_proposals", exit_proposals, "Count");
        emit_metric(&db_tx, ns, &id, &metric_dims, batch_ts, "exit_approved", exit_approved, "Count");
        emit_metric(&db_tx, ns, &id, &metric_dims, batch_ts, "gate_experience", broker.gate_reckoner.experience(), "Count");

        // Console diagnostic every 1000 candles
        if candle_count % 1000 == 0 {
            let grace_rate = if broker.trade_count > 0 {
                broker.grace_count as f64 / broker.trade_count as f64
            } else {
                0.0
            };
            console.out(format!(
                "broker[{}] {}: trades={} grace={:.3} ev={:.2} active={} gate_exp={:.0}",
                broker.slot_idx,
                broker.observer_names.join("-"),
                broker.trade_count,
                grace_rate,
                broker.expected_value,
                active_receipts.len(),
                broker.gate_reckoner.experience(),
            ));
        }
    }

    // On disconnect: return the broker. The accounting comes home.
    broker
}
