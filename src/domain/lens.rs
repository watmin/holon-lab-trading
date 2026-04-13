/// Lens wiring. Maps MarketLens/ExitLens to vocabulary facts.
///
/// Extracted from orchestration/post.rs. These are the live functions that
/// the wat-vm programs call to wire vocab modules to observer lenses.

use std::collections::HashMap;

use crate::types::candle::Candle;
use crate::types::enums::{ExitLens, MarketLens};
use crate::encoding::scale_tracker::ScaleTracker;
use crate::encoding::thought_encoder::ThoughtAST;

// Vocab imports -- market
use crate::vocab::market::divergence::encode_divergence_facts;
use crate::vocab::market::fibonacci::encode_fibonacci_facts;
use crate::vocab::market::flow::encode_flow_facts;
use crate::vocab::market::ichimoku::encode_ichimoku_facts;
use crate::vocab::market::keltner::encode_keltner_facts;
use crate::vocab::market::momentum::encode_momentum_facts;
use crate::vocab::market::oscillators::encode_oscillator_facts;
use crate::vocab::market::persistence::encode_persistence_facts;
use crate::vocab::market::price_action::encode_price_action_facts;
use crate::vocab::market::regime::encode_regime_facts;
use crate::vocab::market::standard::encode_standard_facts;
use crate::vocab::market::stochastic::encode_stochastic_facts;
use crate::vocab::market::timeframe::encode_timeframe_facts;

// Vocab imports -- exit
use crate::vocab::exit::structure::encode_exit_structure_facts;
use crate::vocab::exit::timing::encode_exit_timing_facts;
use crate::vocab::exit::volatility::encode_exit_volatility_facts;
use crate::vocab::exit::regime::encode_exit_regime_facts;
use crate::vocab::exit::time::encode_exit_time_facts;
use crate::vocab::exit::self_assessment::encode_exit_self_assessment_facts;

// Vocab imports -- shared
use crate::vocab::shared::time::encode_time_facts;

/// Collect market vocab facts for a specific lens.
/// Each MarketLens selects different modules. All include shared/time + standard.
/// This is the CRITICAL wiring -- different lenses see different market data.
pub fn market_lens_facts(lens: &MarketLens, candle: &Candle, window: &[Candle], scales: &mut HashMap<String, ScaleTracker>) -> Vec<ThoughtAST> {
    // Shared: time facts (all lenses get these)
    let mut facts = encode_time_facts(candle);

    // Standard: window-based facts (all lenses get these)
    facts.extend(encode_standard_facts(window, scales));

    // Lens-specific modules
    match lens {
        MarketLens::Momentum => {
            facts.extend(encode_oscillator_facts(candle, scales));
            facts.extend(encode_momentum_facts(candle, scales));
            facts.extend(encode_stochastic_facts(candle, scales));
        }
        MarketLens::Structure => {
            facts.extend(encode_keltner_facts(candle, scales));
            facts.extend(encode_fibonacci_facts(candle, scales));
            facts.extend(encode_ichimoku_facts(candle, scales));
            facts.extend(encode_price_action_facts(candle, scales));
        }
        MarketLens::Volume => {
            facts.extend(encode_flow_facts(candle, scales));
        }
        MarketLens::Narrative => {
            facts.extend(encode_timeframe_facts(candle, scales));
            facts.extend(encode_divergence_facts(candle, scales));
        }
        MarketLens::Regime => {
            facts.extend(encode_regime_facts(candle, scales));
            facts.extend(encode_persistence_facts(candle, scales));
        }
        MarketLens::Generalist => {
            // ALL modules
            facts.extend(encode_oscillator_facts(candle, scales));
            facts.extend(encode_momentum_facts(candle, scales));
            facts.extend(encode_stochastic_facts(candle, scales));
            facts.extend(encode_keltner_facts(candle, scales));
            facts.extend(encode_fibonacci_facts(candle, scales));
            facts.extend(encode_ichimoku_facts(candle, scales));
            facts.extend(encode_price_action_facts(candle, scales));
            facts.extend(encode_flow_facts(candle, scales));
            facts.extend(encode_timeframe_facts(candle, scales));
            facts.extend(encode_divergence_facts(candle, scales));
            facts.extend(encode_regime_facts(candle, scales));
            facts.extend(encode_persistence_facts(candle, scales));
        }
    }

    facts
}

