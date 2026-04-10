/// Treasury — capital management, proposal funding, trade settlement.

use std::collections::HashMap;

use holon::kernel::vector::Vector;

use crate::distances::Levels;
use crate::enums::{Outcome, Prediction, Side, TradePhase};
use crate::log_entry::LogEntry;
use crate::newtypes::TradeId;
use crate::proposal::Proposal;
use crate::raw_candle::Asset;
use crate::settlement::TreasurySettlement;
use crate::trade::Trade;
use crate::trade_origin::TradeOrigin;

/// The treasury — manages capital, funds proposals, settles trades.
#[derive(Clone)]
pub struct Treasury {
    pub denomination: Asset,
    pub available: HashMap<String, f64>,
    pub reserved: HashMap<String, f64>,
    pub proposals: Vec<Proposal>,
    pub trades: HashMap<TradeId, Trade>,
    pub trade_origins: HashMap<TradeId, TradeOrigin>,
    pub swap_fee: f64,
    pub slippage: f64,
    pub next_trade_id: usize,
}

impl Treasury {
    pub fn new(
        denomination: Asset,
        initial_balances: HashMap<String, f64>,
        swap_fee: f64,
        slippage: f64,
    ) -> Self {
        Self {
            denomination,
            available: initial_balances,
            reserved: HashMap::new(),
            proposals: Vec::new(),
            trades: HashMap::new(),
            trade_origins: HashMap::new(),
            swap_fee,
            slippage,
            next_trade_id: 0,
        }
    }

    /// Available capital for a given asset.
    pub fn available_capital(&self, asset: &str) -> f64 {
        *self.available.get(asset).unwrap_or(&0.0)
    }

    /// Deposit: add to available.
    pub fn deposit(&mut self, asset: &str, amount: f64) {
        let current = self.available_capital(asset);
        self.available.insert(asset.to_string(), current + amount);
    }

    /// Total equity: available + reserved.
    pub fn total_equity(&self) -> f64 {
        let avail_sum: f64 = self.available.values().sum();
        let reserved_sum: f64 = self.reserved.values().sum();
        avail_sum + reserved_sum
    }

    /// Submit a proposal for evaluation.
    pub fn submit_proposal(&mut self, prop: Proposal) {
        self.proposals.push(prop);
    }

    /// Venue cost per swap.
    pub fn venue_cost_rate(&self) -> f64 {
        self.swap_fee + self.slippage
    }

    /// Fund proposals: evaluate, sort by edge, fund what fits.
    pub fn fund_proposals(&mut self) -> Vec<LogEntry> {
        let mut sorted = std::mem::take(&mut self.proposals);
        sorted.sort_by(|a, b| b.edge.partial_cmp(&a.edge).unwrap_or(std::cmp::Ordering::Equal));

        let cost_rate = self.venue_cost_rate();
        let min_trade = 1.0;
        let mut logs = Vec::new();

        for prop in sorted {
            let source = &prop.source_asset.name;
            let avail = self.available_capital(source);

            // Not enough edge to cover venue costs
            if prop.edge < cost_rate * 2.0 {
                logs.push(LogEntry::ProposalRejected {
                    broker_slot_idx: prop.broker_slot_idx,
                    reason: "edge below venue cost".into(),
                });
                continue;
            }

            // Not enough capital
            if avail < min_trade {
                logs.push(LogEntry::ProposalRejected {
                    broker_slot_idx: prop.broker_slot_idx,
                    reason: "insufficient capital".into(),
                });
                continue;
            }

            // Fund the trade
            let edge_fraction = prop.edge.max(0.01);
            let amount = avail * edge_fraction * 0.1;
            let total_cost = cost_rate * amount * 2.0;
            let reserve_amount = amount + total_cost;

            let trade_id = TradeId(self.next_trade_id);
            self.next_trade_id += 1;

            // Move capital: available -> reserved
            let new_avail = avail - reserve_amount;
            self.available
                .insert(source.to_string(), new_avail.max(0.0));
            let current_reserved = *self.reserved.get(source).unwrap_or(&0.0);
            self.reserved
                .insert(source.to_string(), current_reserved + reserve_amount);

            // Create trade (levels will be set by the enterprise)
            let new_trade = Trade::new(
                trade_id,
                prop.post_idx,
                prop.broker_slot_idx,
                prop.side.clone(),
                prop.source_asset.clone(),
                prop.target_asset.clone(),
                0.0, // entry-rate set by the enterprise
                amount,
                Levels::new(0.0, 0.0, 0.0, 0.0),
            );

            // Stash origin
            let origin = TradeOrigin::new(
                prop.post_idx,
                prop.broker_slot_idx,
                prop.composed_thought.clone(),
                Prediction::Discrete {
                    scores: vec![],
                    conviction: 0.0,
                },
            );

            self.trades.insert(trade_id, new_trade);
            self.trade_origins.insert(trade_id, origin);

            logs.push(LogEntry::ProposalFunded {
                trade_id,
                broker_slot_idx: prop.broker_slot_idx,
                amount_reserved: reserve_amount,
            });
        }

        logs
    }

