//! Exit observer vocabulary — judgment facts over market thoughts.
//!
//! The exit observer asks "is now a good time to trade?" not "which direction?"
//! These encoders read candle indicators and produce Fact data that gets
//! bundled with the market observer's thought vector.
//!
//! Three judgment lenses (from wat/exit/observer.wat):
//!   - Volatility: ATR regime, ATR ratio, squeeze state
//!   - Structure:  trend consistency, ADX strength, structure quality
//!   - Timing:     momentum state, reversal signals
//!
//! Each function is pure: candle in, facts out. No vectors. No holon imports.

use crate::candle::Candle;
use crate::vocab::Fact;

// ─── ExitLens ──────────────────────────────────────────────────────────────

/// Which judgment vocabulary an exit observer thinks through.
/// Matches (enum exit-lens :volatility :structure :timing :exit-generalist)
/// in wat/exit/observer.wat.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ExitLens {
    Volatility,
    Structure,
    Timing,
    ExitGeneralist,
}

impl ExitLens {
    /// The string name used for atom lookup and journal naming.
    pub fn as_str(&self) -> &'static str {
        match self {
            ExitLens::Volatility     => "volatility",
            ExitLens::Structure      => "structure",
            ExitLens::Timing         => "timing",
            ExitLens::ExitGeneralist => "exit-generalist",
        }
    }
}

/// The exit observer panel: 3 specialists + 1 generalist.
pub const EXIT_LENSES: [ExitLens; 4] = [
    ExitLens::Volatility,
    ExitLens::Structure,
    ExitLens::Timing,
    ExitLens::ExitGeneralist,
];

// ─── Volatility facts ──────────────────────────────────────────────────────
//
// Implements (encode-volatility-facts atr-now atr-slow squeeze-pct)
// from wat/exit/observer.wat.
//
// Reads: candle.atr_r, candle.squeeze, candle.atr_roc_6, candle.atr_roc_12

pub fn encode_volatility_facts(candle: &Candle) -> Vec<Fact<'static>> {
    let mut facts: Vec<Fact<'static>> = Vec::new();

    // ATR regime — log-encoded current volatility level
    // wat: (bind (atom "atr-regime") (encode-log atr-now))
    facts.push(Fact::Scalar {
        indicator: "atr-regime",
        value: candle.atr_r.max(1e-10),
        scale: 0.1, // ATR ratio typically 0.001–0.05; scale keeps geometry meaningful
    });

    // ATR ratio — current vs slow (6-period rate of change as proxy)
    // wat: (bind (atom "atr-ratio") (encode-log (/ atr-now atr-slow)))
    // atr_roc_6 is (atr_now - atr_6_ago) / atr_6_ago, so ratio ≈ 1 + atr_roc_6
    let atr_ratio = (1.0 + candle.atr_roc_6).max(0.01);
    facts.push(Fact::Scalar {
        indicator: "atr-ratio",
        value: atr_ratio,
        scale: 2.0, // centered around 1.0; scale of 2 maps [0,2] → [0,1]
    });

    // Squeeze state — Bollinger inside Keltner
    // wat: (bind (atom "squeeze-state") (encode-linear (clamp squeeze-pct 0.0 1.0) 1.0))
    facts.push(Fact::Bare {
        label: if candle.squeeze { "squeeze-active" } else { "squeeze-off" },
    });

    // ATR acceleration — is volatility expanding or contracting?
    let atr_roc_6_norm = candle.atr_roc_6.clamp(-1.0, 1.0) * 0.5 + 0.5;
    facts.push(Fact::Scalar {
        indicator: "atr-accel-6",
        value: atr_roc_6_norm,
        scale: 1.0,
    });

    let atr_roc_12_norm = candle.atr_roc_12.clamp(-1.0, 1.0) * 0.5 + 0.5;
    facts.push(Fact::Scalar {
        indicator: "atr-accel-12",
        value: atr_roc_12_norm,
        scale: 1.0,
    });

    // Zone classification for volatility regime
    if candle.atr_roc_6 > 0.3 {
        facts.push(Fact::Zone { indicator: "vol-regime", zone: "vol-expanding-fast" });
    } else if candle.atr_roc_6 > 0.1 {
        facts.push(Fact::Zone { indicator: "vol-regime", zone: "vol-expanding" });
    } else if candle.atr_roc_6 < -0.2 {
        facts.push(Fact::Zone { indicator: "vol-regime", zone: "vol-contracting-fast" });
    } else if candle.atr_roc_6 < -0.05 {
        facts.push(Fact::Zone { indicator: "vol-regime", zone: "vol-contracting" });
    } else {
        facts.push(Fact::Zone { indicator: "vol-regime", zone: "vol-stable" });
    }

    facts
}

// ─── Structure facts ───────────────────────────────────────────────────────
//
// Implements (encode-structure-facts trend-consistency adx support-resistance-quality)
// from wat/exit/observer.wat.
//
// Reads: candle.trend_consistency_6/12/24, candle.adx

