/// broker_program.rs — the broker thread body.
///
/// Receives MarketRegimeChains through a queue.
/// Submits papers to the treasury, discovers outcomes by reading.
/// Composes the full thought: market rhythms + regime rhythms +
/// portfolio rhythms + phase rhythm + time facts.
/// Gate 4: the Hold/Exit reckoner. Strips noise, reads the anomaly,
/// predicts Hold or Exit.
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
use crate::vocab::broker::portfolio::{PortfolioSnapshot, portfolio_rhythm_asts};
use crate::vocab::exit::phase::phase_rhythm_thought;
use crate::vocab::shared::time::time_facts;
use crate::programs::chain::MarketRegimeChain;
use crate::encoding::encode::{encode, take_encode_metrics, EncodeState};
use crate::encoding::thought_encoder::{ThoughtAST, ThoughtASTKind};
use crate::programs::stdlib::cache::CacheHandle;
use crate::programs::stdlib::console::ConsoleHandle;
use crate::programs::stdlib::database::DatabaseHandle;
use crate::programs::telemetry::{emit_metric, flush_metrics};
use crate::services::queue::QueueReceiver;


/// Build the broker's thought AST: market rhythms + regime rhythms + portfolio rhythms + phase + time.
/// Returns the AST so it can be encoded AND logged without recomputing.
fn broker_thought_ast(
    market_ast: &ThoughtAST,
    regime_facts: &[ThoughtAST],
    portfolio_window: &[PortfolioSnapshot],
    candle: &crate::types::candle::Candle,
) -> ThoughtAST {
    let mut facts: Vec<ThoughtAST> = Vec::new();

    // Market rhythms — the market observer's rhythms, no time.
    facts.push(market_ast.clone());

    // Regime rhythms — each one an indicator rhythm AST
    facts.extend(regime_facts.iter().cloned());

    // Portfolio rhythms — the broker's own state as streams
    facts.extend(portfolio_rhythm_asts(portfolio_window));

    // Phase rhythm — bundled bigrams of trigrams with structural deltas
    facts.push(phase_rhythm_thought(&candle.phase_history));

    // Time — 5 leaf binds + 3 pairwise compositions
    facts.extend(time_facts(candle));

    ThoughtAST::new(ThoughtASTKind::Bundle(facts))
}

