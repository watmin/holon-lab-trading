/// Post — a self-contained unit for one asset pair. Compiled from wat/post.wat.
///
/// Owns the indicator bank, candle window, market observers, exit observers,
/// and the broker registry. Does NOT own proposals or trades.
///
/// CRITICAL: on_candle wires vocab modules to lenses. Each MarketLens selects
/// which vocab functions to call. This is NOT identical across observers.

use std::collections::{HashMap, VecDeque};
use rayon::prelude::*;

use holon::kernel::primitives::Primitives;
use holon::kernel::vector::Vector;

use crate::broker::Broker;
use crate::types::candle::Candle;
use crate::encoding::ctx::Ctx;
use crate::types::distances::{Distances, Levels};
use crate::types::enums::{Direction, ExitLens, MarketLens, Outcome, Prediction, Side};
use crate::exit_observer::ExitObserver;
use crate::indicator_bank::IndicatorBank;
use crate::types::log_entry::LogEntry;
use crate::market_observer::MarketObserver;
use crate::types::newtypes::{Price, TradeId};
use crate::trades::proposal::Proposal;
use crate::types::raw_candle::{Asset, RawCandle};
use crate::encoding::scale_tracker::ScaleTracker;
use crate::encoding::thought_encoder::{ThoughtAST, ToAst};
use crate::trades::trade::Trade;

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

/// A post -- per-asset-pair unit.
pub struct Post {
    pub post_idx: usize,
    pub source_asset: Asset,
    pub target_asset: Asset,
    pub indicator_bank: IndicatorBank,
    pub candle_window: VecDeque<Candle>,
    pub max_window_size: usize,
    pub market_observers: Vec<MarketObserver>,
    pub exit_observers: Vec<ExitObserver>,
    pub registry: Vec<Broker>,
    pub encode_count: usize,
    pub scales: HashMap<String, ScaleTracker>,
}

impl Post {
    pub fn new(
        post_idx: usize,
        source: Asset,
        target: Asset,
        indicator_bank: IndicatorBank,
        max_window_size: usize,
        market_observers: Vec<MarketObserver>,
        exit_observers: Vec<ExitObserver>,
        registry: Vec<Broker>,
    ) -> Self {
        Self {
            post_idx,
            source_asset: source,
            target_asset: target,
            indicator_bank,
            candle_window: VecDeque::new(),
            max_window_size,
            market_observers,
            exit_observers,
            registry,
            encode_count: 0,
            scales: HashMap::new(),
        }
    }

    /// Last close price. Panics if called before the first tick.
    pub fn last_close(&self) -> Price {
        Price(
            self.candle_window
                .back()
                .expect("last_close called before first candle tick")
                .close,
        )
    }

    // Lens facts methods removed -- see free functions below.

