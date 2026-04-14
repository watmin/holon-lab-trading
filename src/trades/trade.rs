/// Trade — an active position the treasury holds. Compiled from wat/trade.wat.
///
/// Created when a proposal is funded. Phase transitions: Active -> Runner -> Settled*.
/// Levels has TWO fields: trail_stop and safety_stop.

use crate::types::distances::Levels;
use crate::types::enums::{Side, TradePhase};
use crate::types::newtypes::{Amount, Price, TradeId};
use crate::types::ohlcv::Asset;

/// An active or settled trade.
#[derive(Clone, Debug)]
pub struct Trade {
    pub id: TradeId,
    pub post_idx: usize,
    pub broker_slot_idx: usize,
    pub side: Side,
    pub source_asset: Asset,
    pub target_asset: Asset,
    pub entry_price: Price,
    pub amount: Amount,
    pub stop_levels: Levels,
    pub phase: TradePhase,
    pub candles_held: usize,
    pub price_history: Vec<f64>,
}

impl Trade {
    pub fn new(
        id: TradeId,
        post_idx: usize,
        broker_slot_idx: usize,
        side: Side,
        source_asset: Asset,
        target_asset: Asset,
        entry_price: Price,
        amount: Amount,
        stop_levels: Levels,
    ) -> Self {
        Self {
            id,
            post_idx,
            broker_slot_idx,
            side,
            source_asset,
            target_asset,
            entry_price,
            amount,
            stop_levels,
            phase: TradePhase::Active,
            candles_held: 0,
            price_history: vec![entry_price.0],
        }
    }

    /// Append a close price to the trade's history and increment candles_held.
    pub fn tick(&mut self, current_price: f64) {
        self.candles_held += 1;
        self.price_history.push(current_price);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_test_trade() -> Trade {
        Trade::new(
            TradeId(1),
            0,
            3,
            Side::Buy,
            Asset::new("USDC"),
            Asset::new("WBTC"),
            Price(50000.0),
            Amount(1000.0),
            Levels::new(49000.0, 47500.0),
        )
    }

    #[test]
    fn test_trade_construct() {
        let t = make_test_trade();
        assert_eq!(t.id, TradeId(1));
        assert_eq!(t.phase, TradePhase::Active);
        assert_eq!(t.entry_price, Price(50000.0));
        assert_eq!(t.amount, Amount(1000.0));
        assert_eq!(t.candles_held, 0);
        assert_eq!(t.price_history.len(), 1);
        assert_eq!(t.price_history[0], 50000.0);
    }

    #[test]
    fn test_trade_tick() {
        let mut t = make_test_trade();
        t.tick(50100.0);
        t.tick(50200.0);
        t.tick(50300.0);
        assert_eq!(t.candles_held, 3);
        assert_eq!(t.price_history.len(), 4); // entry + 3 ticks
        assert_eq!(t.price_history[3], 50300.0);
    }

    #[test]
    fn test_trade_levels_two_fields() {
        let t = make_test_trade();
        assert!((t.stop_levels.trail_stop.0 - 49000.0).abs() < 1e-10);
        assert!((t.stop_levels.safety_stop.0 - 47500.0).abs() < 1e-10);
    }

    #[test]
    fn test_trade_clone() {
        let t = make_test_trade();
        let t2 = t.clone();
        assert_eq!(t.id, t2.id);
        assert_eq!(t.entry_price, t2.entry_price);
        assert_eq!(t.phase, t2.phase);
    }
}
