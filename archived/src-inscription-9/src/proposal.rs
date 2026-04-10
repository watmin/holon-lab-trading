/// Proposal — assembled by the post during step-compute-dispatch.

use holon::kernel::vector::Vector;

use crate::distances::Distances;
use crate::enums::Side;
use crate::raw_candle::Asset;

/// A proposal for the treasury to evaluate. No prediction — just data.
#[derive(Clone, Debug)]
pub struct Proposal {
    pub composed_thought: Vector,
    pub distances: Distances,
    pub edge: f64,
    pub side: Side,
    pub source_asset: Asset,
    pub target_asset: Asset,
    pub post_idx: usize,
    pub broker_slot_idx: usize,
}

impl Proposal {
    pub fn new(
        composed_thought: Vector,
        distances: Distances,
        edge: f64,
        side: Side,
        source_asset: Asset,
        target_asset: Asset,
        post_idx: usize,
        broker_slot_idx: usize,
    ) -> Self {
        Self {
            composed_thought,
            distances,
            edge,
            side,
            source_asset,
            target_asset,
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
        let prop = Proposal::new(
            Vector::zeros(4096),
            Distances::new(0.01, 0.02, 0.03, 0.015),
            0.05,
            Side::Buy,
            Asset::new("BTC"),
            Asset::new("USD"),
            0,
            3,
        );
        assert_eq!(prop.edge, 0.05);
        assert_eq!(prop.side, Side::Buy);
        assert_eq!(prop.source_asset.name, "BTC");
        assert_eq!(prop.target_asset.name, "USD");
        assert_eq!(prop.post_idx, 0);
        assert_eq!(prop.broker_slot_idx, 3);
        assert_eq!(prop.composed_thought.dimensions(), 4096);
        assert_eq!(prop.distances.trail, 0.01);
    }
}