    /// The main per-candle entry point.
    /// Returns (proposals, market_thoughts, misses).
    pub fn on_candle(
        &mut self,
        rc: &RawCandle,
        ctx: &Ctx,
    ) -> (Vec<Proposal>, Vec<Vector>, Vec<(ThoughtAST, Vector)>) {
        // Step: tick indicators -> enriched candle
        let enriched = self.indicator_bank.tick(rc);

        // Push to window
        self.candle_window.push_back(enriched.clone());
        while self.candle_window.len() > self.max_window_size {
            self.candle_window.pop_front();
        }
        self.encode_count += 1;

        // Step: market observers observe-candle (each with its own lens facts)
        let n = self.market_observers.len();
        let m = self.exit_observers.len();
        let mut market_thoughts = Vec::with_capacity(n);
        let mut market_predictions = Vec::with_capacity(n);
        let mut market_edges = Vec::with_capacity(n);
        let mut all_misses = Vec::new();

        // Collect lens-specific facts BEFORE mutably borrowing observers
        let window: Vec<Candle> = self.candle_window.iter().cloned().collect();
        // Collect facts sequentially — scales are mutable state on the post.
        // Then encode and observe in parallel.
        let all_facts: Vec<Vec<ThoughtAST>> = self
            .market_observers
            .iter()
            .map(|obs| market_lens_facts(&obs.lens, &enriched, &window, &mut self.scales))
            .collect();
        // pmap: each observer encodes and observes with pre-collected facts.
        let market_results: Vec<_> = self
            .market_observers
            .par_iter_mut()
            .zip(all_facts.into_par_iter())
            .map(|(obs, facts)| {
                let (thought, misses) = obs.incremental.encode(&facts, &ctx.thought_encoder);
                let result = obs.observe(thought, Vec::new());
                (result.anomaly.clone(), result.prediction, result.edge, misses)
            })
            .collect();

        for (thought, prediction, edge, misses) in market_results {
            market_thoughts.push(thought);
            market_predictions.push(prediction);
            market_edges.push(edge);
            all_misses.extend(misses);
        }

        // Pre-encode exit facts per exit observer (M, not N×M).
        // Each exit observer's incremental bundle maintains sums across candles.
        // The exit_vecs are then shared across all N market observers.
        // Proposal 026: includes regime, time, and self-assessment (generalist only).
        // Collect facts sequentially — scales are mutable state on the post.
        let all_exit_facts: Vec<Vec<ThoughtAST>> = self
            .exit_observers
            .iter()
            .map(|eobs| {
                let mut exit_fact_asts = exit_lens_facts(&eobs.lens, &enriched, &mut self.scales);
                let self_facts = exit_self_assessment_facts(
                    eobs.grace_rate, eobs.avg_residue, &mut self.scales);
                exit_fact_asts.extend(self_facts);
                exit_fact_asts
            })
            .collect();
        let exit_results: Vec<_> = self
            .exit_observers
            .par_iter_mut()
            .zip(all_exit_facts.into_par_iter())
            .map(|(eobs, exit_fact_asts)| {
                eobs.incremental.encode(&exit_fact_asts, &ctx.thought_encoder)
            })
            .collect();
        let exit_vecs: Vec<Vector> = exit_results.iter().map(|(v, _)| v.clone()).collect();
        for (_, exit_misses) in &exit_results {
            all_misses.extend(exit_misses.iter().cloned());
        }

        // N market x M exit -> N*M proposals
        // Parallel phase: compute values. Sequential phase: apply mutations.
        let price = self.last_close();
        let source = &self.source_asset;
        let target = &self.target_asset;
        let post_idx = self.post_idx;
        let exit_observers = &self.exit_observers;

        // pmap: each slot computes independently. Pure reads only.
        let grid_values: Vec<_> = (0..(n * m))
            .into_par_iter()
            .map(|slot_idx| {
                let mi = slot_idx / m;
                let ei = slot_idx % m;
                let market_thought = &market_thoughts[mi];

                // Exit vec already encoded above (incremental per exit observer)
                let exit_vec = &exit_vecs[ei];

                // Compose market thought with exit facts
                let composed = Primitives::bundle(&[market_thought, exit_vec]);

                // Exit: tier 1 only — reckoner distances.
                // The broker owns the full cascade (reckoner → accumulator → default).
                // Proposal 026: exit reckoner queries on exit_vec only, not composed.
                let reckoner_dists = exit_observers[ei].reckoner_distances(exit_vec);

                // Derive side (reads only). Edge is zero — broker has no reckoner.
                let side_val = derive_side(&market_predictions[mi]);
                let edge_val = 0.0_f64;
                let enterprise_pred = prediction_convert(&market_predictions[mi]);

                // Derive direction for paper registration
                let direction = if market_predictions[mi].direction.map_or(true, |d| d.index() == 0) {
                    Direction::Up
                } else {
                    Direction::Down
                };

                // Return values — no mutation
                (slot_idx, mi, ei, composed, reckoner_dists, side_val, edge_val, enterprise_pred, direction)
            })
            .collect();

        // Build proposals + apply mutations per-broker in parallel.
        // The broker owns the distance cascade (reckoner → accumulator → default).
        // grid_values is indexed by position (0..n*m), which IS the slot_idx.
        let proposals: Vec<_> = self.registry
            .par_iter_mut()
            .zip(grid_values.into_par_iter())
            .map(|(broker, (slot_idx, mi, ei, composed, reckoner_dists, side_val, edge_val, enterprise_pred, direction)): (&mut Broker, (usize, usize, usize, Vector, Option<Distances>, Side, f64, crate::types::enums::Prediction, Direction))| {
                let dists = broker.cascade_distances(reckoner_dists);
                // Proposal 035: no propose(). Register paper with market_thought as composed.
                broker.register_paper(composed.clone(), market_thoughts[mi].clone(), exit_vecs[ei].clone(), direction, price, dists);
                Proposal::new(
                    composed,
                    market_thoughts[mi].clone(),
                    exit_vecs[ei].clone(),
                    dists,
                    edge_val,
                    side_val,
                    source.clone(),
                    target.clone(),
                    enterprise_pred,
                    post_idx,
                    slot_idx,
                )
            })
            .collect();

        (proposals, market_thoughts, all_misses)
    }