pub fn encode_structure_facts(candle: &Candle) -> Vec<Fact<'static>> {
    let mut facts: Vec<Fact<'static>> = Vec::new();

    // Trend consistency at three scales
    // wat: (bind (atom "trend-consistency") (encode-linear (clamp trend-consistency 0.0 1.0) 1.0))
    facts.push(Fact::Scalar {
        indicator: "exit-trend-consistency-6",
        value: candle.trend_consistency_6.clamp(0.0, 1.0),
        scale: 1.0,
    });
    facts.push(Fact::Scalar {
        indicator: "exit-trend-consistency-12",
        value: candle.trend_consistency_12.clamp(0.0, 1.0),
        scale: 1.0,
    });
    facts.push(Fact::Scalar {
        indicator: "exit-trend-consistency-24",
        value: candle.trend_consistency_24.clamp(0.0, 1.0),
        scale: 1.0,
    });

    // ADX strength — directional movement quality
    // wat: (bind (atom "adx-strength") (encode-log (max adx 1.0)))
    facts.push(Fact::Scalar {
        indicator: "exit-adx-strength",
        value: candle.adx.max(1.0),
        scale: 100.0, // ADX range [0, ~80]; scale normalizes
    });

    // Structure quality — multi-scale trend agreement as proxy for
    // support/resistance quality (higher agreement = cleaner structure)
    let avg_consistency = (candle.trend_consistency_6
        + candle.trend_consistency_12
        + candle.trend_consistency_24) / 3.0;
    facts.push(Fact::Scalar {
        indicator: "exit-structure-quality",
        value: avg_consistency.clamp(0.0, 1.0),
        scale: 1.0,
    });

    // Zone: is the structure clear enough to exploit?
    if candle.adx > 40.0 && avg_consistency > 0.6 {
        facts.push(Fact::Zone { indicator: "exit-structure", zone: "structure-strong" });
    } else if candle.adx > 25.0 && avg_consistency > 0.5 {
        facts.push(Fact::Zone { indicator: "exit-structure", zone: "structure-moderate" });
    } else if candle.adx < 15.0 {
        facts.push(Fact::Zone { indicator: "exit-structure", zone: "structure-absent" });
    } else {
        facts.push(Fact::Zone { indicator: "exit-structure", zone: "structure-weak" });
    }

    facts
}

// ─── Timing facts ──────────────────────────────────────────────────────────
//
// Implements (encode-timing-facts momentum-state reversal-strength bars-since-cross)
// from wat/exit/observer.wat.
//
// Reads: candle.rsi, candle.macd_hist, candle.stoch_k, candle.cci

pub fn encode_timing_facts(candle: &Candle) -> Vec<Fact<'static>> {
    let mut facts: Vec<Fact<'static>> = Vec::new();

    // Momentum state — composite from RSI and MACD histogram
    // wat: (bind (atom "momentum-state") (encode-linear (clamp momentum-state 0.0 1.0) 1.0))
    let rsi_norm = candle.rsi / 100.0; // RSI [0,100] → [0,1]
    facts.push(Fact::Scalar {
        indicator: "exit-momentum-rsi",
        value: rsi_norm.clamp(0.0, 1.0),
        scale: 1.0,
    });

    // MACD histogram as momentum direction signal
    // Normalize to a reasonable range; sign carries direction
    facts.push(Fact::Scalar {
        indicator: "exit-momentum-macd",
        value: candle.macd_hist.clamp(-500.0, 500.0) / 500.0 * 0.5 + 0.5,
        scale: 1.0,
    });

    // Stochastic %K — overbought/oversold timing
    let stoch_norm = candle.stoch_k / 100.0;
    facts.push(Fact::Scalar {
        indicator: "exit-stoch-k",
        value: stoch_norm.clamp(0.0, 1.0),
        scale: 1.0,
    });

    // CCI — extreme moves
    // wat: (bind (atom "reversal-strength") (encode-log (max reversal-strength 0.01)))
    let cci_norm = candle.cci.abs().max(1.0);
    facts.push(Fact::Scalar {
        indicator: "exit-cci-magnitude",
        value: cci_norm,
        scale: 300.0, // CCI typically -200 to +200; extreme beyond
    });

    // Reversal signal zones
    if candle.rsi > 70.0 && candle.stoch_k > 80.0 {
        facts.push(Fact::Zone { indicator: "exit-timing", zone: "timing-overbought" });
    } else if candle.rsi < 30.0 && candle.stoch_k < 20.0 {
        facts.push(Fact::Zone { indicator: "exit-timing", zone: "timing-oversold" });
    } else if candle.macd_hist.abs() < 10.0 && candle.rsi > 45.0 && candle.rsi < 55.0 {
        facts.push(Fact::Zone { indicator: "exit-timing", zone: "timing-neutral" });
    } else if candle.cci > 100.0 {
        facts.push(Fact::Zone { indicator: "exit-timing", zone: "timing-cci-hot" });
    } else if candle.cci < -100.0 {
        facts.push(Fact::Zone { indicator: "exit-timing", zone: "timing-cci-cold" });
    } else {
        facts.push(Fact::Zone { indicator: "exit-timing", zone: "timing-active" });
    }

    facts
}

