/// Lens wiring. Maps MarketLens/RegimeLens to vocabulary facts.
///
/// Extracted from orchestration/post.rs. These are the live functions that
/// the wat-vm programs call to wire vocab modules to observer lenses.

use std::collections::HashMap;

use crate::types::candle::Candle;
use crate::types::enums::{RegimeLens, MarketLens};
use crate::encoding::scale_tracker::ScaleTracker;
use crate::encoding::thought_encoder::ThoughtAST;
use crate::encoding::rhythm::{IndicatorSpec, CircularSpec};

// Vocab imports -- market
// Proposals 041+042: ichimoku, stochastic removed from all lenses.
// Their modules still exist but are no longer called.
// fibonacci is used by WyckoffPosition.
use crate::vocab::market::divergence::encode_divergence_facts;
use crate::vocab::market::fibonacci::encode_fibonacci_facts;
use crate::vocab::market::flow::encode_flow_facts;
use crate::vocab::market::keltner::encode_keltner_facts;
use crate::vocab::market::momentum::encode_momentum_facts;
use crate::vocab::market::oscillators::encode_oscillator_facts;
use crate::vocab::market::persistence::encode_persistence_facts;
use crate::vocab::market::price_action::encode_price_action_facts;
use crate::vocab::market::regime::encode_regime_facts;
use crate::vocab::market::standard::encode_standard_facts;
use crate::vocab::market::timeframe::encode_timeframe_facts;

// Vocab imports -- exit
use crate::vocab::exit::regime::encode_exit_regime_facts;
use crate::vocab::exit::time::encode_exit_time_facts;
use crate::vocab::exit::phase::{encode_phase_current_facts, phase_series_thought, phase_scalar_facts};

// Vocab imports -- shared
use crate::vocab::shared::time::encode_time_facts;