    // All lens-facts logic is in the free functions below.

    /// Update triggers: re-query exit observers for fresh distances on active trades.
    pub fn update_triggers(
        &self,
        trades: &[(TradeId, &Trade)],
        market_thoughts: &[Vector],
        ctx: &Ctx,
    ) -> (Vec<(TradeId, Levels)>, Vec<(ThoughtAST, Vector)>) {
        let m = self.exit_observers.len();
        let mut level_updates = Vec::new();
        let mut all_misses = Vec::new();

        if let Some(candle) = self.candle_window.back() {
            for (tid, trade) in trades {
                let slot = trade.broker_slot_idx;
                let mi = slot / m;
                let ei = slot % m;

                if mi >= market_thoughts.len() {
                    continue;
                }

                let _market_thought = &market_thoughts[mi];

                // Exit: encode facts via lens
                // Note: update_triggers uses &self (immutable), so scales cannot be updated.
                // Use the struct's forms() path (hardcoded scales) — correct for trigger queries
                // where exact scale doesn't matter for distance estimation.
                let exit_lens = self.exit_observers[ei].lens;
                let mut exit_fact_asts = match exit_lens {
                    ExitLens::Volatility => crate::vocab::exit::volatility::ExitVolatilityThought::from_candle(candle).forms(),
                    ExitLens::Structure => crate::vocab::exit::structure::ExitStructureThought::from_candle(candle).forms(),
                    ExitLens::Timing => crate::vocab::exit::timing::ExitTimingThought::from_candle(candle).forms(),
                    ExitLens::Generalist => {
                        let mut f = crate::vocab::exit::volatility::ExitVolatilityThought::from_candle(candle).forms();
                        f.extend(crate::vocab::exit::structure::ExitStructureThought::from_candle(candle).forms());
                        f.extend(crate::vocab::exit::timing::ExitTimingThought::from_candle(candle).forms());
                        f
                    }
                };
                exit_fact_asts.extend(crate::vocab::exit::regime::ExitRegimeThought::from_candle(candle).forms());
                exit_fact_asts.extend(encode_exit_time_facts(candle));
                let self_facts = crate::vocab::exit::self_assessment::ExitSelfAssessmentThought::new(
                    self.exit_observers[ei].grace_rate,
                    self.exit_observers[ei].avg_residue,
                ).forms();
                exit_fact_asts.extend(self_facts);
                let exit_bundle = ThoughtAST::Bundle(exit_fact_asts);
                let (exit_vec, misses) = ctx.thought_encoder.encode(&exit_bundle);
                all_misses.extend(misses);

                // Get fresh distances — broker owns the cascade
                // Proposal 026: exit reckoner queries on exit_vec only, not composed.
                let reckoner_dists = self.exit_observers[ei].reckoner_distances(&exit_vec);
                let dists = self.registry[slot].cascade_distances(reckoner_dists);

                // Convert to levels
                let price = self.last_close();
                let lvls = dists.to_levels(price, trade.side);

                level_updates.push((*tid, lvls));
            }
        }

        (level_updates, all_misses)
    }