/// Collect exit vocab facts for a specific lens.
/// Proposal 026: all lenses gain regime and time atoms (universal context).
/// Generalist additionally gains self-assessment atoms.
pub fn exit_lens_facts(lens: &ExitLens, candle: &Candle, scales: &mut HashMap<String, ScaleTracker>) -> Vec<ThoughtAST> {
    let mut facts = match lens {
        ExitLens::Volatility => encode_exit_volatility_facts(candle, scales),
        ExitLens::Structure => encode_exit_structure_facts(candle, scales),
        ExitLens::Timing => encode_exit_timing_facts(candle, scales),
        ExitLens::Generalist => {
            let mut f = encode_exit_volatility_facts(candle, scales);
            f.extend(encode_exit_structure_facts(candle, scales));
            f.extend(encode_exit_timing_facts(candle, scales));
            f
        }
    };
    // Universal context: regime + time for all lenses
    facts.extend(encode_exit_regime_facts(candle, scales));
    facts.extend(encode_exit_time_facts(candle));
    facts
}

/// Collect exit self-assessment facts from the exit observer's rolling window.
/// Generalist-only for now. Returns empty for non-generalist lenses.
pub fn exit_self_assessment_facts(grace_rate: f64, avg_residue: f64, scales: &mut HashMap<String, ScaleTracker>) -> Vec<ThoughtAST> {
    // Self-assessment is on ALL lenses — it's an internal property
    // every exit observer has, not a generalist-only feature.
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
    use crate::types::enums::{MarketLens, ExitLens};

    #[test]
    fn test_market_lens_facts_differ_by_lens() {
        let candle = Candle::default();
        let window = vec![candle.clone()];
        let mut scales = std::collections::HashMap::new();

        let momentum_facts = market_lens_facts(&MarketLens::Momentum, &candle, &window, &mut scales);
        let volume_facts = market_lens_facts(&MarketLens::Volume, &candle, &window, &mut scales);
        let regime_facts = market_lens_facts(&MarketLens::Regime, &candle, &window, &mut scales);

        // Different lenses produce different numbers of facts
        // (all share time + standard, but lens-specific modules differ)
        assert_ne!(momentum_facts.len(), volume_facts.len());
        assert_ne!(volume_facts.len(), regime_facts.len());
    }

    #[test]
    fn test_generalist_includes_all_modules() {
        let candle = Candle::default();
        let window = vec![candle.clone()];
        let mut scales = std::collections::HashMap::new();

        let gen_facts = market_lens_facts(&MarketLens::Generalist, &candle, &window, &mut scales);

        // Generalist should have more facts than any single specialist
        for lens in &[MarketLens::Momentum, MarketLens::Structure, MarketLens::Volume,
                      MarketLens::Narrative, MarketLens::Regime] {
            let specialist_facts = market_lens_facts(lens, &candle, &window, &mut scales);
            assert!(
                gen_facts.len() >= specialist_facts.len(),
                "Generalist ({}) should have >= facts than {:?} ({})",
                gen_facts.len(),
                lens,
                specialist_facts.len(),
            );
        }
    }

    #[test]
    fn test_exit_lens_facts_variants() {
        let candle = Candle::default();
        let mut scales = std::collections::HashMap::new();

        let vol_facts = exit_lens_facts(&ExitLens::Volatility, &candle, &mut scales);
        let struct_facts = exit_lens_facts(&ExitLens::Structure, &candle, &mut scales);
        let timing_facts = exit_lens_facts(&ExitLens::Timing, &candle, &mut scales);
        let gen_facts = exit_lens_facts(&ExitLens::Generalist, &candle, &mut scales);

        // Proposal 026: all lenses get regime(8) + time(2) = +10 universal context
        assert!(!vol_facts.is_empty());
        assert!(!struct_facts.is_empty());
        // All specialists have their specific atoms + 10 universal
        assert_eq!(vol_facts.len(), 6 + 10);  // volatility(6) + regime(8) + time(2)
        assert_eq!(struct_facts.len(), 5 + 10); // structure(5) + regime(8) + time(2)
        assert_eq!(timing_facts.len(), 5 + 10); // timing(5) + regime(8) + time(2)
        // Generalist has all three specialists' specific atoms + one set of universal
        assert_eq!(gen_facts.len(), 6 + 5 + 5 + 10); // vol+struct+timing + regime+time
    }

    #[test]
    fn test_exit_self_assessment_generalist_only() {
        let mut scales = std::collections::HashMap::new();
        let facts = exit_self_assessment_facts(0.6, 0.005, &mut scales);
        assert_eq!(facts.len(), 2);
    }
}
