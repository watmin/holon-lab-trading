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
#[derive(Debug)]
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::candle::Candle;

    /// Build a Candle with sensible defaults. Override fields via the returned value.
    fn make_candle() -> Candle {
        Candle {
            ts: String::new(),
            open: 99.0,
            high: 102.0,
            low: 98.0,
            close: 100.0,
            volume: 50.0,
            sma20: 100.0,
            sma50: 100.0,
            sma200: 100.0,
            bb_upper: 105.0,
            bb_lower: 95.0,
            bb_width: 0.0,
            rsi: 50.0,
            macd_line: 0.5,
            macd_signal: 0.3,
            macd_hist: 0.2,
            dmi_plus: 20.0,
            dmi_minus: 15.0,
            adx: 25.0,
            atr: 2.0,
            atr_r: 0.02,
            stoch_k: 50.0,
            stoch_d: 45.0,
            williams_r: -50.0,
            cci: 0.0,
            mfi: 50.0,
            roc_1: 0.0,
            roc_3: 0.0,
            roc_6: 0.0,
            roc_12: 0.0,
            obv_slope_12: 0.0,
            volume_sma_20: 0.0,
            tf_1h_close: 0.0,
            tf_1h_high: 0.0,
            tf_1h_low: 0.0,
            tf_1h_ret: 0.0,
            tf_1h_body: 0.0,
            tf_4h_close: 0.0,
            tf_4h_high: 0.0,
            tf_4h_low: 0.0,
            tf_4h_ret: 0.0,
            tf_4h_body: 0.0,
            bb_pos: 0.0,
            kelt_upper: 0.0,
            kelt_lower: 0.0,
            kelt_pos: 0.0,
            squeeze: false,
            range_pos_12: 0.0,
            range_pos_24: 0.0,
            range_pos_48: 0.0,
            trend_consistency_6: 0.0,
            trend_consistency_12: 0.0,
            trend_consistency_24: 0.0,
            atr_roc_6: 0.0,
            atr_roc_12: 0.0,
            vol_accel: 0.0,
            hour: 0.0,
            day_of_week: 0.0,
        }
    }

    // ── Stochastic tests ────────────────────────────────────────────────

    #[test]
    fn stochastic_k_above_d() {
        let mut c = make_candle();
        c.stoch_k = 60.0;
        c.stoch_d = 40.0;
        let prev = make_candle(); // defaults: k=50, d=45 → k > d (no cross)
        let facts = stochastic::eval_stochastic(&[prev, c]).unwrap();
        let has_above = facts.iter().any(|f| matches!(f,
            Fact::Comparison { predicate: "above", a: "stoch-k", b: "stoch-d" }
        ));
        assert!(has_above, "expected (above stoch-k stoch-d), got: {:?}", facts);
    }

    #[test]
    fn stochastic_k_below_d() {
        let mut c = make_candle();
        c.stoch_k = 30.0;
        c.stoch_d = 60.0;
        let mut prev = make_candle();
        prev.stoch_k = 30.0;
        prev.stoch_d = 60.0; // prev also below → no cross
        let facts = stochastic::eval_stochastic(&[prev, c]).unwrap();
        let has_below = facts.iter().any(|f| matches!(f,
            Fact::Comparison { predicate: "below", a: "stoch-k", b: "stoch-d" }
        ));
        assert!(has_below, "expected (below stoch-k stoch-d), got: {:?}", facts);
    }

    #[test]
    fn stochastic_overbought_zone() {
        let mut c = make_candle();
        c.stoch_k = 85.0;
        c.stoch_d = 80.0;
        let prev = make_candle();
        let facts = stochastic::eval_stochastic(&[prev, c]).unwrap();
        let has_ob = facts.iter().any(|f| matches!(f,
            Fact::Zone { indicator: "stoch-k", zone: "stoch-overbought" }
        ));
        assert!(has_ob, "expected stoch-overbought zone, got: {:?}", facts);
    }

    #[test]
    fn stochastic_oversold_zone() {
        let mut c = make_candle();
        c.stoch_k = 15.0;
        c.stoch_d = 20.0;
        let prev = make_candle();
        let facts = stochastic::eval_stochastic(&[prev, c]).unwrap();
        let has_os = facts.iter().any(|f| matches!(f,
            Fact::Zone { indicator: "stoch-k", zone: "stoch-oversold" }
        ));
        assert!(has_os, "expected stoch-oversold zone, got: {:?}", facts);
    }

    #[test]
    fn stochastic_crosses_above() {
        let mut prev = make_candle();
        prev.stoch_k = 40.0;
        prev.stoch_d = 50.0; // prev: k < d
        let mut now = make_candle();
        now.stoch_k = 55.0;
        now.stoch_d = 50.0; // now: k >= d → crosses above
        let facts = stochastic::eval_stochastic(&[prev, now]).unwrap();
        let has_cross = facts.iter().any(|f| matches!(f,
            Fact::Comparison { predicate: "crosses-above", a: "stoch-k", b: "stoch-d" }
        ));
        assert!(has_cross, "expected crosses-above, got: {:?}", facts);
    }

    #[test]
    fn stochastic_crosses_below() {
        let mut prev = make_candle();
        prev.stoch_k = 55.0;
        prev.stoch_d = 50.0; // prev: k > d
        let mut now = make_candle();
        now.stoch_k = 45.0;
        now.stoch_d = 50.0; // now: k <= d → crosses below
        let facts = stochastic::eval_stochastic(&[prev, now]).unwrap();
        let has_cross = facts.iter().any(|f| matches!(f,
            Fact::Comparison { predicate: "crosses-below", a: "stoch-k", b: "stoch-d" }
        ));
        assert!(has_cross, "expected crosses-below, got: {:?}", facts);
    }

    // ── Flow tests ──────────────────────────────────────────────────────

    #[test]
    fn flow_mfi_overbought() {
        let mut c = make_candle();
        c.mfi = 85.0;
        let prev = make_candle();
        let (_obv, facts) = flow::eval_flow(&[prev, c]);
        let has_ob = facts.iter().any(|f| matches!(f,
            Fact::Zone { indicator: "mfi", zone: "mfi-overbought" }
        ));
        assert!(has_ob, "expected mfi-overbought, got: {:?}", facts);
    }

    #[test]
    fn flow_mfi_oversold() {
        let mut c = make_candle();
        c.mfi = 15.0;
        let prev = make_candle();
        let (_obv, facts) = flow::eval_flow(&[prev, c]);
        let has_os = facts.iter().any(|f| matches!(f,
            Fact::Zone { indicator: "mfi", zone: "mfi-oversold" }
        ));
        assert!(has_os, "expected mfi-oversold, got: {:?}", facts);
    }

    // ── Keltner tests ───────────────────────────────────────────────────

    #[test]
    fn keltner_above_upper() {
        let mut c = make_candle();
        c.close = 110.0;
        c.kelt_upper = 105.0;
        c.kelt_lower = 95.0;
        c.kelt_pos = 1.5;
        let facts = keltner::eval_keltner(&[c]);
        let has_above = facts.iter().any(|f| matches!(f,
            Fact::Comparison { predicate: "above", a: "close", b: "keltner-upper" }
        ));
        assert!(has_above, "expected close above keltner-upper, got: {:?}", facts);
    }

    #[test]
    fn keltner_below_lower() {
        let mut c = make_candle();
        c.close = 90.0;
        c.kelt_upper = 105.0;
        c.kelt_lower = 95.0;
        c.kelt_pos = -0.5;
        let facts = keltner::eval_keltner(&[c]);
        let has_below = facts.iter().any(|f| matches!(f,
            Fact::Comparison { predicate: "below", a: "close", b: "keltner-lower" }
        ));
        assert!(has_below, "expected close below keltner-lower, got: {:?}", facts);
    }

    #[test]
    fn keltner_squeeze_detected() {
        let mut c = make_candle();
        c.kelt_upper = 105.0;
        c.kelt_lower = 95.0;
        c.squeeze = true;
        let facts = keltner::eval_keltner(&[c]);
        let has_squeeze = facts.iter().any(|f| matches!(f,
            Fact::Zone { indicator: "volatility", zone: "squeeze" }
        ));
        assert!(has_squeeze, "expected squeeze zone, got: {:?}", facts);
    }

    // ── Price action tests ──────────────────────────────────────────────

    #[test]
    fn price_action_no_panic() {
        let c1 = make_candle();
        let c2 = make_candle();
        let c3 = make_candle();
        // Must not panic — 3 candles needed (n >= 3 guard).
        let facts = price_action::eval_price_action(&[c1, c2, c3]);
        // Just verify it returns a vec (may be empty depending on defaults).
        let _ = facts;
    }

    #[test]
    fn price_action_inside_bar() {
        let mut prev = make_candle();
        prev.high = 110.0;
        prev.low = 90.0;
        let mut now = make_candle();
        now.high = 105.0;
        now.low = 95.0;
        let filler = make_candle(); // need n >= 3
        let facts = price_action::eval_price_action(&[filler, prev, now]);
        let has_inside = facts.iter().any(|f| matches!(f,
            Fact::Zone { indicator: "close", zone: "inside-bar" }
        ));
        assert!(has_inside, "expected inside-bar, got: {:?}", facts);
    }

    #[test]
    fn price_action_outside_bar() {
        let mut prev = make_candle();
        prev.high = 101.0;
        prev.low = 99.0;
        let mut now = make_candle();
        now.high = 105.0;
        now.low = 95.0;
        let filler = make_candle();
        let facts = price_action::eval_price_action(&[filler, prev, now]);
        let has_outside = facts.iter().any(|f| matches!(f,
            Fact::Zone { indicator: "close", zone: "outside-bar" }
        ));
        assert!(has_outside, "expected outside-bar, got: {:?}", facts);
    }

    #[test]
    fn price_action_gap_up() {
        let mut prev = make_candle();
        prev.close = 100.0;
        let mut now = make_candle();
        now.open = 100.2; // gap > 0.1%
        let filler = make_candle();
        let facts = price_action::eval_price_action(&[filler, prev, now]);
        let has_gap = facts.iter().any(|f| matches!(f,
            Fact::Zone { indicator: "close", zone: "gap-up" }
        ));
        assert!(has_gap, "expected gap-up, got: {:?}", facts);
    }
}