    /// Propagate a resolved outcome to the right observers.
    /// Proposal 026: exit observer learns from exit_thought only, not composed.
    pub fn propagate(
        &mut self,
        slot_idx: usize,
        thought: &Vector,
        market_thought: &Vector,
        exit_thought: &Vector,
        outcome: Outcome,
        weight: f64,
        direction: Direction,
        optimal: &Distances,
        recalib_interval: usize,
    ) -> Vec<LogEntry> {
        // Broker propagate -- returns facts for observers
        let facts = self.registry[slot_idx].propagate(
            thought,
            market_thought,
            exit_thought,
            outcome,
            weight,
            direction,
            optimal,
            ctx_scalar_encoder_placeholder(),
        );

        // Apply propagation facts to observers
        let mi = facts.market_idx;
        let ei = facts.exit_idx;
        let mut observers_updated: usize = 0;

        // Proposal 024: market observer learns from market_thought (the anomaly),
        // not composed_thought.
        if mi < self.market_observers.len() {
            self.market_observers[mi].resolve(
                &facts.market_thought,
                facts.direction,
                facts.weight,
                recalib_interval,
            );
            observers_updated += 1;
        }

        // Proposal 026: exit observer learns from exit_thought only.
        let is_grace = outcome == Outcome::Grace;
        if ei < self.exit_observers.len() {
            self.exit_observers[ei].observe_distances(
                &facts.exit_thought,
                &facts.optimal,
                facts.weight,
                is_grace,
                facts.optimal.trail, // residue proxy: optimal trail distance
            );
            observers_updated += 1;
        }

        vec![LogEntry::Propagated {
            broker_slot_idx: slot_idx,
            observers_updated,
        }]
    }
}

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

/// Derive Side from a holon-rs Prediction. Up -> Buy, Down -> Sell.
pub fn derive_side(pred: &holon::memory::Prediction) -> Side {
    if let Some(dir) = pred.direction {
        if dir.index() == 0 {
            Side::Buy // "Up" is label 0
        } else {
            Side::Sell // "Down" is label 1
        }
    } else {
        Side::Buy // default
    }
}

/// Convert holon-rs Prediction to enterprise Prediction.
pub fn prediction_convert(pred: &holon::memory::Prediction) -> Prediction {
    Prediction::Discrete {
        scores: pred
            .scores
            .iter()
            .map(|ls| (format!("{}", ls.label.index()), ls.cosine))
            .collect(),
        conviction: pred.conviction,
    }
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
    use crate::types::enums::MarketLens;
    use crate::learning::window_sampler::WindowSampler;

    #[test]
    fn test_post_construct() {
        let bank = IndicatorBank::new();
        let market_obs = vec![MarketObserver::new(
            MarketLens::Momentum,
            256,
            500,
            WindowSampler::new(42, 10, 200),
        )];
        let exit_obs = vec![ExitObserver::new(
            ExitLens::Volatility,
            256,
            500,
            0.02,
            0.03,
        )];
        let registry = vec![Broker::new(
            vec!["momentum".into(), "volatility".into()],
            0,
            1,
            vec![
                crate::learning::scalar_accumulator::ScalarAccumulator::new(
                    "trail",
                    crate::types::enums::ScalarEncoding::Log,
                    256,
                ),
                crate::learning::scalar_accumulator::ScalarAccumulator::new(
                    "stop",
                    crate::types::enums::ScalarEncoding::Log,
                    256,
                ),
            ],
            Distances::new(0.015, 0.030),
            0.0010, // swap_fee
        )];
        let post = Post::new(
            0,
            Asset::new("USDC"),
            Asset::new("WBTC"),
            bank,
            200,
            market_obs,
            exit_obs,
            registry,
        );
        assert_eq!(post.post_idx, 0);
        assert_eq!(post.source_asset.name, "USDC");
        assert_eq!(post.encode_count, 0);
        // last_close() panics on empty window — correct, it's a programming error
    }

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
