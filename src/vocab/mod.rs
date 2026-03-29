//! Vocabulary modules — the enterprise's thoughts.
//!
//! Each module is a pure function: candles in, facts out.
//! Modules don't import holon. They don't create vectors.
//! They return Fact data. The encoder renders data into geometry.
//!
//! The contract (from wat/vocab.wat):
//!   fn eval_foo(candles: &[Candle]) -> Vec<Fact>
//!
//! Adding a new module:
//!   1. Write eval_foo(candles) -> Vec<Fact>
//!   2. Add one line to the profile dispatch
//!   3. The encoder never changes

// ─── The Fact ───────────────────────────────────────────────────────────────
// Data, not vectors. The interface between vocab modules and the encoder.

/// What a vocab module says about a candle window.
pub enum Fact<'a> {
    /// "This indicator is in this zone." → (at indicator zone)
    Zone { indicator: &'a str, zone: &'a str },

    /// "A is above/below B." → (above a b) or (below a b)
    Comparison { predicate: &'a str, a: &'a str, b: &'a str },

    /// "This indicator has this continuous value." → bind(indicator, encode(value))
    Scalar { indicator: &'a str, value: f64, scale: f64 },

    /// "This named condition is present." → atom lookup
    Bare { label: &'a str },
}

// ─── Domain modules ─────────────────────────────────────────────────────────

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
pub mod divergence;    // RSI divergence via PELT structural peaks/troughs
pub mod timeframe;     // Inter-timeframe structure: 1h/4h agreement, range position, body ratio
// pub mod complexity;    // TODO: SampEn, permutation entropy, Lyapunov
// pub mod crosses;       // TODO: SMA cross timing, histogram turns
// pub mod channels;      // TODO: donchian, supertrend, SAR
// pub mod levels;        // TODO: pivot points, round numbers
// pub mod microstructure;// TODO: EMV, force index, mass index, vortex
// pub mod participation; // TODO: candle patterns, relative volume
