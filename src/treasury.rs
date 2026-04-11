/// Treasury — pure accounting. Compiled from wat/treasury.wat.
///
/// Holds capital (available vs reserved). Funds proposals, settles trades,
/// routes outcomes. The treasury counts. It decides based on capital
/// availability and proof curves.

use std::collections::HashMap;

use holon::kernel::vector::Vector;

use crate::distances::Levels;
use crate::enums::{Outcome, Side, TradePhase};
use crate::log_entry::LogEntry;
use crate::newtypes::TradeId;
use crate::proposal::Proposal;
use crate::raw_candle::Asset;
use crate::settlement::TreasurySettlement;
use crate::trade::Trade;
use crate::trade_origin::TradeOrigin;

/// The treasury — manages capital, funds proposals, settles trades.
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

    /// Venue cost per swap.
    pub fn venue_cost_rate(&self) -> f64 {
        self.swap_fee + self.slippage
    }

    /// Submit a proposal for evaluation.
    pub fn submit_proposal(&mut self, prop: Proposal) {
        self.proposals.push(prop);
    }

    /// Fund proposals: evaluate, sort by edge descending, fund what fits.
    /// Drain proposals when done.
    pub fn fund_proposals(&mut self) -> Vec<LogEntry> {
        let mut sorted = std::mem::take(&mut self.proposals);
        sorted.sort_by(|a, b| b.edge.partial_cmp(&a.edge).unwrap_or(std::cmp::Ordering::Equal));

        let venue_cost_rate = 2.0 * self.venue_cost_rate();
        let mut logs = Vec::new();

        for prop in sorted {
            let source = &prop.source_asset.name;
            let avail = self.available_capital(source);

            // Edge does not exceed venue cost rate — negative expected value
            if prop.edge < venue_cost_rate {
                logs.push(LogEntry::ProposalRejected {
                    broker_slot_idx: prop.broker_slot_idx,
                    reason: "edge below venue cost".into(),
                });
                continue;
            }

            // No capital available
            if avail <= 0.0 {
                logs.push(LogEntry::ProposalRejected {
                    broker_slot_idx: prop.broker_slot_idx,
                    reason: "insufficient capital".into(),
                });
                continue;
            }

            // Fund the proposal — reserve all available, trade amount
            // deducts venue cost so the round trip fits within the reservation.
            let actual_reserve = avail;
            let trade_amount = avail / (1.0 + venue_cost_rate);

            let trade_id = TradeId(self.next_trade_id);
            self.next_trade_id += 1;

            // Initial levels (will be set properly by enterprise from current price)
            let initial_levels = prop.distances.to_levels(0.0, prop.side);

            let new_trade = Trade::new(
                trade_id,
                prop.post_idx,
                prop.broker_slot_idx,
                prop.side,
                prop.source_asset.clone(),
                prop.target_asset.clone(),
                0.0, // entry price set by enterprise
                trade_amount,
                initial_levels,
            );

            // Stash origin for propagation
            let origin = TradeOrigin::new(
                prop.post_idx,
                prop.broker_slot_idx,
                prop.composed_thought.clone(),
                prop.prediction.clone(),
            );

            // Move capital: available -> reserved
            let new_avail = (avail - trade_amount).max(0.0);
            self.available.insert(source.to_string(), new_avail);
            let current_reserved = *self.reserved.get(source).unwrap_or(&0.0);
            self.reserved
                .insert(source.to_string(), current_reserved + trade_amount);

            self.trades.insert(trade_id, new_trade);
            self.trade_origins.insert(trade_id, origin);

            logs.push(LogEntry::ProposalFunded {
                trade_id,
                broker_slot_idx: prop.broker_slot_idx,
                amount_reserved: trade_amount,
            });
        }

        logs
    }

    /// Settle triggered trades. Two paths: safety_stop fires, trail_stop fires.
    pub fn settle_triggered(
        &mut self,
        current_prices: &HashMap<(String, String), f64>,
    ) -> (Vec<TreasurySettlement>, Vec<LogEntry>) {
        let venue_cost_per_swap = self.venue_cost_rate();
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

            // Safety stop check
            let safety_fired = match trade.side {
                Side::Buy => price <= lvls.safety_stop,
                Side::Sell => price >= lvls.safety_stop,
            };

            // Trail stop check
            let trail_fired = match trade.side {
                Side::Buy => price <= lvls.trail_stop,
                Side::Sell => price >= lvls.trail_stop,
            };

            if safety_fired && trade.phase == TradePhase::Active {
                // Safety stop fires -> settled-violence
                let exit_value = trade.amount * (1.0 - venue_cost_per_swap);
                let loss = trade.amount - exit_value;

                let origin = self.trade_origins.remove(&tid).unwrap_or_else(|| {
                    TradeOrigin::new(0, 0, Vector::zeros(1), crate::enums::Prediction::Discrete {
                        scores: vec![], conviction: 0.0,
                    })
                });

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

                // Return remaining to available
                let src = &trade.source_asset.name;
                let reserved_amt = *self.reserved.get(src).unwrap_or(&0.0);
                self.reserved
                    .insert(src.to_string(), (reserved_amt - trade.amount).max(0.0));
                let avail_amt = self.available_capital(src);
                self.available
                    .insert(src.to_string(), avail_amt + exit_value);

                logs.push(LogEntry::TradeSettled {
                    trade_id: tid,
                    outcome: Outcome::Violence,
                    amount: loss,
                    duration: trade.candles_held,
                    prediction: origin.prediction,
                });

                self.trades.remove(&tid);
                settlements.push(stl);
            } else if trail_fired
                && (trade.phase == TradePhase::Active || trade.phase == TradePhase::Runner)
            {
                // Trail stop fires -> outcome depends on exit vs principal
                let exit_ratio = if trade.entry_price == 0.0 {
                    1.0
                } else {
                    match trade.side {
                        Side::Buy => price / trade.entry_price,
                        Side::Sell => trade.entry_price / price,
                    }
                };
                let exit_value = trade.amount * exit_ratio * (1.0 - venue_cost_per_swap);
                let is_grace = exit_value > trade.amount;
                let outcome_val = if is_grace {
                    Outcome::Grace
                } else {
                    Outcome::Violence
                };
                let residue = (exit_value - trade.amount).abs();

                let origin = self.trade_origins.remove(&tid).unwrap_or_else(|| {
                    TradeOrigin::new(0, 0, Vector::zeros(1), crate::enums::Prediction::Discrete {
                        scores: vec![], conviction: 0.0,
                    })
                });

                let mut settled_trade = trade.clone();
                settled_trade.phase = if is_grace {
                    TradePhase::SettledGrace
                } else {
                    TradePhase::SettledViolence
                };

                let stl = TreasurySettlement::new(
                    settled_trade,
                    price,
                    outcome_val,
                    residue,
                    origin.composed_thought.clone(),
                    origin.prediction.clone(),
                );

                // Return principal to available
                let src = &trade.source_asset.name;
                let reserved_amt = *self.reserved.get(src).unwrap_or(&0.0);
                self.reserved
                    .insert(src.to_string(), (reserved_amt - trade.amount).max(0.0));
                let avail_amt = self.available_capital(src);
                self.available
                    .insert(src.to_string(), avail_amt + trade.amount.min(exit_value));

                logs.push(LogEntry::TradeSettled {
                    trade_id: tid,
                    outcome: outcome_val,
                    amount: residue,
                    duration: trade.candles_held,
                    prediction: origin.prediction,
                });

                self.trades.remove(&tid);
                settlements.push(stl);
            }
        }

        (settlements, logs)
    }

    /// Update stop levels on a trade. Also handles runner transition:
    /// when the trailing stop has moved past break-even, Active -> Runner.
    pub fn update_trade_stops(&mut self, tid: TradeId, new_levels: Levels) {
        if let Some(trade) = self.trades.get_mut(&tid) {
            trade.stop_levels = new_levels;

            // Check runner transition
            let would_recover = match trade.side {
                Side::Buy => new_levels.trail_stop > trade.entry_price,
                Side::Sell => new_levels.trail_stop < trade.entry_price,
            };

            if trade.phase == TradePhase::Active && would_recover {
                trade.phase = TradePhase::Runner;
            }
        }
    }

    /// Active trades belonging to a given post.
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
        balances.insert("USDC".into(), 10000.0);
        Treasury::new(Asset::new("USD"), balances, 0.001, 0.0025)
    }

    #[test]
    fn test_treasury_construct() {
        let t = make_test_treasury();
        assert_eq!(t.available_capital("USDC"), 10000.0);
        assert_eq!(t.available_capital("WBTC"), 0.0);
        assert!((t.venue_cost_rate() - 0.0035).abs() < 1e-10);
        assert_eq!(t.total_equity(), 10000.0);
    }

    #[test]
    fn test_deposit_increases_available() {
        let mut t = make_test_treasury();
        t.deposit("USDC", 5000.0);
        assert_eq!(t.available_capital("USDC"), 15000.0);
    }

    #[test]
    fn test_total_equity_includes_reserved() {
        let mut t = make_test_treasury();
        t.reserved.insert("USDC".into(), 2000.0);
        assert_eq!(t.total_equity(), 12000.0);
    }

    #[test]
    fn test_submit_proposal() {
        let mut t = make_test_treasury();
        let prop = Proposal::new(
            Vector::zeros(256),
            crate::distances::Distances::new(0.02, 0.05),
            0.1,
            Side::Buy,
            Asset::new("USDC"),
            Asset::new("WBTC"),
            crate::enums::Prediction::Discrete {
                scores: vec![],
                conviction: 0.0,
            },
            0,
            0,
        );
        t.submit_proposal(prop);
        assert_eq!(t.proposals.len(), 1);
    }

    #[test]
    fn test_fund_proposals_rejects_low_edge() {
        let mut t = make_test_treasury();
        let prop = Proposal::new(
            Vector::zeros(256),
            crate::distances::Distances::new(0.02, 0.05),
            0.001, // edge below venue cost
            Side::Buy,
            Asset::new("USDC"),
            Asset::new("WBTC"),
            crate::enums::Prediction::Discrete {
                scores: vec![],
                conviction: 0.0,
            },
            0,
            0,
        );
        t.submit_proposal(prop);
        let logs = t.fund_proposals();
        assert_eq!(logs.len(), 1);
        match &logs[0] {
            LogEntry::ProposalRejected { reason, .. } => {
                assert_eq!(reason, "edge below venue cost");
            }
            _ => panic!("Expected ProposalRejected"),
        }
    }

    #[test]
    fn test_fund_proposals_drains() {
        let mut t = make_test_treasury();
        let _ = t.fund_proposals();
        assert!(t.proposals.is_empty());
    }

    #[test]
    fn test_trades_for_post_filters_correctly() {
        let mut t = make_test_treasury();
        let trade = Trade::new(
            TradeId(0),
            0, // post_idx
            0,
            Side::Buy,
            Asset::new("USDC"),
            Asset::new("WBTC"),
            50000.0,
            1000.0,
            Levels::new(49000.0, 47500.0),
        );
        t.trades.insert(TradeId(0), trade);

        let for_post_0 = t.trades_for_post(0);
        let for_post_1 = t.trades_for_post(1);

        assert_eq!(for_post_0.len(), 1);
        assert_eq!(for_post_1.len(), 0);
    }

    #[test]
    fn test_update_trade_stops_runner_transition() {
        let mut t = make_test_treasury();
        let mut trade = Trade::new(
            TradeId(0),
            0,
            0,
            Side::Buy,
            Asset::new("USDC"),
            Asset::new("WBTC"),
            50000.0,
            1000.0,
            Levels::new(49000.0, 47500.0),
        );
        trade.entry_price = 50000.0;
        t.trades.insert(TradeId(0), trade);

        // New trail_stop above entry_price -> runner transition
        let new_levels = Levels::new(51000.0, 47500.0);
        t.update_trade_stops(TradeId(0), new_levels);

        assert_eq!(t.trades[&TradeId(0)].phase, TradePhase::Runner);
    }

    #[test]
    fn test_capital_never_negative() {
        let mut t = make_test_treasury();
        t.available.insert("USDC".into(), 0.0);
        assert_eq!(t.available_capital("USDC"), 0.0);
        assert!(t.available_capital("USDC") >= 0.0);
    }
}