/// Collect market vocab facts for a specific lens.
/// Proposals 041+042: three schools (Dow, Pring, Wyckoff), 11 lenses.
/// All include shared/time. Standard window facts go to lenses that need them.
/// Each lens calls the vocab modules that produce its atoms. A few extra atoms
/// per module is noise the subspace strips — no per-atom filtering needed.
pub fn market_lens_facts(lens: &MarketLens, candle: &Candle, window: &[Candle], scales: &mut HashMap<String, ScaleTracker>) -> Vec<ThoughtAST> {
    // Shared: time facts (all lenses get these)
    let mut facts = encode_time_facts(candle);

    match lens {
        // ── Dow school ──────────────────────────────────────────────────
        MarketLens::DowTrend => {
            // close-sma20/50/200, adx, di-spread, macd-hist, atr-ratio
            facts.extend(encode_momentum_facts(candle, scales));
            // hurst, autocorrelation, adx
            facts.extend(encode_persistence_facts(candle, scales));
            // kama-er, choppiness, aroon-up/down, ...
            facts.extend(encode_regime_facts(candle, scales));
            // tf-agreement, tf-4h-trend, tf-5m-1h-align, ...
            facts.extend(encode_timeframe_facts(candle, scales));
        }
        MarketLens::DowVolume => {
            // volume-ratio, obv-slope, buying-pressure, selling-pressure, body-ratio
            facts.extend(encode_flow_facts(candle, scales));
            // since-vol-spike, since-rsi-extreme, since-large-move, dist-from-*, ...
            facts.extend(encode_standard_facts(window, scales));
            // squeeze, bb-width, bb-pos, kelt-pos, ...
            facts.extend(encode_keltner_facts(candle, scales));
        }
        MarketLens::DowCycle => {
            // rsi, cci, mfi, williams-r, roc-1/3/6/12
            facts.extend(encode_oscillator_facts(candle, scales));
            // bb-width, squeeze, bb-pos, kelt-pos, ...
            facts.extend(encode_keltner_facts(candle, scales));
            // momentum: atr-ratio (also close-sma*, di-spread, macd-hist)
            facts.extend(encode_momentum_facts(candle, scales));
            // dist-from-high, dist-from-low, since-large-move, ...
            facts.extend(encode_standard_facts(window, scales));
            // tf-4h-trend, tf-5m-1h-align, tf-agreement, ...
            facts.extend(encode_timeframe_facts(candle, scales));
        }
        MarketLens::DowGeneralist => {
            // All Dow atoms: union of DowTrend + DowVolume + DowCycle modules
            facts.extend(encode_momentum_facts(candle, scales));
            facts.extend(encode_persistence_facts(candle, scales));
            facts.extend(encode_regime_facts(candle, scales));
            facts.extend(encode_timeframe_facts(candle, scales));
            facts.extend(encode_flow_facts(candle, scales));
            facts.extend(encode_standard_facts(window, scales));
            facts.extend(encode_keltner_facts(candle, scales));
            facts.extend(encode_oscillator_facts(candle, scales));
        }

        // ── Pring school ────────────────────────────────────────────────
        MarketLens::PringImpulse => {
            // roc-1, roc-6, roc-12 (also rsi, cci, mfi, williams-r, roc-3)
            facts.extend(encode_oscillator_facts(candle, scales));
            // macd-hist, di-spread (also close-sma*, atr-ratio)
            facts.extend(encode_momentum_facts(candle, scales));
            // adx, hurst, autocorrelation
            facts.extend(encode_persistence_facts(candle, scales));
        }
        MarketLens::PringConfirmation => {
            // obv-slope, volume-ratio (also buying/selling-pressure, body-ratio, vwap-distance)
            facts.extend(encode_flow_facts(candle, scales));
            // rsi, mfi (also cci, williams-r, roc-*)
            facts.extend(encode_oscillator_facts(candle, scales));
            // rsi-divergence-bull, rsi-divergence-bear, divergence-spread
            facts.extend(encode_divergence_facts(candle, scales));
            // tf-agreement (also tf-1h-*, tf-4h-*, tf-5m-1h-align)
            facts.extend(encode_timeframe_facts(candle, scales));
        }
        MarketLens::PringRegime => {
            // kama-er, choppiness (also aroon-up/down, dfa-alpha, ...)
            facts.extend(encode_regime_facts(candle, scales));
            // hurst, adx, autocorrelation
            facts.extend(encode_persistence_facts(candle, scales));
            // squeeze (also bb-pos, bb-width, kelt-pos, ...)
            facts.extend(encode_keltner_facts(candle, scales));
        }
        MarketLens::PringGeneralist => {
            // All Pring atoms: union of PringImpulse + PringConfirmation + PringRegime
            facts.extend(encode_oscillator_facts(candle, scales));
            facts.extend(encode_momentum_facts(candle, scales));
            facts.extend(encode_persistence_facts(candle, scales));
            facts.extend(encode_flow_facts(candle, scales));
            facts.extend(encode_divergence_facts(candle, scales));
            facts.extend(encode_timeframe_facts(candle, scales));
            facts.extend(encode_regime_facts(candle, scales));
            facts.extend(encode_keltner_facts(candle, scales));
        }

        // ── Wyckoff school ──────────────────────────────────────────────
        MarketLens::WyckoffEffort => {
            // volume-ratio, obv-slope, buying-pressure, selling-pressure, body-ratio
            facts.extend(encode_flow_facts(candle, scales));
            // upper-wick, lower-wick, body-ratio-pa, range-ratio, gap, consecutive-*
            facts.extend(encode_price_action_facts(candle, scales));
            // mfi (also rsi, cci, williams-r, roc-*)
            facts.extend(encode_oscillator_facts(candle, scales));
            // since-vol-spike (also since-rsi-extreme, dist-from-*, ...)
            facts.extend(encode_standard_facts(window, scales));
        }
        MarketLens::WyckoffPersistence => {
            // adx, hurst, autocorrelation
            facts.extend(encode_persistence_facts(candle, scales));
            // kama-er, choppiness, aroon-up, aroon-down, ...
            facts.extend(encode_regime_facts(candle, scales));
            // atr-ratio (also close-sma*, di-spread, macd-hist)
            facts.extend(encode_momentum_facts(candle, scales));
            // roc-6, roc-12 (also rsi, cci, mfi, williams-r, roc-1, roc-3)
            facts.extend(encode_oscillator_facts(candle, scales));
        }
        MarketLens::WyckoffPosition => {
            // close-sma20, close-sma50, close-sma200 (also di-spread, macd-hist, atr-ratio)
            facts.extend(encode_momentum_facts(candle, scales));
            // dist-from-high, dist-from-low (also since-*, dist-from-midpoint, ...)
            facts.extend(encode_standard_facts(window, scales));
            // aroon-up, aroon-down (also kama-er, choppiness, ...)
            facts.extend(encode_regime_facts(candle, scales));
            // rsi-divergence-bull, rsi-divergence-bear, divergence-spread
            facts.extend(encode_divergence_facts(candle, scales));
            // range-pos-48 (also range-pos-12/24, fib-dist-*)
            facts.extend(encode_fibonacci_facts(candle, scales));
        }
    }

    facts
}

