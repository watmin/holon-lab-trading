/// TreasurySettlement — what the treasury produces when a trade settles.
/// Carries prediction for learning propagation.

use holon::kernel::vector::Vector;

use crate::enums::{Outcome, Prediction};
use crate::trade::Trade;

/// Settlement carrying all data needed for propagation.
#[derive(Clone, Debug)]
pub struct TreasurySettlement {
    pub trade: Trade,
    pub exit_price: f64,
    pub outcome: Outcome,
    pub amount: f64,
    pub composed_thought: Vector,
    pub prediction: Prediction,
}

impl TreasurySettlement {
    pub fn new(
        trade: Trade,
        exit_price: f64,
        outcome: Outcome,
        amount: f64,
        composed_thought: Vector,
        prediction: Prediction,
    ) -> Self {
        Self {
            trade,
            exit_price,
            outcome,
            amount,
            composed_thought,
            prediction,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::distances::Levels;
    use crate::enums::Side;
    use crate::newtypes::TradeId;
    use crate::raw_candle::Asset;

    #[test]
    fn test_treasury_settlement_construct() {
        let trade = Trade::new(
            TradeId(1),
            0,
            3,
            Side::Buy,
            Asset::new("BTC"),
            Asset::new("USD"),
            50000.0,
            1000.0,
            Levels::new(49500.0, 49000.0, 51500.0, 49250.0),
        );
        let stl = TreasurySettlement::new(
            trade,
            51000.0,
            Outcome::Grace,
            50.0,
            Vector::zeros(4096),
            Prediction::Discrete {
                scores: vec![("Grace".into(), 0.7), ("Violence".into(), 0.3)],
                conviction: 0.7,
            },
        );
        assert_eq!(stl.exit_price, 51000.0);
        assert_eq!(stl.outcome, Outcome::Grace);
        assert_eq!(stl.amount, 50.0);
    }
}
