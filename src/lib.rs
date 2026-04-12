// Tenth inscription. Rebuilt from the guide.

use holon::kernel::vector::Vector;

/// Convert Vector (i8) to Vec<f64> for OnlineSubspace operations.
/// Shared by broker, market_observer, and any module needing f64 projections.
pub fn to_f64(v: &Vector) -> Vec<f64> {
    v.data().iter().map(|&x| x as f64).collect()
}

pub mod types;
pub mod indicator_bank;
pub mod learning;
pub mod simulation;
pub mod encoding;
pub mod vocab;
pub mod market_observer;
pub mod exit_observer;
pub mod trades;
pub mod broker;
pub mod post;
pub mod treasury;
pub mod enterprise;
pub mod encoder_service;
pub mod log_service;
pub mod services;
pub mod programs;