/// Collect position vocab facts for a specific lens.
/// The lens IS the factory. It determines what this observer sees.
/// Core: lean — regime + time. 5 trade atoms downstream.
/// Full: rich — regime + time + phase series. 13 trade atoms downstream.
pub fn regime_lens_facts(lens: &RegimeLens, candle: &Candle, scales: &mut HashMap<String, ScaleTracker>) -> Vec<ThoughtAST> {
    match lens {
        RegimeLens::Core => {
            // Lean: regime + time. The consensus minimum.
            let mut facts = encode_exit_regime_facts(candle, scales);
            facts.extend(encode_exit_time_facts(candle));
            facts
        }
        RegimeLens::Full => {
            // Rich: regime + time + phase. The full picture.
            let mut facts = encode_exit_regime_facts(candle, scales);
            facts.extend(encode_exit_time_facts(candle));
            facts.extend(encode_phase_current_facts(candle, scales));
            facts.push(phase_series_thought(&candle.phase_history));
            facts.extend(phase_scalar_facts(&candle.phase_history, scales));
            facts
        }
    }
}


// ═══ Rhythm specs — Proposal 056 ════════════════════════════════════
// Each lens returns indicator specs for rhythm encoding.
// Grouped by vocab module, same as the fact functions above.

fn momentum_specs() -> Vec<IndicatorSpec> {
    vec![
        IndicatorSpec { atom_name: "close-sma20", extractor: |c| (c.close - c.sma20) / c.sma20.max(0.01), value_min: -0.1, value_max: 0.1, delta_range: 0.05 },
        IndicatorSpec { atom_name: "close-sma50", extractor: |c| (c.close - c.sma50) / c.sma50.max(0.01), value_min: -0.2, value_max: 0.2, delta_range: 0.1 },
        IndicatorSpec { atom_name: "close-sma200", extractor: |c| (c.close - c.sma200) / c.sma200.max(0.01), value_min: -0.5, value_max: 0.5, delta_range: 0.1 },
        IndicatorSpec { atom_name: "macd-hist", extractor: |c| c.macd_hist, value_min: -500.0, value_max: 500.0, delta_range: 100.0 },
        IndicatorSpec { atom_name: "plus-di", extractor: |c| c.plus_di, value_min: 0.0, value_max: 100.0, delta_range: 10.0 },
        IndicatorSpec { atom_name: "minus-di", extractor: |c| c.minus_di, value_min: 0.0, value_max: 100.0, delta_range: 10.0 },
        IndicatorSpec { atom_name: "atr-ratio", extractor: |c| c.atr_ratio, value_min: 0.0, value_max: 0.05, delta_range: 0.01 },
    ]
}

