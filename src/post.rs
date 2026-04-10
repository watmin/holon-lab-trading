/// Post — a self-contained unit for one asset pair.
/// Owns market observers, exit observers, and brokers.

use std::collections::VecDeque;

use holon::kernel::vector::Vector;

use crate::broker::Broker;
use crate::candle::Candle;
use crate::ctx::Ctx;
use crate::distances::{distances_to_levels, Distances, Levels};
use crate::enums::{Direction, Outcome, Side, ThoughtAST};
use crate::exit_observer::ExitObserver;
use crate::indicator_bank::IndicatorBank;
use crate::log_entry::LogEntry;
use crate::market_observer::{lens_facts, MarketObserver};
use crate::newtypes::TradeId;
use crate::proposal::Proposal;
use crate::raw_candle::{Asset, RawCandle};
use crate::trade::Trade;

/// A post — per-asset-pair unit.
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

    /// The main per-candle entry point for a post.
    /// Returns (proposals, market_thoughts, misses).
    pub fn on_candle(
        &mut self,
        rc: &RawCandle,
        ctx: &Ctx,
    ) -> (Vec<Proposal>, Vec<Vector>, Vec<(ThoughtAST, Vector)>) {
        // Step: tick indicators
        let enriched = self.indicator_bank.tick(rc);

        // Push to window
        self.candle_window.push_back(enriched.clone());
        while self.candle_window.len() > self.max_window_size {
            self.candle_window.pop_front();
        }
        self.encode_count += 1;

        // Step: market observers observe-candle
        let n = self.market_observers.len();
        let m = self.exit_observers.len();
        let mut market_thoughts = Vec::with_capacity(n);
        let mut market_predictions = Vec::with_capacity(n);
        let mut market_edges = Vec::with_capacity(n);
        let mut all_misses = Vec::new();

        for obs in &mut self.market_observers {
            let fact_asts = lens_facts(&obs.lens, &enriched);
            let (thought, pred, edge, misses) =
                obs.observe_candle(fact_asts, &ctx.thought_encoder);
            market_thoughts.push(thought);
            market_predictions.push(pred);
            market_edges.push(edge);
            all_misses.extend(misses);
        }

        // N market x M exit -> N*M proposals
        let mut proposals = Vec::with_capacity(n * m);
        let price = self.current_price();

        for slot_idx in 0..(n * m) {
            let mi = slot_idx / m;
            let ei = slot_idx % m;
            let market_thought = &market_thoughts[mi];

            // Exit: encode facts and compose with market thought
            let exit_fact_asts = self.exit_observers[ei].encode_exit_facts(&enriched);
            let (composed, exit_misses) = self.exit_observers[ei].evaluate_and_compose(
                market_thought,
                exit_fact_asts,
                &ctx.thought_encoder,
            );
            all_misses.extend(exit_misses);

            // Exit: recommend distances
            let (dists, _exit_exp) = self.exit_observers[ei]
                .recommended_distances(&composed, &self.registry[slot_idx].scalar_accums);

            // Broker: propose Grace/Violence
            let _broker_pred = self.registry[slot_idx].propose(&composed);

            // Derive side from market prediction
            let side_val = match &market_predictions[mi] {
                crate::enums::Prediction::Discrete { scores, .. } => {
                    let up_score = scores
                        .iter()
                        .find(|(label, _)| label == "Up")
                        .map(|(_, s)| *s)
                        .unwrap_or(0.0);
                    let down_score = scores
                        .iter()
                        .find(|(label, _)| label == "Down")
                        .map(|(_, s)| *s)
                        .unwrap_or(0.0);
                    if up_score >= down_score {
                        Side::Buy
                    } else {
                        Side::Sell
                    }
                }
                _ => Side::Buy,
            };

            // Broker edge
            let edge_val = self.registry[slot_idx].edge();

            // Assemble proposal
            let prop = Proposal::new(
                composed.clone(),
                dists.clone(),
                edge_val,
                side_val,
                self.source_asset.clone(),
                self.target_asset.clone(),
                self.post_idx,
                slot_idx,
            );

            // Register paper
            self.registry[slot_idx].register_paper(composed, price, dists);

            proposals.push(prop);
        }

        (proposals, market_thoughts, all_misses)
    }

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

                // Compose fresh
                let exit_fact_asts = self.exit_observers[ei].encode_exit_facts(candle);
                let (composed, misses) = self.exit_observers[ei].evaluate_and_compose(
                    market_thought,
                    exit_fact_asts,
                    &ctx.thought_encoder,
                );
                all_misses.extend(misses);

                // Get fresh distances
                let (dists, _) = self.exit_observers[ei]
                    .recommended_distances(&composed, &self.registry[slot].scalar_accums);

                // Convert to levels
                let price = self.current_price();
                let lvls = distances_to_levels(&dists, price, &trade.side);

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
        outcome: &Outcome,
        weight: f64,
        direction: &Direction,
        optimal: &Distances,
    ) -> Vec<LogEntry> {
        // Broker propagate
        let (logs, facts) =
            self.registry[slot_idx].propagate(thought, outcome, weight, direction, optimal);

        // Apply propagation facts to observers
        let mi = facts.market_idx;
        let ei = facts.exit_idx;

        if mi < self.market_observers.len() {
            self.market_observers[mi].resolve(
                &facts.composed_thought,
                &facts.direction,
                facts.weight,
            );
        }

        if ei < self.exit_observers.len() {
            self.exit_observers[ei].observe_distances(
                &facts.composed_thought,
                &facts.optimal,
                facts.weight,
            );
        }

        logs
    }
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
            crate::enums::ExitLens::Volatility,
            256,
            500,
            0.02,
            0.03,
            0.05,
            0.025,
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
                crate::scalar_accumulator::ScalarAccumulator::new(
                    "tp",
                    crate::enums::ScalarEncoding::Log,
                    256,
                ),
                crate::scalar_accumulator::ScalarAccumulator::new(
                    "runner",
                    crate::enums::ScalarEncoding::Log,
                    256,
                ),
            ],
        )];
        let post = Post::new(
            0,
            Asset::new("BTC"),
            Asset::new("USD"),
            bank,
            200,
            market_obs,
            exit_obs,
            registry,
        );
        assert_eq!(post.post_idx, 0);
        assert_eq!(post.source_asset.name, "BTC");
        assert_eq!(post.encode_count, 0);
        assert_eq!(post.current_price(), 0.0);
    }
}