/// Run the broker program. Call this inside thread::spawn.
/// Returns the trained Broker when the chain source disconnects.
pub fn broker_program(
    chain_rx: QueueReceiver<MarketRegimeChain>,
    cache: CacheHandle<u64, Vector>,
    vm: VectorManager,
    scalar: Arc<ScalarEncoder>,
    console: ConsoleHandle,
    db_tx: DatabaseHandle<LogEntry>,
    mut broker: Broker,
    treasury: TreasuryHandle,
) -> Broker {
    let mut candle_count = 0usize;
    let mut active_receipts: Vec<PositionReceipt> = Vec::new();
    let mut portfolio_window: Vec<PortfolioSnapshot> = Vec::new();
    let max_portfolio_window = ((vm.dimensions() as f64).sqrt() as usize) + 3;
    let mut encode_state = EncodeState::new();

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
        let direction = Direction::from(&chain.market_prediction);
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

        // Compute portfolio snapshot and push to window.
        let n = active_receipts.len() as f64;
        let snap = PortfolioSnapshot {
            avg_age: if n > 0.0 {
                active_receipts.iter()
                    .map(|r| (candle_count.saturating_sub(r.entry_candle)) as f64)
                    .sum::<f64>() / n
            } else { 0.0 },
            avg_tp: if n > 0.0 {
                active_receipts.iter()
                    .map(|r| {
                        let total = (r.deadline.saturating_sub(r.entry_candle)) as f64;
                        let age = (candle_count.saturating_sub(r.entry_candle)) as f64;
                        if total > 0.0 { age / total } else { 1.0 }
                    })
                    .sum::<f64>() / n
            } else { 0.0 },
            avg_unrealized: if n > 0.0 {
                active_receipts.iter()
                    .map(|r| {
                        let value = r.units_acquired * price;
                        (value - r.amount) / r.amount
                    })
                    .sum::<f64>() / n
            } else { 0.0 },
            grace_rate: broker.expected_value,
            active_count: n,
        };
        portfolio_window.push(snap);
        if portfolio_window.len() > max_portfolio_window {
            portfolio_window.drain(..portfolio_window.len() - max_portfolio_window);
        }

        // 3. Gate 4 — one question: do I need to get out right now?
        let t0 = std::time::Instant::now();
        let thought_ast = broker_thought_ast(
            &chain.market_ast,
            &chain.regime_facts,
            &portfolio_window,
            &chain.candle,
        );
        let broker_thought = encode(&mut encode_state, &cache, &thought_ast, &vm, &scalar);
        let broker_enc_metrics = take_encode_metrics();
        let ns_broker_encode = t0.elapsed().as_nanos() as f64;

        // Noise subspace: train on the composed thought, extract the anomaly.
        let t0 = std::time::Instant::now();
        let thought_f64 = crate::to_f64(&broker_thought);
        broker.noise_subspace.update(&thought_f64);
        let anomaly_f64 = broker.noise_subspace.anomalous_component(&thought_f64);
        let anomaly = holon::kernel::vector::Vector::from_f64(&anomaly_f64);
        let ns_noise = t0.elapsed().as_nanos() as f64;

        // Gate 4 predicts from the anomaly — what's unusual about this moment.
        let t0 = std::time::Instant::now();
        let gate_pred = broker.gate_reckoner.predict(&anomaly);
        let wants_exit = gate_pred.direction.map_or(false, |d| d.index() == 1)
            && broker.gate_reckoner.experience() > 0.0;
        let ns_predict = t0.elapsed().as_nanos() as f64;
        let ns_gate = ns_broker_encode + ns_noise + ns_predict;

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

        // 4. Check active papers — one batch round-trip to treasury.
        let t0 = std::time::Instant::now();
        if !active_receipts.is_empty() {
            let paper_ids: Vec<u64> = active_receipts.iter().map(|r| r.position_id).collect();
            let states = treasury.batch_get_paper_states(paper_ids);

            // Build a lookup from the batch response.
            let state_map: std::collections::HashMap<u64, Option<PositionState>> =
                states.into_iter().collect();

            active_receipts.retain(|receipt| {
                let state = match state_map.get(&receipt.position_id) {
                    Some(Some(s)) => s,
                    _ => return false,
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
                broker.gate_reckoner.observe(&anomaly, label, 1.0);

                // Feed the curve.
                let predicted_hold = gate_pred.direction.map_or(true, |d| d.index() == 0);
                let correct = match outcome {
                    Outcome::Grace => predicted_hold,
                    Outcome::Violence => !predicted_hold,
                };
                broker.gate_reckoner.resolve(gate_pred.conviction, correct);

                false // resolved — remove
            });
        }
        let ns_retain = t0.elapsed().as_nanos() as f64;

        // 5. Snapshot — AST serialization disabled for rhythm ASTs.
        // rune:temper(disabled) — rhythm ASTs are multi-MB EDN strings.
        let t0 = std::time::Instant::now();
        // let snapshot_edn = thought_ast.to_edn();
        let snapshot_edn = String::from("disabled:rhythm-ast-too-large");
        let ns_snapshot = t0.elapsed().as_nanos() as f64;

        // Collect all log entries into a pending vec, flush once.
        let mut pending = Vec::new();

        // 6. DB snapshot every 100 candles
        if candle_count % 100 == 0 {
            pending.push(LogEntry::BrokerSnapshot {
                candle: candle_count,
                broker_slot_idx: broker.slot_idx,
                grace_count: broker.grace_count,
                violence_count: broker.violence_count,
                paper_count: active_receipts.len(),
                expected_value: broker.expected_value,
                fact_count: chain.regime_facts.len(),
                thought_ast: snapshot_edn.clone(),
            });
        }

        // Phase snapshot — every candle, only slot 0.
        if broker.slot_idx == 0 {
            pending.push(LogEntry::PhaseSnapshot {
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
        emit_metric(&mut pending, ns, &id, &metric_dims, batch_ts, "total", ns_total, "Nanoseconds");
        emit_metric(&mut pending, ns, &id, &metric_dims, batch_ts, "submit_paper", ns_submit, "Nanoseconds");
        emit_metric(&mut pending, ns, &id, &metric_dims, batch_ts, "gate4", ns_gate, "Nanoseconds");
        emit_metric(&mut pending, ns, &id, &metric_dims, batch_ts, "gate4_encode", ns_broker_encode, "Nanoseconds");
        emit_metric(&mut pending, ns, &id, &metric_dims, batch_ts, "gate4_noise", ns_noise, "Nanoseconds");
        emit_metric(&mut pending, ns, &id, &metric_dims, batch_ts, "gate4_predict", ns_predict, "Nanoseconds");
        emit_metric(&mut pending, ns, &id, &metric_dims, batch_ts, "gate4_enc_nodes", broker_enc_metrics.nodes_walked as f64, "Count");
        emit_metric(&mut pending, ns, &id, &metric_dims, batch_ts, "gate4_enc_hits", broker_enc_metrics.cache_hits as f64, "Count");
        emit_metric(&mut pending, ns, &id, &metric_dims, batch_ts, "gate4_enc_misses", broker_enc_metrics.cache_misses as f64, "Count");
        emit_metric(&mut pending, ns, &id, &metric_dims, batch_ts, "gate4_enc_ns_batch_get", broker_enc_metrics.ns_batch_get as f64, "Nanoseconds");
        emit_metric(&mut pending, ns, &id, &metric_dims, batch_ts, "gate4_enc_batch_rounds", broker_enc_metrics.batch_rounds as f64, "Count");
        emit_metric(&mut pending, ns, &id, &metric_dims, batch_ts, "gate4_enc_l1_hits", broker_enc_metrics.l1_hits as f64, "Count");
        emit_metric(&mut pending, ns, &id, &metric_dims, batch_ts, "gate4_enc_l1_misses", broker_enc_metrics.l1_misses as f64, "Count");
        emit_metric(&mut pending, ns, &id, &metric_dims, batch_ts, "gate4_enc_ns_compute", broker_enc_metrics.ns_compute as f64, "Nanoseconds");
        emit_metric(&mut pending, ns, &id, &metric_dims, batch_ts, "gate4_enc_forms_computed", broker_enc_metrics.forms_computed as f64, "Count");
        emit_metric(&mut pending, ns, &id, &metric_dims, batch_ts, "snapshot", ns_snapshot, "Nanoseconds");
        emit_metric(&mut pending, ns, &id, &metric_dims, batch_ts, "exit_submit", ns_exit_submit, "Nanoseconds");
        emit_metric(&mut pending, ns, &id, &metric_dims, batch_ts, "retain", ns_retain, "Nanoseconds");
        emit_metric(&mut pending, ns, &id, &metric_dims, batch_ts, "wants_exit", if wants_exit { 1.0 } else { 0.0 }, "Count");
        emit_metric(&mut pending, ns, &id, &metric_dims, batch_ts, "learn_grace_count", learn_grace, "Count");
        emit_metric(&mut pending, ns, &id, &metric_dims, batch_ts, "learn_violence_count", learn_violence, "Count");
        emit_metric(&mut pending, ns, &id, &metric_dims, batch_ts, "active_receipts", active_receipts.len() as f64, "Count");
        emit_metric(&mut pending, ns, &id, &metric_dims, batch_ts, "exit_proposals", exit_proposals, "Count");
        emit_metric(&mut pending, ns, &id, &metric_dims, batch_ts, "exit_approved", exit_approved, "Count");
        emit_metric(&mut pending, ns, &id, &metric_dims, batch_ts, "gate_experience", broker.gate_reckoner.experience(), "Count");

        // One batch send per candle.
        flush_metrics(&db_tx, &mut pending);

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
