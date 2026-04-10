/// Post — a self-contained unit for one asset pair. Compiled from wat/post.wat.
///
/// Owns the indicator bank, candle window, market observers, exit observers,
/// and the broker registry. Does NOT own proposals or trades.
///
/// CRITICAL: on_candle wires vocab modules to lenses. Each MarketLens selects
/// which vocab functions to call. This is NOT identical across observers.

use std::collections::VecDeque;
use rayon::prelude::*;

use holon::kernel::primitives::Primitives;
use holon::kernel::vector::Vector;

use crate::broker::Broker;
use crate::candle::Candle;
use crate::ctx::Ctx;
use crate::distances::{Distances, Levels};
use crate::enums::{Direction, ExitLens, MarketLens, Outcome, Prediction, Side};
use crate::exit_observer::ExitObserver;
use crate::indicator_bank::IndicatorBank;
use crate::log_entry::LogEntry;
use crate::market_observer::MarketObserver;
use crate::newtypes::TradeId;
use crate::proposal::Proposal;
use crate::raw_candle::{Asset, RawCandle};
use crate::thought_encoder::ThoughtAST;
use crate::trade::Trade;

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
        }
    }

    /// Current price: close of the last candle.
    pub fn current_price(&self) -> f64 {
        self.candle_window
            .back()
            .map(|c| c.close)
            .unwrap_or(0.0)
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
        // pmap: each observer does everything — facts, encode, observe.
        // Each observer is independent. ctx is shared immutable.
        let market_results: Vec<_> = self
            .market_observers
            .par_iter_mut()
            .map(|obs| {
                let facts = market_lens_facts(&obs.lens, &enriched, &window);
                let bundle_ast = ThoughtAST::Bundle(facts);
                let (thought, misses) = ctx.thought_encoder.encode(&bundle_ast);
                let result = obs.observe(thought, Vec::new());
                (result.thought.clone(), result.prediction, result.edge, misses)
            })
            .collect();

        for (thought, prediction, edge, misses) in market_results {
            market_thoughts.push(thought);
            market_predictions.push(prediction);
            market_edges.push(edge);
            all_misses.extend(misses);
        }

        // N market x M exit -> N*M proposals
        // Parallel phase: compute values. Sequential phase: apply mutations.
        let price = self.current_price();
        let source = &self.source_asset;
        let target = &self.target_asset;
        let post_idx = self.post_idx;
        let exit_observers = &self.exit_observers;
        let registry = &self.registry;

        // pmap: each slot computes independently. Pure reads only.
        let grid_values: Vec<_> = (0..(n * m))
            .into_par_iter()
            .map(|slot_idx| {
                let mi = slot_idx / m;
                let ei = slot_idx % m;
                let market_thought = &market_thoughts[mi];

                // Exit: encode facts via lens
                let exit_lens = exit_observers[ei].lens;
                let exit_fact_asts = exit_lens_facts(&exit_lens, &enriched);

                // Bundle exit facts and encode
                let exit_bundle = ThoughtAST::Bundle(exit_fact_asts);
                let (exit_vec, exit_misses) = ctx.thought_encoder.encode(&exit_bundle);

                // Compose market thought with exit facts
                let composed = Primitives::bundle(&[market_thought, &exit_vec]);

                // Exit: recommend distances
                let (dists, _exit_exp) = exit_observers[ei].recommended_distances(
                    &composed,
                    &registry[slot_idx].scalar_accums,
                    ctx.thought_encoder.scalar_encoder(),
                );

                // Derive side + edge (reads only)
                let side_val = derive_side_from_prediction(&market_predictions[mi]);
                let edge_val = registry[slot_idx].edge();
                let enterprise_pred = holon_prediction_to_enterprise(&market_predictions[mi]);

                // Return values — no mutation
                (slot_idx, composed, dists, side_val, edge_val, enterprise_pred, exit_misses)
            })
            .collect();

        // Sequential phase: apply mutations, build proposals
        let mut proposals = Vec::with_capacity(n * m);
        for (slot_idx, composed, dists, side_val, edge_val, enterprise_pred, exit_misses) in grid_values {
            all_misses.extend(exit_misses);

            // Broker: propose (mutates reckoner)
            let _broker_pred = self.registry[slot_idx].propose(&composed);

            // Assemble proposal
            let prop = Proposal::new(
                composed.clone(),
                dists,
                edge_val,
                side_val,
                source.clone(),
                target.clone(),
                enterprise_pred,
                post_idx,
                slot_idx,
            );

            // Register paper (mutates broker papers)
            self.registry[slot_idx].register_paper(composed, price, dists);

            proposals.push(prop);
        }

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

                let market_thought = &market_thoughts[mi];

                // Exit: encode facts via lens and compose with market thought
                let exit_lens = self.exit_observers[ei].lens;
                let exit_fact_asts = exit_lens_facts(&exit_lens, candle);
                let exit_bundle = ThoughtAST::Bundle(exit_fact_asts);
                let (exit_vec, misses) = ctx.thought_encoder.encode(&exit_bundle);
                all_misses.extend(misses);

                let composed = Primitives::bundle(&[market_thought, &exit_vec]);

                // Get fresh distances
                let (dists, _) = self.exit_observers[ei].recommended_distances(
                    &composed,
                    &self.registry[slot].scalar_accums,
                    ctx.thought_encoder.scalar_encoder(),
                );

                // Convert to levels
                let price = self.current_price();
                let lvls = dists.to_levels(price, trade.side);

                level_updates.push((*tid, lvls));
            }
        }

        (level_updates, all_misses)
    }

    /// Propagate a resolved outcome to the right observers.
    pub fn propagate(
        &mut self,
        slot_idx: usize,
        thought: &Vector,
        outcome: Outcome,
        weight: f64,
        direction: Direction,
        optimal: &Distances,
        recalib_interval: usize,
    ) -> Vec<LogEntry> {
        // Broker propagate -- returns facts for observers
        let facts = self.registry[slot_idx].propagate(
            thought,
            outcome,
            weight,
            direction,
            optimal,
            recalib_interval,
            ctx_scalar_encoder_placeholder(),
        );

        // Apply propagation facts to observers
        let mi = facts.market_idx;
        let ei = facts.exit_idx;

        if mi < self.market_observers.len() {
            self.market_observers[mi].resolve(
                &facts.composed_thought,
                facts.direction,
                facts.weight,
                recalib_interval,
            );
        }

        if ei < self.exit_observers.len() {
            self.exit_observers[ei].observe_distances(
                &facts.composed_thought,
                &facts.optimal,
                facts.weight,
            );
        }

        vec![LogEntry::Propagated {
            broker_slot_idx: slot_idx,
            observers_updated: 2,
        }]
    }
}