fn oscillator_specs() -> Vec<IndicatorSpec> {
    vec![
        IndicatorSpec { atom_name: "rsi", extractor: |c| c.rsi, value_min: 0.0, value_max: 100.0, delta_range: 10.0 },
        IndicatorSpec { atom_name: "stoch-k", extractor: |c| c.stoch_k, value_min: 0.0, value_max: 100.0, delta_range: 10.0 },
        IndicatorSpec { atom_name: "williams-r", extractor: |c| c.williams_r, value_min: -100.0, value_max: 0.0, delta_range: 10.0 },
        IndicatorSpec { atom_name: "cci", extractor: |c| c.cci, value_min: -300.0, value_max: 300.0, delta_range: 50.0 },
        IndicatorSpec { atom_name: "mfi", extractor: |c| c.mfi, value_min: 0.0, value_max: 100.0, delta_range: 10.0 },
        IndicatorSpec { atom_name: "roc-1", extractor: |c| c.roc_1, value_min: -0.05, value_max: 0.05, delta_range: 0.02 },
        IndicatorSpec { atom_name: "roc-3", extractor: |c| c.roc_3, value_min: -0.1, value_max: 0.1, delta_range: 0.03 },
        IndicatorSpec { atom_name: "roc-6", extractor: |c| c.roc_6, value_min: -0.15, value_max: 0.15, delta_range: 0.05 },
        IndicatorSpec { atom_name: "roc-12", extractor: |c| c.roc_12, value_min: -0.2, value_max: 0.2, delta_range: 0.05 },
    ]
}

fn flow_specs() -> Vec<IndicatorSpec> {
    vec![
        IndicatorSpec { atom_name: "obv-slope", extractor: |c| c.obv_slope_12, value_min: -2.0, value_max: 2.0, delta_range: 1.0 },
        IndicatorSpec { atom_name: "volume-accel", extractor: |c| c.volume_accel, value_min: 0.0, value_max: 3.0, delta_range: 1.0 },
        IndicatorSpec { atom_name: "vwap-distance", extractor: |c| c.vwap_distance, value_min: -0.05, value_max: 0.05, delta_range: 0.02 },
    ]
}

fn persistence_specs() -> Vec<IndicatorSpec> {
    vec![
        IndicatorSpec { atom_name: "hurst", extractor: |c| c.hurst, value_min: 0.0, value_max: 1.0, delta_range: 0.2 },
        IndicatorSpec { atom_name: "autocorrelation", extractor: |c| c.autocorrelation, value_min: -1.0, value_max: 1.0, delta_range: 0.3 },
        IndicatorSpec { atom_name: "adx", extractor: |c| c.adx, value_min: 0.0, value_max: 100.0, delta_range: 10.0 },
    ]
}

fn regime_specs() -> Vec<IndicatorSpec> {
    vec![
        IndicatorSpec { atom_name: "kama-er", extractor: |c| c.kama_er, value_min: 0.0, value_max: 1.0, delta_range: 0.2 },
        IndicatorSpec { atom_name: "choppiness", extractor: |c| c.choppiness, value_min: 0.0, value_max: 100.0, delta_range: 10.0 },
        IndicatorSpec { atom_name: "dfa-alpha", extractor: |c| c.dfa_alpha, value_min: 0.0, value_max: 2.0, delta_range: 0.3 },
        IndicatorSpec { atom_name: "variance-ratio", extractor: |c| c.variance_ratio, value_min: 0.0, value_max: 3.0, delta_range: 0.5 },
        IndicatorSpec { atom_name: "entropy-rate", extractor: |c| c.entropy_rate, value_min: 0.0, value_max: 1.0, delta_range: 0.2 },
        IndicatorSpec { atom_name: "aroon-up", extractor: |c| c.aroon_up, value_min: 0.0, value_max: 100.0, delta_range: 10.0 },
        IndicatorSpec { atom_name: "aroon-down", extractor: |c| c.aroon_down, value_min: 0.0, value_max: 100.0, delta_range: 10.0 },
        IndicatorSpec { atom_name: "fractal-dim", extractor: |c| c.fractal_dim, value_min: 1.0, value_max: 2.0, delta_range: 0.2 },
    ]
}

fn keltner_specs() -> Vec<IndicatorSpec> {
    vec![
        IndicatorSpec { atom_name: "bb-pos", extractor: |c| c.bb_pos, value_min: -0.5, value_max: 1.5, delta_range: 0.3 },
        IndicatorSpec { atom_name: "bb-width", extractor: |c| c.bb_width, value_min: 0.0, value_max: 0.2, delta_range: 0.05 },
        IndicatorSpec { atom_name: "kelt-pos", extractor: |c| c.kelt_pos, value_min: -0.5, value_max: 1.5, delta_range: 0.3 },
        IndicatorSpec { atom_name: "squeeze", extractor: |c| c.squeeze, value_min: 0.0, value_max: 2.0, delta_range: 0.3 },
    ]
}

