/// Lens wiring. Maps MarketLens/PositionLens to vocabulary facts.
///
/// Extracted from orchestration/post.rs. These are the live functions that
/// the wat-vm programs call to wire vocab modules to observer lenses.

use std::collections::HashMap;

use crate::types::candle::Candle;
use crate::types::enums::{PositionLens, MarketLens};
use crate::encoding::scale_tracker::ScaleTracker;
use crate::encoding::thought_encoder::ThoughtAST;

// Vocab imports -- market
// Proposals 041+042: fibonacci, ichimoku, stochastic removed from all lenses.
// Their modules still exist but are no longer called.
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
use crate::vocab::exit::self_assessment::encode_exit_self_assessment_facts;

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
/// Proposal 040: trade atoms come through the trade pipe, not the candle.
/// Position lenses keep regime + time facts as market context alongside trade atoms.
pub fn position_lens_facts(lens: &PositionLens, candle: &Candle, scales: &mut HashMap<String, ScaleTracker>) -> Vec<ThoughtAST> {
    // Both Core and Full get regime + time as market context.
    // The trade-specific atoms arrive through the trade pipe.
    let _ = lens; // both lenses get the same market context
    let mut facts = encode_exit_regime_facts(candle, scales);
    facts.extend(encode_exit_time_facts(candle));
    facts
}

/// Collect position self-assessment facts from the position observer's rolling window.
/// Generalist-only for now. Returns empty for non-generalist lenses.
pub fn position_self_assessment_facts(grace_rate: f64, avg_residue: f64, scales: &mut HashMap<String, ScaleTracker>) -> Vec<ThoughtAST> {
    // Self-assessment is on ALL lenses — it's an internal property
    // every position observer has, not a generalist-only feature.
    encode_exit_self_assessment_facts(grace_rate, avg_residue, scales)
}

/// Static ScalarEncoder shared across the process.
///
/// WHY this exists: broker.propagate() needs a &ScalarEncoder to encode optimal
/// distances into the scalar accumulators. The proper owner is Ctx (via
/// ThoughtEncoder), but propagate() is called from both the Post (which has ctx)
/// and the binary's broker threads (which don't). Threading &ctx through the
/// broker channel would require either an Arc or restructuring the channel
/// protocol — a larger refactor than justified right now.
///
/// WHY OnceLock: the ScalarEncoder is deterministic for a given dimension, so a
/// single static instance at 4096 dims is bit-identical to what ctx holds. There
/// is no divergence risk as long as dims don't change at runtime (they don't).
///
/// TODO: eliminate this by passing &ScalarEncoder (or &Ctx) through the broker
/// propagation path. Options: (a) bundle it into the channel message, (b) wrap
/// ctx in Arc and share with broker threads, or (c) move propagation back to
/// the main thread where ctx is available. Option (c) is cleanest but requires
/// rethinking the broker-thread drain loop.
pub fn ctx_scalar_encoder_placeholder() -> &'static holon::kernel::scalar::ScalarEncoder {
    use std::sync::OnceLock;
    static SE: OnceLock<holon::kernel::scalar::ScalarEncoder> = OnceLock::new();
    SE.get_or_init(|| holon::kernel::scalar::ScalarEncoder::new(4096))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::enums::{MarketLens, PositionLens};

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
    fn test_position_lens_facts_variants() {
        let candle = Candle::default();
        let mut scales = std::collections::HashMap::new();

        let core_facts = position_lens_facts(&PositionLens::Core, &candle, &mut scales);
        let full_facts = position_lens_facts(&PositionLens::Full, &candle, &mut scales);

        // Proposal 040: both lenses get regime(8) + time(2) = 10 market context atoms.
        // Trade atoms arrive through the trade pipe, not here.
        assert_eq!(core_facts.len(), 10); // regime(8) + time(2)
        assert_eq!(full_facts.len(), 10); // regime(8) + time(2)
    }

    #[test]
    fn test_exit_self_assessment_generalist_only() {
        let mut scales = std::collections::HashMap::new();
        let facts = position_self_assessment_facts(0.6, 0.005, &mut scales);
        assert_eq!(facts.len(), 2);
    }
}