/// Collect market vocab facts for a specific lens.
/// Each MarketLens selects different modules. All include shared/time + standard.
/// This is the CRITICAL wiring -- different lenses see different market data.
fn market_lens_facts(lens: &MarketLens, candle: &Candle, window: &[Candle]) -> Vec<ThoughtAST> {
    // Shared: time facts (all lenses get these)
    let mut facts = encode_time_facts(candle);

    // Standard: window-based facts (all lenses get these)
    facts.extend(encode_standard_facts(window));

    // Lens-specific modules
    match lens {
        MarketLens::Momentum => {
            facts.extend(encode_oscillator_facts(candle));
            facts.extend(encode_momentum_facts(candle));
            facts.extend(encode_stochastic_facts(candle));
        }
        MarketLens::Structure => {
            facts.extend(encode_keltner_facts(candle));
            facts.extend(encode_fibonacci_facts(candle));
            facts.extend(encode_ichimoku_facts(candle));
            facts.extend(encode_price_action_facts(candle));
        }
        MarketLens::Volume => {
            facts.extend(encode_flow_facts(candle));
        }
        MarketLens::Narrative => {
            facts.extend(encode_timeframe_facts(candle));
            facts.extend(encode_divergence_facts(candle));
        }
        MarketLens::Regime => {
            facts.extend(encode_regime_facts(candle));
            facts.extend(encode_persistence_facts(candle));
        }
        MarketLens::Generalist => {
            // ALL modules
            facts.extend(encode_oscillator_facts(candle));
            facts.extend(encode_momentum_facts(candle));
            facts.extend(encode_stochastic_facts(candle));
            facts.extend(encode_keltner_facts(candle));
            facts.extend(encode_fibonacci_facts(candle));
            facts.extend(encode_ichimoku_facts(candle));
            facts.extend(encode_price_action_facts(candle));
            facts.extend(encode_flow_facts(candle));
            facts.extend(encode_timeframe_facts(candle));
            facts.extend(encode_divergence_facts(candle));
            facts.extend(encode_regime_facts(candle));
            facts.extend(encode_persistence_facts(candle));
        }
    }

    facts
}

