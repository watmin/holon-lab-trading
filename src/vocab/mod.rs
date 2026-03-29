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
pub mod flow;          // OBV, VWAP, MFI, buying/selling pressure
pub mod persistence;   // Hurst, autocorrelation, ADX zones
pub mod regime;        // KAMA ER, choppiness, DFA, DeMark, Aroon, fractal dim, entropy, GR b-value
pub mod ichimoku;      // Ichimoku Cloud: tenkan, kijun, spans, cloud zone, TK cross
pub mod stochastic;    // Stochastic Oscillator: %K, %D, zones, crossover
pub mod fibonacci;     // Fibonacci retracement levels and proximity
pub mod keltner;       // Keltner Channels + squeeze detection
pub mod momentum;      // CCI zones
pub mod price_action;  // Inside/outside bars, gaps, consecutive candles
// pub mod complexity;    // TODO: SampEn, permutation entropy, Lyapunov
// pub mod divergence;    // TODO: multi-indicator divergence framework
// pub mod crosses;       // TODO: SMA cross timing, histogram turns
// pub mod channels;      // TODO: donchian, supertrend, SAR
// pub mod levels;        // TODO: pivot points, round numbers
// pub mod microstructure;// TODO: EMV, force index, mass index, vortex
// pub mod participation; // TODO: candle patterns, relative volume