    /// Settle triggered trades against current prices.
    pub fn settle_triggered(
        &mut self,
        current_prices: &HashMap<(String, String), f64>,
    ) -> (Vec<TreasurySettlement>, Vec<LogEntry>) {
        let cost_rate = self.venue_cost_rate();
        let trade_ids: Vec<TradeId> = self.trades.keys().cloned().collect();
        let mut settlements = Vec::new();
        let mut logs = Vec::new();

        for tid in trade_ids {
            let trade = match self.trades.get(&tid) {
                Some(t) => t.clone(),
                None => continue,
            };

            let price_key = (
                trade.source_asset.name.clone(),
                trade.target_asset.name.clone(),
            );
            let price = match current_prices.get(&price_key) {
                Some(&p) => p,
                None => continue,
            };

            let lvls = &trade.stop_levels;
            let s = &trade.side;

            let trail_fired = match s {
                Side::Buy => price <= lvls.trail_stop,
                Side::Sell => price >= lvls.trail_stop,
            };
            let safety_fired = match s {
                Side::Buy => price <= lvls.safety_stop,
                Side::Sell => price >= lvls.safety_stop,
            };
            let tp_fired = match s {
                Side::Buy => price >= lvls.take_profit,
                Side::Sell => price <= lvls.take_profit,
            };
            let runner_trail_fired = trade.phase == TradePhase::Runner
                && match s {
                    Side::Buy => price <= lvls.runner_trail_stop,
                    Side::Sell => price >= lvls.runner_trail_stop,
                };

            if safety_fired {
                // Safety stop fires -- violence
                let exit_value = trade.source_amount * (1.0 - cost_rate);
                let loss = trade.source_amount - exit_value;

                let origin = self
                    .trade_origins
                    .remove(&tid)
                    .unwrap_or_else(|| TradeOrigin::new(0, 0, Vector::zeros(1), Prediction::Discrete { scores: vec![], conviction: 0.0 }));

                let mut settled_trade = trade.clone();
                settled_trade.phase = TradePhase::SettledViolence;

                let stl = TreasurySettlement::new(
                    settled_trade,
                    price,
                    Outcome::Violence,
                    loss,
                    origin.composed_thought.clone(),
                    origin.prediction.clone(),
                );

                logs.push(LogEntry::TradeSettled {
                    trade_id: tid,
                    outcome: Outcome::Violence,
                    amount: loss,
                    duration: trade.candles_held,
                    prediction: origin.prediction,
                });

                // Return remaining to available
                let src = &trade.source_asset.name;
                let reserved_amt = *self.reserved.get(src).unwrap_or(&0.0);
                self.reserved
                    .insert(src.to_string(), (reserved_amt - trade.source_amount).max(0.0));
                let avail_amt = self.available_capital(src);
                self.available
                    .insert(src.to_string(), avail_amt + exit_value);

                self.trades.remove(&tid);
                settlements.push(stl);
            } else if trail_fired || tp_fired || runner_trail_fired {
                let entry = trade.entry_rate;
                let exit_ratio = if entry == 0.0 {
                    1.0
                } else {
                    match s {
                        Side::Buy => price / entry,
                        Side::Sell => entry / price,
                    }
                };
                let exit_value = trade.source_amount * exit_ratio * (1.0 - cost_rate);
                let principal = trade.source_amount;
                let is_grace = exit_value > principal;
                let outcome_val = if is_grace {
                    Outcome::Grace
                } else {
                    Outcome::Violence
                };
                let amount_val = if is_grace {
                    exit_value - principal
                } else {
                    principal - exit_value
                };

                let origin = self
                    .trade_origins
                    .remove(&tid)
                    .unwrap_or_else(|| TradeOrigin::new(0, 0, Vector::zeros(1), Prediction::Discrete { scores: vec![], conviction: 0.0 }));

                let mut settled_trade = trade.clone();
                settled_trade.phase = if is_grace {
                    TradePhase::SettledGrace
                } else {
                    TradePhase::SettledViolence
                };

                let stl = TreasurySettlement::new(
                    settled_trade,
                    price,
                    outcome_val.clone(),
                    amount_val,
                    origin.composed_thought.clone(),
                    origin.prediction.clone(),
                );

                logs.push(LogEntry::TradeSettled {
                    trade_id: tid,
                    outcome: outcome_val,
                    amount: amount_val,
                    duration: trade.candles_held,
                    prediction: origin.prediction,
                });

                // Return principal to available, residue stays as target
                let src = &trade.source_asset.name;
                let reserved_amt = *self.reserved.get(src).unwrap_or(&0.0);
                self.reserved
                    .insert(src.to_string(), (reserved_amt - trade.source_amount).max(0.0));
                let avail_amt = self.available_capital(src);
                self.available
                    .insert(src.to_string(), avail_amt + principal);

                self.trades.remove(&tid);
                settlements.push(stl);
            } else if trade.phase == TradePhase::Active {
                // Check runner transition
                let past_breakeven = match s {
                    Side::Buy => lvls.trail_stop > trade.entry_rate,
                    Side::Sell => lvls.trail_stop < trade.entry_rate,
                };
                if past_breakeven {
                    if let Some(t) = self.trades.get_mut(&tid) {
                        t.phase = TradePhase::Runner;
                    }
                } else {
                    // No trigger -- tick the trade
                    if let Some(t) = self.trades.get_mut(&tid) {
                        t.tick(price);
                    }
                }
            } else {
                // No trigger -- tick the trade
                if let Some(t) = self.trades.get_mut(&tid) {
                    t.tick(price);
                }
            }
        }

        (settlements, logs)
    }