/// Collect exit vocab facts for a specific lens.
fn exit_lens_facts(lens: &ExitLens, candle: &Candle) -> Vec<ThoughtAST> {
    match lens {
        ExitLens::Volatility => encode_exit_volatility_facts(candle),
        ExitLens::Structure => encode_exit_structure_facts(candle),
        ExitLens::Timing => encode_exit_timing_facts(candle),
        ExitLens::Generalist => {
            let mut facts = encode_exit_volatility_facts(candle);
            facts.extend(encode_exit_structure_facts(candle));
            facts.extend(encode_exit_timing_facts(candle));
            facts
        }
    }
}

/// Derive Side from a holon-rs Prediction. Up -> Buy, Down -> Sell.
fn derive_side_from_prediction(pred: &holon::memory::Prediction) -> Side {
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
fn holon_prediction_to_enterprise(pred: &holon::memory::Prediction) -> Prediction {
    Prediction::Discrete {
        scores: pred
            .scores
            .iter()
            .map(|ls| (format!("{}", ls.label.index()), ls.cosine))
            .collect(),
        conviction: pred.conviction,
    }
}

/// Placeholder: creates a ScalarEncoder for broker propagation.
/// In the full system, this would come from ctx.
pub fn ctx_scalar_encoder_placeholder() -> &'static holon::kernel::scalar::ScalarEncoder {
    use std::sync::OnceLock;
    static SE: OnceLock<holon::kernel::scalar::ScalarEncoder> = OnceLock::new();
    SE.get_or_init(|| holon::kernel::scalar::ScalarEncoder::new(4096))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::enums::MarketLens;
    use crate::window_sampler::WindowSampler;

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
            256,
            500,
            vec![
                crate::scalar_accumulator::ScalarAccumulator::new(
                    "trail",
                    crate::enums::ScalarEncoding::Log,
                    256,
                ),
                crate::scalar_accumulator::ScalarAccumulator::new(
                    "stop",
                    crate::enums::ScalarEncoding::Log,
                    256,
                ),
            ],
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
        assert_eq!(post.current_price(), 0.0);
    }

    #[test]
    fn test_market_lens_facts_differ_by_lens() {
        let candle = Candle::default();
        let window = vec![candle.clone()];

        let momentum_facts = market_lens_facts(&MarketLens::Momentum, &candle, &window);
        let volume_facts = market_lens_facts(&MarketLens::Volume, &candle, &window);
        let regime_facts = market_lens_facts(&MarketLens::Regime, &candle, &window);

        // Different lenses produce different numbers of facts
        // (all share time + standard, but lens-specific modules differ)
        assert_ne!(momentum_facts.len(), volume_facts.len());
        assert_ne!(volume_facts.len(), regime_facts.len());
    }

    #[test]
    fn test_generalist_includes_all_modules() {
        let candle = Candle::default();
        let window = vec![candle.clone()];

        let gen_facts = market_lens_facts(&MarketLens::Generalist, &candle, &window);

        // Generalist should have more facts than any single specialist
        for lens in &[MarketLens::Momentum, MarketLens::Structure, MarketLens::Volume,
                      MarketLens::Narrative, MarketLens::Regime] {
            let specialist_facts = market_lens_facts(lens, &candle, &window);
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

        let vol_facts = exit_lens_facts(&ExitLens::Volatility, &candle);
        let struct_facts = exit_lens_facts(&ExitLens::Structure, &candle);
        let gen_facts = exit_lens_facts(&ExitLens::Generalist, &candle);

        assert!(!vol_facts.is_empty());
        assert!(!struct_facts.is_empty());
        // Generalist includes all three
        assert_eq!(gen_facts.len(), vol_facts.len() + struct_facts.len() + {
            exit_lens_facts(&ExitLens::Timing, &candle).len()
        });
    }
}