// ─── Tests ─────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::candle::Candle;

    /// Build a candle with sensible defaults for exit vocab tests.
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

    #[test]
    fn volatility_facts_non_empty() {
        let candle = make_candle();
        let facts = encode_volatility_facts(&candle);
        assert!(!facts.is_empty(), "volatility facts should not be empty");
        // Must have at least: atr-regime, atr-ratio, squeeze, atr-accel-6, atr-accel-12, vol-regime
        assert!(facts.len() >= 6, "expected >= 6 volatility facts, got {}", facts.len());
    }

    #[test]
    fn volatility_squeeze_active() {
        let mut candle = make_candle();
        candle.squeeze = true;
        let facts = encode_volatility_facts(&candle);
        let has_squeeze = facts.iter().any(|f| matches!(f, Fact::Bare { label: "squeeze-active" }));
        assert!(has_squeeze, "expected squeeze-active when squeeze=true, got: {:?}", facts);
    }

    #[test]
    fn volatility_squeeze_off() {
        let candle = make_candle(); // squeeze defaults to false
        let facts = encode_volatility_facts(&candle);
        let has_off = facts.iter().any(|f| matches!(f, Fact::Bare { label: "squeeze-off" }));
        assert!(has_off, "expected squeeze-off when squeeze=false, got: {:?}", facts);
    }

    #[test]
    fn volatility_expanding_zone() {
        let mut candle = make_candle();
        candle.atr_roc_6 = 0.5; // fast expansion
        let facts = encode_volatility_facts(&candle);
        let has_expanding = facts.iter().any(|f| matches!(f,
            Fact::Zone { indicator: "vol-regime", zone: "vol-expanding-fast" }
        ));
        assert!(has_expanding, "expected vol-expanding-fast, got: {:?}", facts);
    }

    #[test]
    fn structure_facts_non_empty() {
        let candle = make_candle();
        let facts = encode_structure_facts(&candle);
        assert!(!facts.is_empty(), "structure facts should not be empty");
        // consistency-6, -12, -24, adx-strength, structure-quality, zone
        assert!(facts.len() >= 6, "expected >= 6 structure facts, got {}", facts.len());
    }

    #[test]
    fn structure_strong_zone() {
        let mut candle = make_candle();
        candle.adx = 45.0;
        candle.trend_consistency_6 = 0.85;
        candle.trend_consistency_12 = 0.75;
        candle.trend_consistency_24 = 0.65;
        let facts = encode_structure_facts(&candle);
        let has_strong = facts.iter().any(|f| matches!(f,
            Fact::Zone { indicator: "exit-structure", zone: "structure-strong" }
        ));
        assert!(has_strong, "expected structure-strong with high adx+consistency, got: {:?}", facts);
    }

    #[test]
    fn timing_facts_non_empty() {
        let candle = make_candle();
        let facts = encode_timing_facts(&candle);
        assert!(!facts.is_empty(), "timing facts should not be empty");
        // rsi, macd, stoch, cci, zone
        assert!(facts.len() >= 5, "expected >= 5 timing facts, got {}", facts.len());
    }

    #[test]
    fn timing_overbought_zone() {
        let mut candle = make_candle();
        candle.rsi = 75.0;
        candle.stoch_k = 85.0;
        let facts = encode_timing_facts(&candle);
        let has_ob = facts.iter().any(|f| matches!(f,
            Fact::Zone { indicator: "exit-timing", zone: "timing-overbought" }
        ));
        assert!(has_ob, "expected timing-overbought with rsi=75 stoch=85, got: {:?}", facts);
    }

    #[test]
    fn timing_oversold_zone() {
        let mut candle = make_candle();
        candle.rsi = 25.0;
        candle.stoch_k = 15.0;
        let facts = encode_timing_facts(&candle);
        let has_os = facts.iter().any(|f| matches!(f,
            Fact::Zone { indicator: "exit-timing", zone: "timing-oversold" }
        ));
        assert!(has_os, "expected timing-oversold with rsi=25 stoch=15, got: {:?}", facts);
    }

    #[test]
    fn exit_lens_as_str() {
        assert_eq!(ExitLens::Volatility.as_str(), "volatility");
        assert_eq!(ExitLens::Structure.as_str(), "structure");
        assert_eq!(ExitLens::Timing.as_str(), "timing");
        assert_eq!(ExitLens::ExitGeneralist.as_str(), "exit-generalist");
    }

    #[test]
    fn exit_lenses_count() {
        assert_eq!(EXIT_LENSES.len(), 4);
    }
}
