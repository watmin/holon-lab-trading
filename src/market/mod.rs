//! Market domain — shared primitives for market-level modules.
//!
//! Time encoding, candle helpers, and re-exports for market::manager, etc.

pub mod desk;
pub mod manager;
pub mod observer;

/// The enterprise's observer panel: 5 specialists + 1 generalist.
/// Single source of truth — used by both enterprise.rs (atom lookup) and state.rs (observer creation).
pub const OBSERVER_LENSES: [&str; 6] = ["momentum", "structure", "volume", "narrative", "regime", "generalist"];

