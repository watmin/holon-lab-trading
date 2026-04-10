/// Trade — a funded position with 4-phase lifecycle.

use crate::distances::Levels;
use crate::enums::{Side, TradePhase};
use crate::newtypes::TradeId;
use crate::raw_candle::Asset;

/// An active or settled trade.
#[derive(Clone, Debug)]
pub struct Trade {
    pub id: TradeId,
    pub post_idx: usize,
    pub broker_slot_idx: usize,
    pub phase: TradePhase,
    pub source_asset: Asset,
    pub target_asset: Asset,
    pub side: Side,
    pub entry_rate: f64,
    pub source_amount: f64,
    pub stop_levels: Levels,
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
        entry_rate: f64,
        source_amount: f64,
        stop_levels: Levels,
    ) -> Self {
        Self {
            id,
            post_idx,
            broker_slot_idx,
            phase: TradePhase::Active,
            source_asset,
            target_asset,
            side,
            entry_rate,
            source_amount,
            stop_levels,
            candles_held: 0,
            price_history: vec![entry_rate],
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
            Asset::new("BTC"),
            Asset::new("USD"),
            50000.0,
            1000.0,
            Levels::new(49500.0, 49000.0, 51500.0, 49250.0),
        )
    }

    #[test]
    fn test_trade_construct() {
        let t = make_test_trade();
        assert_eq!(t.id, TradeId(1));
        assert_eq!(t.phase, TradePhase::Active);
        assert_eq!(t.entry_rate, 50000.0);
        assert_eq!(t.candles_held, 0);
        assert_eq!(t.price_history.len(), 1);
        assert_eq!(t.price_history[0], 50000.0);
    }

    #[test]
    fn test_append_price_grows_history() {
        let mut t = make_test_trade();
        t.tick(50100.0);
        t.tick(50200.0);
        t.tick(50300.0);
        assert_eq!(t.candles_held, 3);
        assert_eq!(t.price_history.len(), 4); // entry + 3 ticks
        assert_eq!(t.price_history[3], 50300.0);
    }
}
