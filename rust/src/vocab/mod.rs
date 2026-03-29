//! Vocabulary modules — the enterprise's thoughts.
//!
//! Each module implements a set of atoms + eval methods from the wat spec.
//! Experts include the modules they need via their profile's eval dispatch.
//!
//! Structure mirrors wat/mod/:
//!   wat/mod/oscillators.wat  → vocab/oscillators.rs
//!   wat/mod/flow.wat         → vocab/flow.rs
//!   etc.
//!
//! The stdlib (common.wat) lives in thought.rs as eval_comparisons_cached.
//! Modules add domain-specific facts on top of stdlib.

// Domain modules — each implements eval methods for its atoms
pub mod oscillators;   // Williams%R, StochRSI, UltOsc, multi-ROC
// pub mod flow;          // TODO: OBV, VWAP, A/D, MFI, CMF
// pub mod persistence;   // TODO: Hurst, autocorrelation, ADX zones
// pub mod complexity;    // TODO: SampEn, permutation entropy, Lyapunov
// pub mod divergence;    // TODO: multi-indicator divergence framework
// pub mod crosses;       // TODO: SMA cross timing, histogram turns
// pub mod channels;      // TODO: donchian, supertrend, SAR
// pub mod levels;        // TODO: pivot points, round numbers
// pub mod microstructure;// TODO: EMV, force index, mass index, vortex
// pub mod participation; // TODO: candle patterns, relative volume