fn timeframe_specs() -> Vec<IndicatorSpec> {
    vec![
        IndicatorSpec { atom_name: "tf-1h-ret", extractor: |c| c.tf_1h_ret, value_min: -0.05, value_max: 0.05, delta_range: 0.02 },
        IndicatorSpec { atom_name: "tf-4h-ret", extractor: |c| c.tf_4h_ret, value_min: -0.1, value_max: 0.1, delta_range: 0.03 },
        IndicatorSpec { atom_name: "tf-agreement", extractor: |c| c.tf_agreement, value_min: -1.0, value_max: 1.0, delta_range: 0.3 },
    ]
}

fn divergence_specs() -> Vec<IndicatorSpec> {
    vec![
        IndicatorSpec { atom_name: "rsi-div-bull", extractor: |c| c.rsi_divergence_bull, value_min: 0.0, value_max: 1.0, delta_range: 0.3 },
        IndicatorSpec { atom_name: "rsi-div-bear", extractor: |c| c.rsi_divergence_bear, value_min: 0.0, value_max: 1.0, delta_range: 0.3 },
    ]
}

fn price_action_specs() -> Vec<IndicatorSpec> {
    vec![
        IndicatorSpec { atom_name: "range-ratio", extractor: |c| c.range_ratio, value_min: 0.0, value_max: 5.0, delta_range: 1.0 },
        IndicatorSpec { atom_name: "gap", extractor: |c| c.gap, value_min: -0.05, value_max: 0.05, delta_range: 0.02 },
        IndicatorSpec { atom_name: "consecutive-up", extractor: |c| c.consecutive_up, value_min: 0.0, value_max: 10.0, delta_range: 2.0 },
        IndicatorSpec { atom_name: "consecutive-down", extractor: |c| c.consecutive_down, value_min: 0.0, value_max: 10.0, delta_range: 2.0 },
    ]
}

fn fibonacci_specs() -> Vec<IndicatorSpec> {
    vec![
        IndicatorSpec { atom_name: "range-pos-12", extractor: |c| c.range_pos_12, value_min: 0.0, value_max: 1.0, delta_range: 0.2 },
        IndicatorSpec { atom_name: "range-pos-24", extractor: |c| c.range_pos_24, value_min: 0.0, value_max: 1.0, delta_range: 0.2 },
        IndicatorSpec { atom_name: "range-pos-48", extractor: |c| c.range_pos_48, value_min: 0.0, value_max: 1.0, delta_range: 0.2 },
    ]
}

fn time_circular_specs() -> Vec<CircularSpec> {
    vec![
        CircularSpec { atom_name: "hour", extractor: |c| c.hour, period: 24.0 },
        CircularSpec { atom_name: "day-of-week", extractor: |c| c.day_of_week, period: 7.0 },
    ]
}

