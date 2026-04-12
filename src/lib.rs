// Tenth inscription. Rebuilt from the guide.

use holon::kernel::vector::Vector;

/// Convert Vector (i8) to Vec<f64> for OnlineSubspace operations.
/// Shared by broker, market_observer, and any module needing f64 projections.
pub fn to_f64(v: &Vector) -> Vec<f64> {
    v.data().iter().map(|&x| x as f64).collect()
}

pub mod raw_candle;
pub mod candle;
pub mod indicator_bank;
pub mod enums;
pub mod newtypes;
pub mod distances;
pub mod window_sampler;
pub mod scalar_accumulator;
pub mod engram_gate;
pub mod simulation;
pub mod thought_encoder;
pub mod scale_tracker;
pub mod vocab;
pub mod ctx;
pub mod market_observer;
pub mod exit_observer;
pub mod paper_entry;
pub mod broker;
pub mod proposal;
pub mod trade;
pub mod trade_origin;
pub mod settlement;
pub mod log_entry;
pub mod post;
pub mod treasury;
pub mod enterprise;
pub mod encoder_service;
pub mod log_service;
