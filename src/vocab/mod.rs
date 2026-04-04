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
pub mod harmonics;     // Harmonic patterns: Gartley, Bat, Butterfly, Crab (XABCD)
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
            tenkan_sen: 0.0,
            kijun_sen: 0.0,
            senkou_span_a: 0.0,
            senkou_span_b: 0.0,
            cloud_top: 0.0,
            cloud_bottom: 0.0,
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

    // ── Oscillator tests ────────────────────────────────────────────────

    #[test]
    fn oscillators_williams_r_overbought() {
        let mut c = make_candle();
        c.williams_r = -10.0; // > -20 → overbought
        let facts = oscillators::eval_oscillators(&[c]);
        let has_ob = facts.iter().any(|f| matches!(f,
            Fact::Zone { indicator: "williams-r", zone: "williams-overbought" }
        ));
        assert!(has_ob, "expected williams-overbought, got: {:?}", facts);
    }

    #[test]
    fn oscillators_williams_r_oversold() {
        let mut c = make_candle();
        c.williams_r = -90.0; // < -80 → oversold
        let facts = oscillators::eval_oscillators(&[c]);
        let has_os = facts.iter().any(|f| matches!(f,
            Fact::Zone { indicator: "williams-r", zone: "williams-oversold" }
        ));
        assert!(has_os, "expected williams-oversold, got: {:?}", facts);
    }

    #[test]
    fn oscillators_williams_r_neutral_no_zone() {
        let mut c = make_candle();
        c.williams_r = -50.0; // between -80 and -20 → no zone fact
        let facts = oscillators::eval_oscillators(&[c]);
        let has_zone = facts.iter().any(|f| matches!(f,
            Fact::Zone { indicator: "williams-r", .. }
        ));
        assert!(!has_zone, "expected no williams-r zone for neutral value, got: {:?}", facts);
    }

    #[test]
    fn oscillators_williams_r_scalar_always_present() {
        let c = make_candle(); // williams_r = -50
        let facts = oscillators::eval_oscillators(&[c]);
        let has_scalar = facts.iter().any(|f| matches!(f,
            Fact::Scalar { indicator: "williams-r", .. }
        ));
        assert!(has_scalar, "expected williams-r scalar, got: {:?}", facts);
    }

    #[test]
    fn oscillators_stoch_rsi_overbought() {
        let mut c = make_candle();
        c.stoch_k = 85.0; // > 80 → overbought
        let facts = oscillators::eval_oscillators(&[c]);
        let has_ob = facts.iter().any(|f| matches!(f,
            Fact::Zone { indicator: "stoch-rsi", zone: "stoch-rsi-overbought" }
        ));
        assert!(has_ob, "expected stoch-rsi-overbought, got: {:?}", facts);
    }

    #[test]
    fn oscillators_stoch_rsi_oversold() {
        let mut c = make_candle();
        c.stoch_k = 15.0; // < 20 → oversold
        let facts = oscillators::eval_oscillators(&[c]);
        let has_os = facts.iter().any(|f| matches!(f,
            Fact::Zone { indicator: "stoch-rsi", zone: "stoch-rsi-oversold" }
        ));
        assert!(has_os, "expected stoch-rsi-oversold, got: {:?}", facts);
    }

    #[test]
    fn oscillators_roc_accelerating() {
        let mut c = make_candle();
        // Per-candle rates: r1=0.05, r3=0.03, r6=0.02, r12=0.01
        // r1 > r3 > r6 > r12 → 3 accel votes → accelerating
        c.roc_1 = 0.05;
        c.roc_3 = 0.09;   // /3 = 0.03
        c.roc_6 = 0.12;   // /6 = 0.02
        c.roc_12 = 0.12;  // /12 = 0.01
        let facts = oscillators::eval_oscillators(&[c]);
        let has_accel = facts.iter().any(|f| matches!(f,
            Fact::Bare { label: "roc-accelerating" }
        ));
        assert!(has_accel, "expected roc-accelerating, got: {:?}", facts);
    }

    #[test]
    fn oscillators_roc_decelerating() {
        let mut c = make_candle();
        // Per-candle rates: r1=0.001, r3=0.01, r6=0.02, r12=0.03
        // r1 < r3 < r6 < r12 → 3 decel votes → decelerating
        c.roc_1 = 0.001;
        c.roc_3 = 0.03;   // /3 = 0.01
        c.roc_6 = 0.12;   // /6 = 0.02
        c.roc_12 = 0.36;  // /12 = 0.03
        let facts = oscillators::eval_oscillators(&[c]);
        let has_decel = facts.iter().any(|f| matches!(f,
            Fact::Bare { label: "roc-decelerating" }
        ));
        assert!(has_decel, "expected roc-decelerating, got: {:?}", facts);
    }

    // ── Momentum tests ──────────────────────────────────────────────────

    #[test]
    fn momentum_cci_overbought() {
        let mut c = make_candle();
        c.cci = 150.0; // > 100 → overbought
        let facts = momentum::eval_momentum(&[c]);
        let has_ob = facts.iter().any(|f| matches!(f,
            Fact::Zone { indicator: "cci", zone: "cci-overbought" }
        ));
        assert!(has_ob, "expected cci-overbought, got: {:?}", facts);
    }

    #[test]
    fn momentum_cci_oversold() {
        let mut c = make_candle();
        c.cci = -150.0; // < -100 → oversold
        let facts = momentum::eval_momentum(&[c]);
        let has_os = facts.iter().any(|f| matches!(f,
            Fact::Zone { indicator: "cci", zone: "cci-oversold" }
        ));
        assert!(has_os, "expected cci-oversold, got: {:?}", facts);
    }

    #[test]
    fn momentum_cci_neutral_no_zone() {
        let mut c = make_candle();
        c.cci = 50.0; // between -100 and 100 → no zone
        let facts = momentum::eval_momentum(&[c]);
        assert!(facts.is_empty(), "expected no facts for neutral CCI, got: {:?}", facts);
    }

    // ── Regime tests ────────────────────────────────────────────────────

    #[test]
    fn regime_returns_empty_for_short_window() {
        let candles: Vec<Candle> = (0..10).map(|_| make_candle()).collect();
        let facts = regime::eval_regime(&candles);
        assert!(facts.is_empty(), "expected empty for n < 20, got: {:?}", facts);
    }

    #[test]
    fn regime_trend_strong() {
        let mut candles: Vec<Candle> = (0..25).map(|i| {
            let mut c = make_candle();
            c.close = 100.0 + i as f64; // steady uptrend for closes
            c.high = c.close + 2.0;
            c.low = c.close - 2.0;
            c
        }).collect();
        // Set trend consistency on the last candle
        let last = candles.last_mut().unwrap();
        last.trend_consistency_6 = 0.9;
        last.trend_consistency_12 = 0.8;
        last.trend_consistency_24 = 0.7;
        let facts = regime::eval_regime(&candles);
        let has_strong = facts.iter().any(|f| matches!(f,
            Fact::Zone { indicator: "trend", zone: "trend-strong" }
        ));
        assert!(has_strong, "expected trend-strong, got: {:?}", facts);
    }

    #[test]
    fn regime_trend_choppy() {
        let mut candles: Vec<Candle> = (0..25).map(|i| {
            let mut c = make_candle();
            // Alternate up/down for choppy behavior
            c.close = 100.0 + if i % 2 == 0 { 1.0 } else { -1.0 };
            c.high = c.close + 2.0;
            c.low = c.close - 2.0;
            c
        }).collect();
        let last = candles.last_mut().unwrap();
        last.trend_consistency_6 = 0.3;
        last.trend_consistency_12 = 0.35;
        let facts = regime::eval_regime(&candles);
        let has_choppy = facts.iter().any(|f| matches!(f,
            Fact::Zone { indicator: "trend", zone: "trend-choppy" }
        ));
        assert!(has_choppy, "expected trend-choppy, got: {:?}", facts);
    }

    #[test]
    fn regime_vol_expanding() {
        let mut candles: Vec<Candle> = (0..25).map(|i| {
            let mut c = make_candle();
            c.close = 100.0 + i as f64;
            c.high = c.close + 2.0;
            c.low = c.close - 2.0;
            c
        }).collect();
        let last = candles.last_mut().unwrap();
        last.atr_roc_6 = 0.3; // > 0.2 → vol-expanding
        let facts = regime::eval_regime(&candles);
        let has_vol = facts.iter().any(|f| matches!(f,
            Fact::Zone { indicator: "volatility", zone: "vol-expanding" }
        ));
        assert!(has_vol, "expected vol-expanding, got: {:?}", facts);
    }

    #[test]
    fn regime_vol_contracting() {
        let mut candles: Vec<Candle> = (0..25).map(|i| {
            let mut c = make_candle();
            c.close = 100.0 + i as f64;
            c.high = c.close + 2.0;
            c.low = c.close - 2.0;
            c
        }).collect();
        let last = candles.last_mut().unwrap();
        last.atr_roc_6 = -0.2; // < -0.15 → vol-contracting
        let facts = regime::eval_regime(&candles);
        let has_vol = facts.iter().any(|f| matches!(f,
            Fact::Zone { indicator: "volatility", zone: "vol-contracting" }
        ));
        assert!(has_vol, "expected vol-contracting, got: {:?}", facts);
    }

    #[test]
    fn regime_kama_er_zone_present() {
        let candles: Vec<Candle> = (0..25).map(|i| {
            let mut c = make_candle();
            c.close = 100.0 + i as f64;
            c.high = c.close + 2.0;
            c.low = c.close - 2.0;
            c
        }).collect();
        let facts = regime::eval_regime(&candles);
        let has_kama = facts.iter().any(|f| matches!(f,
            Fact::Zone { indicator: "kama-er", .. }
        ));
        assert!(has_kama, "expected kama-er zone, got: {:?}", facts);
    }

    #[test]
    fn regime_chop_zone_present() {
        let candles: Vec<Candle> = (0..25).map(|i| {
            let mut c = make_candle();
            c.close = 100.0 + i as f64;
            c.high = c.close + 2.0;
            c.low = c.close - 2.0;
            c
        }).collect();
        let facts = regime::eval_regime(&candles);
        let has_chop = facts.iter().any(|f| matches!(f,
            Fact::Zone { indicator: "chop", .. }
        ));
        assert!(has_chop, "expected chop zone, got: {:?}", facts);
    }

    #[test]
    fn regime_scalars_present() {
        let candles: Vec<Candle> = (0..25).map(|i| {
            let mut c = make_candle();
            c.close = 100.0 + i as f64;
            c.high = c.close + 2.0;
            c.low = c.close - 2.0;
            c
        }).collect();
        let facts = regime::eval_regime(&candles);
        let has_tc6 = facts.iter().any(|f| matches!(f,
            Fact::Scalar { indicator: "trend-consistency-6", .. }
        ));
        let has_rp12 = facts.iter().any(|f| matches!(f,
            Fact::Scalar { indicator: "range-pos-12", .. }
        ));
        let has_atr_roc = facts.iter().any(|f| matches!(f,
            Fact::Scalar { indicator: "atr-roc-6", .. }
        ));
        assert!(has_tc6, "expected trend-consistency-6 scalar");
        assert!(has_rp12, "expected range-pos-12 scalar");
        assert!(has_atr_roc, "expected atr-roc-6 scalar");
    }

    // ── Divergence tests ────────────────────────────────────────────────

    #[test]
    fn divergence_no_panic_on_short_window() {
        let candles: Vec<Candle> = (0..5).map(|_| make_candle()).collect();
        let divs = divergence::eval_divergence(&candles);
        assert!(divs.is_empty(), "short window should return no divergences");
    }

    #[test]
    fn divergence_no_panic_on_flat_series() {
        let candles: Vec<Candle> = (0..20).map(|_| make_candle()).collect();
        let divs = divergence::eval_divergence(&candles);
        let _ = divs; // just verify no panic
    }

    #[test]
    fn divergence_bearish_higher_high_lower_rsi() {
        let n = 30;
        let mut candles: Vec<Candle> = (0..n).map(|_| make_candle()).collect();
        for (i, c) in candles.iter_mut().enumerate() {
            let t = i as f64;
            c.close = if i <= 8 {
                100.0 + t * 1.25
            } else if i <= 15 {
                110.0 - (t - 8.0) * 2.14
            } else if i <= 22 {
                95.0 + (t - 15.0) * 2.86
            } else {
                115.0 - (t - 22.0) * 1.0
            };
            c.high = c.close + 1.0;
            c.low = c.close - 1.0;
            c.open = c.close - 0.5;
            c.rsi = if i <= 8 {
                50.0 + t * 2.5
            } else if i <= 15 {
                70.0 - (t - 8.0) * 2.86
            } else if i <= 22 {
                50.0 + (t - 15.0) * 1.43
            } else {
                60.0 - (t - 22.0) * 1.0
            };
        }
        let divs = divergence::eval_divergence(&candles);
        for d in &divs {
            assert!(d.kind == "bearish" || d.kind == "bullish");
            assert_eq!(d.indicator, "rsi");
        }
    }

    #[test]
    fn divergence_varying_price_produces_valid_output() {
        let n = 40;
        let mut candles: Vec<Candle> = (0..n).map(|_| make_candle()).collect();
        for (i, c) in candles.iter_mut().enumerate() {
            let t = i as f64 / n as f64 * std::f64::consts::PI * 3.0;
            c.close = 100.0 + 10.0 * t.sin();
            c.high = c.close + 2.0;
            c.low = c.close - 2.0;
            c.open = c.close - 0.5;
            c.rsi = 50.0 + 20.0 * (t * 0.9).sin();
        }
        let divs = divergence::eval_divergence(&candles);
        for d in &divs {
            assert!(d.kind == "bearish" || d.kind == "bullish");
            assert!(d.candles_ago < n);
        }
    }

    // ── Timeframe structure tests ───────────────────────────────────────

    #[test]
    fn timeframe_structure_no_panic_empty() {
        let facts = timeframe::eval_timeframe_structure(&[]);
        assert!(facts.is_empty());
    }

    #[test]
    fn timeframe_structure_produces_body_scalars() {
        let mut c = make_candle();
        c.tf_1h_body = 0.7;
        c.tf_4h_body = 0.3;
        c.tf_1h_high = 105.0;
        c.tf_1h_low = 95.0;
        c.tf_4h_high = 108.0;
        c.tf_4h_low = 92.0;
        let facts = timeframe::eval_timeframe_structure(&[c]);
        let has_1h_body = facts.iter().any(|f| matches!(f,
            Fact::Scalar { indicator: "tf-1h-body", .. }
        ));
        let has_4h_body = facts.iter().any(|f| matches!(f,
            Fact::Scalar { indicator: "tf-4h-body", .. }
        ));
        assert!(has_1h_body, "expected tf-1h-body scalar, got: {:?}", facts);
        assert!(has_4h_body, "expected tf-4h-body scalar, got: {:?}", facts);
    }

    #[test]
    fn timeframe_structure_range_position() {
        let mut c = make_candle();
        c.close = 100.0;
        c.tf_1h_high = 110.0;
        c.tf_1h_low = 90.0;
        c.tf_4h_high = 120.0;
        c.tf_4h_low = 80.0;
        let facts = timeframe::eval_timeframe_structure(&[c]);
        let has_1h_range = facts.iter().any(|f| matches!(f,
            Fact::Scalar { indicator: "tf-1h-range-pos", .. }
        ));
        let has_4h_range = facts.iter().any(|f| matches!(f,
            Fact::Scalar { indicator: "tf-4h-range-pos", .. }
        ));
        assert!(has_1h_range, "expected tf-1h-range-pos, got: {:?}", facts);
        assert!(has_4h_range, "expected tf-4h-range-pos, got: {:?}", facts);
    }

    #[test]
    fn timeframe_structure_zero_range_skips_pos() {
        let mut c = make_candle();
        c.tf_1h_high = 100.0;
        c.tf_1h_low = 100.0;
        let facts = timeframe::eval_timeframe_structure(&[c]);
        let has_1h_range = facts.iter().any(|f| matches!(f,
            Fact::Scalar { indicator: "tf-1h-range-pos", .. }
        ));
        assert!(!has_1h_range, "zero range should skip range-pos, got: {:?}", facts);
    }

    // ── Timeframe narrative tests ───────────────────────────────────────

    #[test]
    fn timeframe_narrative_no_panic_empty() {
        let facts = timeframe::eval_timeframe_narrative(&[]);
        assert!(facts.is_empty());
    }

    #[test]
    fn timeframe_narrative_1h_up_strong() {
        let mut c = make_candle();
        c.tf_1h_ret = 0.01;
        let facts = timeframe::eval_timeframe_narrative(&[c]);
        let has_zone = facts.iter().any(|f| matches!(f,
            Fact::Zone { indicator: "tf-1h", zone: "tf-1h-up-strong" }
        ));
        assert!(has_zone, "expected tf-1h-up-strong zone, got: {:?}", facts);
    }

    #[test]
    fn timeframe_narrative_4h_down_strong() {
        let mut c = make_candle();
        c.tf_4h_ret = -0.02;
        let facts = timeframe::eval_timeframe_narrative(&[c]);
        let has_zone = facts.iter().any(|f| matches!(f,
            Fact::Zone { indicator: "tf-4h", zone: "tf-4h-down-strong" }
        ));
        assert!(has_zone, "expected tf-4h-down-strong zone, got: {:?}", facts);
    }

    #[test]
    fn timeframe_narrative_all_agree() {
        let mut prev = make_candle();
        prev.close = 99.0;
        let mut now = make_candle();
        now.close = 101.0;
        now.tf_1h_ret = 0.01;
        now.tf_4h_ret = 0.02;
        let facts = timeframe::eval_timeframe_narrative(&[prev, now]);
        let has_agree = facts.iter().any(|f| matches!(f,
            Fact::Bare { label: "tf-all-agree" }
        ));
        assert!(has_agree, "expected tf-all-agree, got: {:?}", facts);
    }

    #[test]
    fn timeframe_narrative_all_disagree() {
        let mut prev = make_candle();
        prev.close = 101.0;
        let mut now = make_candle();
        now.close = 99.0;
        now.tf_1h_ret = 0.01;
        now.tf_4h_ret = 0.02;
        let facts = timeframe::eval_timeframe_narrative(&[prev, now]);
        let has_disagree = facts.iter().any(|f| matches!(f,
            Fact::Bare { label: "tf-all-disagree" }
        ));
        assert!(has_disagree, "expected tf-all-disagree, got: {:?}", facts);
    }

    #[test]
    fn timeframe_narrative_ret_scalar() {
        let mut c = make_candle();
        c.tf_1h_ret = 0.003;
        let facts = timeframe::eval_timeframe_narrative(&[c]);
        let has_ret = facts.iter().any(|f| matches!(f,
            Fact::Scalar { indicator: "tf-1h-ret", .. }
        ));
        assert!(has_ret, "expected tf-1h-ret scalar, got: {:?}", facts);
    }

    // ── ROC acceleration/deceleration firing rate diagnostic ────────────

    #[test]
    fn roc_accel_decel_firing_rate() {
        use crate::indicators::{IndicatorBank, RawCandle};

        // --- Generate synthetic price series via IndicatorBank ---
        // Three regimes: uptrend (200 candles), downtrend (200), chop (200)
        let mut bank = IndicatorBank::new();
        let mut candles = Vec::new();
        let mut price = 50_000.0_f64;
        let base_vol = 100.0;

        // Simple deterministic noise from a seed — no rand crate needed.
        let mut seed: u64 = 42;
        let mut noise = || -> f64 {
            seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            // Map to [-1, 1]
            ((seed >> 33) as f64 / (u32::MAX as f64 / 2.0)) - 1.0
        };

        // Phase 1: Strong uptrend (accelerating then steady)
        for i in 0..200 {
            // Accelerating drift: starts small, grows
            let drift = if i < 80 {
                0.001 + 0.0001 * (i as f64) // accelerating
            } else if i < 140 {
                0.005 // steady strong
            } else {
                0.005 - 0.00003 * ((i - 140) as f64) // decelerating
            };
            price *= 1.0 + drift + noise() * 0.002;
            let high = price * (1.0 + noise().abs() * 0.003);
            let low = price * (1.0 - noise().abs() * 0.003);
            let open = price * (1.0 + noise() * 0.001);
            let raw = RawCandle {
                ts: format!("2024-01-01T{:04}:00", i),
                open, high, low, close: price,
                volume: base_vol * (1.0 + noise().abs() * 0.5),
            };
            candles.push(bank.tick(&raw));
        }

        // Phase 2: Strong downtrend
        for i in 0..200 {
            let drift = if i < 80 {
                -0.001 - 0.0001 * (i as f64) // accelerating down
            } else if i < 140 {
                -0.005
            } else {
                -0.005 + 0.00003 * ((i - 140) as f64) // decelerating down
            };
            price *= 1.0 + drift + noise() * 0.002;
            let high = price * (1.0 + noise().abs() * 0.003);
            let low = price * (1.0 - noise().abs() * 0.003);
            let open = price * (1.0 + noise() * 0.001);
            let raw = RawCandle {
                ts: format!("2024-02-01T{:04}:00", i),
                open, high, low, close: price,
                volume: base_vol * (1.0 + noise().abs() * 0.5),
            };
            candles.push(bank.tick(&raw));
        }

        // Phase 3: Choppy sideways
        let anchor = price;
        for i in 0..200 {
            // Mean-reverting chop
            let revert = (anchor - price) / anchor * 0.1;
            price *= 1.0 + revert + noise() * 0.004;
            let high = price * (1.0 + noise().abs() * 0.003);
            let low = price * (1.0 - noise().abs() * 0.003);
            let open = price * (1.0 + noise() * 0.001);
            let raw = RawCandle {
                ts: format!("2024-03-01T{:04}:00", i),
                open, high, low, close: price,
                volume: base_vol * (1.0 + noise().abs() * 0.5),
            };
            candles.push(bank.tick(&raw));
        }

        assert_eq!(candles.len(), 600);

        // --- Evaluate oscillators on each candle and count firings ---
        // Skip first 20 candles (warmup for indicators)
        let warmup = 20;
        let mut accel_count = 0_usize;
        let mut decel_count = 0_usize;
        let mut total = 0_usize;

        // Collect ROC value samples for reporting
        let mut roc_samples: Vec<(f64, f64, f64, f64)> = Vec::new();

        for i in warmup..candles.len() {
            // eval_oscillators only reads candles.last(), but needs a slice
            let slice = &candles[..=i];
            let facts = oscillators::eval_oscillators(slice);
            total += 1;

            let has_accel = facts.iter().any(|f| matches!(f, Fact::Bare { label: "roc-accelerating" }));
            let has_decel = facts.iter().any(|f| matches!(f, Fact::Bare { label: "roc-decelerating" }));

            if has_accel { accel_count += 1; }
            if has_decel { decel_count += 1; }

            // Sample ROC values at phase boundaries and interesting points
            let c = &candles[i];
            if i == warmup || i == 100 || i == 200 || i == 300 || i == 400 || i == 500 || i == candles.len() - 1 {
                roc_samples.push((c.roc_1, c.roc_3, c.roc_6, c.roc_12));
            }
        }

        let accel_pct = 100.0 * accel_count as f64 / total as f64;
        let decel_pct = 100.0 * decel_count as f64 / total as f64;
        let neither_pct = 100.0 * (total - accel_count - decel_count) as f64 / total as f64;

        eprintln!("\n=== ROC Acceleration/Deceleration Firing Rate ===");
        eprintln!("Total candles evaluated: {}", total);
        eprintln!("  roc-accelerating:  {:>4} / {} ({:.1}%)", accel_count, total, accel_pct);
        eprintln!("  roc-decelerating:  {:>4} / {} ({:.1}%)", decel_count, total, decel_pct);
        eprintln!("  neither:           {:>4} / {} ({:.1}%)", total - accel_count - decel_count, total, neither_pct);
        eprintln!();

        // Per-phase breakdown
        let phases = [
            ("uptrend", warmup, 200),
            ("downtrend", 200, 400),
            ("choppy", 400, 600),
        ];
        for (name, start, end) in &phases {
            let mut pa = 0_usize;
            let mut pd = 0_usize;
            let mut pt = 0_usize;
            for i in *start..*end {
                let slice = &candles[..=i];
                let facts = oscillators::eval_oscillators(slice);
                pt += 1;
                if facts.iter().any(|f| matches!(f, Fact::Bare { label: "roc-accelerating" })) { pa += 1; }
                if facts.iter().any(|f| matches!(f, Fact::Bare { label: "roc-decelerating" })) { pd += 1; }
            }
            eprintln!("  {:<12}  accel: {:>3}/{} ({:.1}%)  decel: {:>3}/{} ({:.1}%)",
                name, pa, pt, 100.0 * pa as f64 / pt as f64,
                pd, pt, 100.0 * pd as f64 / pt as f64);
        }

        // ROC value samples — reveal the scale issue
        eprintln!();
        eprintln!("  ROC value samples (roc_1, roc_3, roc_6, roc_12):");
        let labels = ["warmup", "i=100", "i=200", "i=300", "i=400", "i=500", "last"];
        for (j, (r1, r3, r6, r12)) in roc_samples.iter().enumerate() {
            let label = if j < labels.len() { labels[j] } else { "?" };
            eprintln!("    {:<8}  roc1={:+.6}  roc3={:+.6}  roc6={:+.6}  roc12={:+.6}",
                label, r1, r3, r6, r12);
            // Show whether chain ordering holds
            let chain_accel = r1 > r3 && r3 > r6 && r6 > r12;
            let chain_decel = r1 < r3 && r3 < r6 && r6 < r12;
            if chain_accel {
                eprintln!("             ^ ACCEL: roc1 > roc3 > roc6 > roc12");
            } else if chain_decel {
                eprintln!("             ^ DECEL: roc1 < roc3 < roc6 < roc12");
            } else {
                eprintln!("             ^ neither (chain broken)");
            }
        }

        eprintln!();
        eprintln!("  Key insight: ROC_N = (close - close[N]) / close[N]");
        eprintln!("  In a *steady* uptrend, roc_12 > roc_6 > roc_3 > roc_1 (more candles = more return)");
        eprintln!("  Accel requires roc_1 > roc_3 > ... meaning short-term outpaces long-term");
        eprintln!("  This only happens at the START of a new move or during genuine acceleration");

        // The test passes regardless — it's a diagnostic.
        // But assert non-zero to verify the condition CAN fire with our synthetic data.
        assert!(accel_count + decel_count > 0,
            "Neither accel nor decel ever fired — synthetic data may be too tame");
    }
}