/// Return indicator rhythm specs for a market lens.
/// Mirrors the structure of market_lens_facts — same modules per lens.
pub fn market_rhythm_specs(lens: &MarketLens) -> (Vec<IndicatorSpec>, Vec<CircularSpec>) {
    let circular = time_circular_specs();
    let indicators = match lens {
        MarketLens::DowTrend => {
            let mut s = momentum_specs();
            s.extend(persistence_specs());
            s.extend(regime_specs());
            s.extend(timeframe_specs());
            s
        }
        MarketLens::DowVolume => {
            let mut s = flow_specs();
            s.extend(keltner_specs());
            s
        }
        MarketLens::DowCycle => {
            let mut s = oscillator_specs();
            s.extend(keltner_specs());
            s.extend(momentum_specs());
            s.extend(timeframe_specs());
            s
        }
        MarketLens::DowGeneralist => {
            let mut s = momentum_specs();
            s.extend(persistence_specs());
            s.extend(regime_specs());
            s.extend(timeframe_specs());
            s.extend(flow_specs());
            s.extend(keltner_specs());
            s.extend(oscillator_specs());
            s
        }
        MarketLens::PringImpulse => {
            let mut s = oscillator_specs();
            s.extend(momentum_specs());
            s.extend(persistence_specs());
            s
        }
        MarketLens::PringConfirmation => {
            let mut s = flow_specs();
            s.extend(oscillator_specs());
            s.extend(divergence_specs());
            s.extend(timeframe_specs());
            s
        }
        MarketLens::PringRegime => {
            let mut s = regime_specs();
            s.extend(persistence_specs());
            s.extend(keltner_specs());
            s
        }
        MarketLens::PringGeneralist => {
            let mut s = oscillator_specs();
            s.extend(momentum_specs());
            s.extend(persistence_specs());
            s.extend(flow_specs());
            s.extend(divergence_specs());
            s.extend(timeframe_specs());
            s.extend(regime_specs());
            s.extend(keltner_specs());
            s
        }
        MarketLens::WyckoffEffort => {
            let mut s = flow_specs();
            s.extend(price_action_specs());
            s.extend(oscillator_specs());
            s
        }
        MarketLens::WyckoffPersistence => {
            let mut s = persistence_specs();
            s.extend(regime_specs());
            s.extend(momentum_specs());
            s.extend(oscillator_specs());
            s
        }
        MarketLens::WyckoffPosition => {
            let mut s = momentum_specs();
            s.extend(regime_specs());
            s.extend(divergence_specs());
            s.extend(fibonacci_specs());
            s
        }
    };
    (indicators, circular)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::enums::{MarketLens, RegimeLens};

    #[test]
    fn test_market_lens_facts_differ_by_lens() {
        let candle = Candle::default();
        let window = vec![candle.clone()];
        let mut scales = std::collections::HashMap::new();

        let dow_trend = market_lens_facts(&MarketLens::DowTrend, &candle, &window, &mut scales);
        let pring_impulse = market_lens_facts(&MarketLens::PringImpulse, &candle, &window, &mut scales);
        let wyckoff_effort = market_lens_facts(&MarketLens::WyckoffEffort, &candle, &window, &mut scales);

        // Different lenses produce different numbers of facts
        // (all share time, but lens-specific modules differ)
        assert_ne!(dow_trend.len(), wyckoff_effort.len());
        assert_ne!(pring_impulse.len(), wyckoff_effort.len());
    }

    #[test]
    fn test_generalists_include_school_modules() {
        let candle = Candle::default();
        let window = vec![candle.clone()];
        let mut scales = std::collections::HashMap::new();

        // Dow generalist >= any Dow specialist
        let dow_gen = market_lens_facts(&MarketLens::DowGeneralist, &candle, &window, &mut scales);
        for lens in &[MarketLens::DowTrend, MarketLens::DowVolume, MarketLens::DowCycle] {
            let specialist = market_lens_facts(lens, &candle, &window, &mut scales);
            assert!(
                dow_gen.len() >= specialist.len(),
                "DowGeneralist ({}) should have >= facts than {:?} ({})",
                dow_gen.len(), lens, specialist.len(),
            );
        }

        // Pring generalist >= any Pring specialist
        let pring_gen = market_lens_facts(&MarketLens::PringGeneralist, &candle, &window, &mut scales);
        for lens in &[MarketLens::PringImpulse, MarketLens::PringConfirmation, MarketLens::PringRegime] {
            let specialist = market_lens_facts(lens, &candle, &window, &mut scales);
            assert!(
                pring_gen.len() >= specialist.len(),
                "PringGeneralist ({}) should have >= facts than {:?} ({})",
                pring_gen.len(), lens, specialist.len(),
            );
        }
    }

    #[test]
    fn test_regime_lens_facts_variants() {
        let candle = Candle::default();
        let mut scales = std::collections::HashMap::new();

        let core_facts = regime_lens_facts(&RegimeLens::Core, &candle, &mut scales);
        let full_facts = regime_lens_facts(&RegimeLens::Full, &candle, &mut scales);

        // Core: regime(8) + time(2) = 10.
        // Full: regime(8) + time(2) + phase-label(1) + phase-duration(1) + phase-series(1) = 13.
        // (No scalar summaries from empty phase_history on default candle.)
        // Trade atoms arrive through the trade pipe, not here.
        assert_eq!(core_facts.len(), 10); // regime(8) + time(2)
        assert_eq!(full_facts.len(), 13); // regime(8) + time(2) + phase(3)
    }

}
