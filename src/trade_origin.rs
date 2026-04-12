/// TradeOrigin — where a trade came from, for propagation routing.
/// Compiled from wat/trade-origin.wat.
///
/// The archaeological record of WHY a trade exists. Four fields.
/// Stashed by the treasury at funding time.

use holon::kernel::vector::Vector;

use crate::enums::Prediction;

/// Where a trade came from. Stashed by treasury at funding time.
#[derive(Clone, Debug)]
pub struct TradeOrigin {
    pub post_idx: usize,
    pub broker_slot_idx: usize,
    pub composed_thought: Vector,
    pub market_thought: Vector,
    /// The exit observer's own encoded facts. Proposal 026.
    pub exit_thought: Vector,
    pub prediction: Prediction,
}

impl TradeOrigin {
    pub fn new(
        post_idx: usize,
        broker_slot_idx: usize,
        composed_thought: Vector,
        market_thought: Vector,
        exit_thought: Vector,
        prediction: Prediction,
    ) -> Self {
        Self {
            post_idx,
            broker_slot_idx,
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

    #[test]
    fn test_trade_origin_construct() {
        let thought = Vector::zeros(4096);
        let pred = Prediction::Discrete {
            scores: vec![("Grace".into(), 0.6), ("Violence".into(), 0.4)],
            conviction: 0.6,
        };
        let origin = TradeOrigin::new(0, 3, thought.clone(), Vector::zeros(4096), Vector::zeros(4096), pred);
        assert_eq!(origin.post_idx, 0);
        assert_eq!(origin.broker_slot_idx, 3);
        assert_eq!(origin.composed_thought.dimensions(), 4096);
    }

    #[test]
    fn test_trade_origin_clone() {
        let origin = TradeOrigin::new(
            1,
            5,
            Vector::zeros(256),
            Vector::zeros(256),
            Vector::zeros(256),
            Prediction::Discrete {
                scores: vec![],
                conviction: 0.0,
            },
        );
        let cloned = origin.clone();
        assert_eq!(cloned.post_idx, 1);
        assert_eq!(cloned.broker_slot_idx, 5);
    }
}
