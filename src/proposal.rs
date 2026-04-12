/// Proposal — what a post produces, what the treasury evaluates.
/// Compiled from wat/proposal.wat.

use holon::kernel::vector::Vector;

use crate::distances::Distances;
use crate::enums::{Prediction, Side};
use crate::raw_candle::Asset;

/// A proposal for the treasury to evaluate.
#[derive(Clone, Debug)]
pub struct Proposal {
    pub composed_thought: Vector,
    pub market_thought: Vector,
    /// The exit observer's own encoded facts. Proposal 026.
    pub exit_thought: Vector,
    pub distances: Distances,
    pub edge: f64,
    pub side: Side,
    pub source_asset: Asset,
    pub target_asset: Asset,
    pub prediction: Prediction,
    pub post_idx: usize,
    pub broker_slot_idx: usize,
}

impl Proposal {
    pub fn new(
        composed_thought: Vector,
        market_thought: Vector,
        exit_thought: Vector,
        distances: Distances,
        edge: f64,
        side: Side,
        source_asset: Asset,
        target_asset: Asset,
        prediction: Prediction,
        post_idx: usize,
        broker_slot_idx: usize,
    ) -> Self {
        Self {
            composed_thought,
            market_thought,
            exit_thought,
            distances,
            edge,
            side,
            source_asset,
            target_asset,
            prediction,
            post_idx,
            broker_slot_idx,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_proposal_construct() {
        let pred = Prediction::Discrete {
            scores: vec![("Grace".into(), 0.7), ("Violence".into(), 0.3)],
            conviction: 0.7,
        };
        let prop = Proposal::new(
            Vector::zeros(4096),
            Vector::zeros(4096),
            Vector::zeros(4096),
            Distances::new(0.02, 0.05),
            0.05,
            Side::Buy,
            Asset::new("USDC"),
            Asset::new("WBTC"),
            pred,
            0,
            3,
        );
        assert_eq!(prop.edge, 0.05);
        assert_eq!(prop.side, Side::Buy);
        assert_eq!(prop.source_asset.name, "USDC");
        assert_eq!(prop.target_asset.name, "WBTC");
        assert_eq!(prop.post_idx, 0);
        assert_eq!(prop.broker_slot_idx, 3);
        assert_eq!(prop.composed_thought.dimensions(), 4096);
        assert!((prop.distances.trail - 0.02).abs() < 1e-10);
        assert!((prop.distances.stop - 0.05).abs() < 1e-10);
    }

    #[test]
    fn test_proposal_clone() {
        let pred = Prediction::Discrete {
            scores: vec![("Grace".into(), 0.6)],
            conviction: 0.6,
        };
        let prop = Proposal::new(
            Vector::zeros(256),
            Vector::zeros(256),
            Vector::zeros(256),
            Distances::new(0.01, 0.03),
            0.1,
            Side::Sell,
            Asset::new("USDC"),
            Asset::new("WBTC"),
            pred,
            1,
            5,
        );
        let cloned = prop.clone();
        assert_eq!(cloned.post_idx, 1);
        assert_eq!(cloned.broker_slot_idx, 5);
        assert_eq!(cloned.side, Side::Sell);
    }

    #[test]
    fn test_proposal_prediction_field() {
        let pred = Prediction::Discrete {
            scores: vec![("Grace".into(), 0.8), ("Violence".into(), 0.2)],
            conviction: 0.8,
        };
        let prop = Proposal::new(
            Vector::zeros(256),
            Vector::zeros(256),
            Vector::zeros(256),
            Distances::new(0.02, 0.05),
            0.1,
            Side::Buy,
            Asset::new("USDC"),
            Asset::new("WBTC"),
            pred,
            0,
            0,
        );
        if let Prediction::Discrete { scores, conviction } = &prop.prediction {
            assert_eq!(scores.len(), 2);
            assert!((conviction - 0.8).abs() < 1e-10);
        } else {
            panic!("Expected Discrete");
        }
    }
}
