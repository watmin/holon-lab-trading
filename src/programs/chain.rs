/// Pipeline chain types. Pure data. Each stage produces a new value.
/// The type IS the proof of which stage produced it.
/// No methods. No behavior. Values on the wire.

use std::sync::Arc;

use holon::kernel::vector::Vector;

use crate::types::candle::Candle;
use crate::types::distances::Distances;
use crate::encoding::thought_encoder::ThoughtAST;

/// What the market observer produces. What the position observer receives.
#[derive(Clone)]
pub struct MarketChain {
    pub candle: Candle,
    pub window: Arc<Vec<Candle>>,
    pub encode_count: usize,
    pub market_raw: Vector,
    pub market_anomaly: Vector,
    pub market_ast: ThoughtAST,
    pub prediction: holon::memory::Prediction,
    pub edge: f64,
}

/// What the position observer produces. What the broker receives.
pub struct MarketPositionChain {
    pub candle: Candle,
    pub window: Arc<Vec<Candle>>,
    pub encode_count: usize,
    pub market_raw: Vector,
    pub market_anomaly: Vector,
    pub market_ast: ThoughtAST,
    pub market_prediction: holon::memory::Prediction,
    pub market_edge: f64,
    pub position_raw: Vector,
    pub position_anomaly: Vector,
    pub position_ast: ThoughtAST,
    pub position_distances: Distances,
}
