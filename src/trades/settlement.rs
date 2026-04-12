/// TreasurySettlement — what the treasury produces when a trade closes.
/// Compiled from wat/settlement.wat.
///
/// Carries the full trade, exit price, outcome, amount, and the
/// archaeological record (composed_thought, prediction) from TradeOrigin.

use holon::kernel::vector::Vector;

use crate::types::enums::{Outcome, Prediction};
use crate::types::newtypes::{Amount, Price};
use crate::trades::trade::Trade;

/// Settlement carrying all data needed for propagation.
#[derive(Clone, Debug)]
pub struct TreasurySettlement {
    pub trade: Trade,
    pub exit_price: Price,
    pub outcome: Outcome,
    pub amount: Amount,
    pub composed_thought: Vector,
    pub market_thought: Vector,
    /// The exit observer's own encoded facts. Proposal 026.
    pub exit_thought: Vector,
    pub prediction: Prediction,
}

impl TreasurySettlement {
    pub fn new(
        trade: Trade,
        exit_price: Price,
        outcome: Outcome,
        amount: Amount,
        composed_thought: Vector,
        market_thought: Vector,
        exit_thought: Vector,
        prediction: Prediction,
    ) -> Self {
        Self {
            trade,
            exit_price,
            outcome,
            amount,
            composed_thought,
            market_thought,
            exit_thought,
            prediction,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::distances::Levels;
    use crate::types::enums::Side;
    use crate::types::newtypes::{Amount, Price, TradeId};
    use crate::types::ohlcv::Asset;

    #[test]
    fn test_treasury_settlement_construct() {
        let trade = Trade::new(
            TradeId(1),
            0,
            3,
            Side::Buy,
            Asset::new("USDC"),
            Asset::new("WBTC"),
            Price(50000.0),
            Amount(1000.0),
            Levels::new(49000.0, 47500.0),
        );
        let stl = TreasurySettlement::new(
            trade,
            Price(51000.0),
            Outcome::Grace,
            Amount(50.0),
            Vector::zeros(4096),
            Vector::zeros(4096),
            Vector::zeros(4096),
            Prediction::Discrete {
                scores: vec![("Grace".into(), 0.7), ("Violence".into(), 0.3)],
                conviction: 0.7,
            },
        );
        assert_eq!(stl.exit_price, Price(51000.0));
        assert_eq!(stl.outcome, Outcome::Grace);
        assert_eq!(stl.amount, Amount(50.0));
    }

    #[test]
    fn test_settlement_carries_trade() {
        let trade = Trade::new(
            TradeId(5),
            0,
            7,
            Side::Sell,
            Asset::new("USDC"),
            Asset::new("WBTC"),
            Price(48000.0),
            Amount(500.0),
            Levels::new(49000.0, 50000.0),
        );
        let stl = TreasurySettlement::new(
            trade,
            Price(49500.0),
            Outcome::Violence,
            Amount(100.0),
            Vector::zeros(256),
            Vector::zeros(256),
            Vector::zeros(256),
            Prediction::Discrete {
                scores: vec![],
                conviction: 0.0,
            },
        );
        assert_eq!(stl.trade.id, TradeId(5));
        assert_eq!(stl.trade.broker_slot_idx, 7);
        assert_eq!(stl.outcome, Outcome::Violence);
    }
}