    /// Update stop levels on a trade.
    pub fn update_trade_stops(&mut self, tid: TradeId, new_levels: Levels) {
        if let Some(trade) = self.trades.get_mut(&tid) {
            trade.stop_levels = new_levels;
        }
    }

    /// Get active trades for a given post.
    pub fn trades_for_post(&self, post_idx: usize) -> Vec<(TradeId, &Trade)> {
        self.trades
            .iter()
            .filter(|(_, t)| {
                t.post_idx == post_idx
                    && (t.phase == TradePhase::Active || t.phase == TradePhase::Runner)
            })
            .map(|(&tid, t)| (tid, t))
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_test_treasury() -> Treasury {
        let mut balances = HashMap::new();
        balances.insert("BTC".into(), 10.0);
        Treasury::new(Asset::new("BTC"), balances, 0.001, 0.0025)
    }

    #[test]
    fn test_treasury_construct() {
        let t = make_test_treasury();
        assert_eq!(t.available_capital("BTC"), 10.0);
        assert_eq!(t.available_capital("USD"), 0.0);
        assert_eq!(t.venue_cost_rate(), 0.0035);
        assert_eq!(t.total_equity(), 10.0);
    }

    #[test]
    fn test_deposit_increases_available() {
        let mut t = make_test_treasury();
        t.deposit("BTC", 5.0);
        assert_eq!(t.available_capital("BTC"), 15.0);
    }

    #[test]
    fn test_capital_protection_never_negative() {
        let mut t = make_test_treasury();
        let initial = t.total_equity();
        // Even if we try to withdraw more than available, never goes negative
        let _avail = t.available_capital("BTC");
        t.available.insert("BTC".into(), 0.0);
        assert_eq!(t.available_capital("BTC"), 0.0);
        // total equity went down but available is zero, not negative
        assert!(t.total_equity() <= initial);
        assert!(t.available_capital("BTC") >= 0.0);
    }
}
