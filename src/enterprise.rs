/// Enterprise — the coordination plane. Compiled from wat/enterprise.wat.
///
/// Three fields: posts, treasury, market_thoughts_cache.
/// Routes raw candles to posts. CSP sync point.
/// Returns (Vec<LogEntry>, Vec<misses>) from on_candle. Values up.

use std::collections::HashMap;

use rayon::prelude::*;
use holon::kernel::vector::Vector;

use crate::broker::Resolution;
use crate::ctx::Ctx;
use crate::distances::Distances;
use crate::enums::{Direction, Outcome};
use crate::log_entry::LogEntry;
use crate::post::{Post, ctx_scalar_encoder_placeholder};
use crate::raw_candle::RawCandle;
use crate::simulation::compute_optimal_distances;
use crate::thought_encoder::ThoughtAST;
use crate::treasury::Treasury;

/// The enterprise — coordination plane.
pub struct Enterprise {
    pub posts: Vec<Post>,
    pub treasury: Treasury,
    pub market_thoughts_cache: Vec<Vec<Vector>>,
}

impl Enterprise {
    pub fn new(posts: Vec<Post>, treasury: Treasury) -> Self {
        let cache = posts.iter().map(|_| Vec::new()).collect();
        Self {
            posts,
            treasury,
            market_thoughts_cache: cache,
        }
    }

    /// on-candle -- the four-step loop.
    /// Returns (Vec<LogEntry>, Vec<misses>).
    pub fn on_candle(
        &mut self,
        rc: &RawCandle,
        ctx: &Ctx,
    ) -> (Vec<LogEntry>, Vec<(ThoughtAST, Vector)>) {
        // Find the right post
        let post_idx = self
            .posts
            .iter()
            .position(|p| {
                p.source_asset == rc.source_asset && p.target_asset == rc.target_asset
            })
            .unwrap_or(0);

        // Step 1: RESOLVE + PROPAGATE
        let mut all_logs = self.step_resolve_and_propagate();

        // Step 2: COMPUTE + DISPATCH
        let (proposals, market_thoughts, mut all_misses) =
            self.step_compute_dispatch(post_idx, rc, ctx);

        // Cache market thoughts for step 3c
        if post_idx < self.market_thoughts_cache.len() {
            self.market_thoughts_cache[post_idx] = market_thoughts.clone();
        }

        // Submit proposals to treasury
        for prop in proposals {
            self.treasury.submit_proposal(prop);
        }

        // Step 3a: TICK
        let (resolutions, tick_logs) = self.step_tick(post_idx);
        all_logs.extend(tick_logs);

        // Step 3b: PROPAGATE (sequential -- paper resolutions)
        let prop_logs = self.step_propagate(post_idx, resolutions);
        all_logs.extend(prop_logs);

        // Step 3c: UPDATE TRIGGERS
        let trigger_misses = self.step_update_triggers(post_idx, &market_thoughts, ctx);
        all_misses.extend(trigger_misses);

        // Step 4: COLLECT + FUND
        let fund_logs = self.step_collect_fund();
        all_logs.extend(fund_logs);

        (all_logs, all_misses)
    }

    /// Process a batch of candles within one recalibration window.
    /// The indicator bank ticks sequentially (streaming state).
    /// The encoding + composition + paper registration runs in parallel
    /// across all candles in the batch — the discriminant is frozen.
    /// Sync at the end: apply all accumulated observations, recalibrate.
    pub fn on_candle_batch(
        &mut self,
        candles: &[RawCandle],
        ctx: &Ctx,
    ) -> (Vec<LogEntry>, Vec<(ThoughtAST, Vector)>) {
        let mut all_logs = Vec::new();
        let mut all_misses = Vec::new();

        let post_idx = 0; // Single post for now

        // Phase 1: Tick indicators sequentially — streaming state requires order.
        // Produces enriched candles for the batch.
        let mut enriched_candles = Vec::with_capacity(candles.len());
        for rc in candles {
            let enriched = self.posts[post_idx].indicator_bank.tick(rc);
            self.posts[post_idx].candle_window.push_back(enriched.clone());
            while self.posts[post_idx].candle_window.len() > self.posts[post_idx].max_window_size {
                self.posts[post_idx].candle_window.pop_front();
            }
            self.posts[post_idx].encode_count += 1;
            enriched_candles.push(enriched);
        }

        // Phase 2: For each candle, compute the full encoding + composition in parallel.
        // The discriminant is frozen within this window — predictions are stable.
        // Each candle produces: proposals, market_thoughts, misses, resolutions.
        let post = &self.posts[post_idx];
        let n = post.market_observers.len();
        let m = post.exit_observers.len();

        // Parallel across candles: each candle's encoding is independent.
        // Within each candle: the N×M grid is also parallel.
        let batch_results: Vec<_> = enriched_candles
            .par_iter()
            .enumerate()
            .map(|(_candle_offset, enriched)| {
                let window: Vec<_> = {
                    // Window for this candle — use the full candle_window at this point
                    // (simplified: all candles share the same window view)
                    post.candle_window.iter().cloned().collect()
                };

                // Market observer encoding — parallel across observers
                let market_results: Vec<_> = post
                    .market_observers
                    .iter()
                    .map(|obs| {
                        let facts = crate::post::market_lens_facts_pub(&obs.lens, enriched, &window);
                        let bundle_ast = ThoughtAST::Bundle(facts);
                        let (thought, misses) = ctx.thought_encoder.encode(&bundle_ast);
                        // Can't call obs.observe() here — it mutates. Defer.
                        // Just return the encoded thought and misses.
                        (thought, misses)
                    })
                    .collect();

                let market_thoughts: Vec<Vector> = market_results.iter().map(|(t, _)| t.clone()).collect();
                let candle_misses: Vec<(ThoughtAST, Vector)> = market_results.into_iter().flat_map(|(_, m)| m).collect();

                // N×M grid — exit encoding + composition
                let grid_results: Vec<_> = (0..(n * m))
                    .map(|slot_idx| {
                        let mi = slot_idx / m;
                        let ei = slot_idx % m;
                        let market_thought = &market_thoughts[mi];

                        let exit_facts = crate::post::exit_lens_facts_pub(&post.exit_observers[ei].lens, enriched);
                        let exit_bundle = ThoughtAST::Bundle(exit_facts);
                        let (exit_vec, exit_misses) = ctx.thought_encoder.encode(&exit_bundle);

                        let composed = holon::kernel::primitives::Primitives::bundle(&[market_thought, &exit_vec]);

                        let (dists, _) = post.exit_observers[ei].recommended_distances(
                            &composed,
                            &post.registry[slot_idx].scalar_accums,
                            ctx.thought_encoder.scalar_encoder(),
                        );

                        (slot_idx, composed, dists, exit_misses)
                    })
                    .collect();

                let grid_misses: Vec<(ThoughtAST, Vector)> = grid_results.iter().flat_map(|(_, _, _, m)| m.clone()).collect();

                (market_thoughts, candle_misses, grid_misses, grid_results)
            })
            .collect();

        // Phase 3: Sequential — apply all mutations from the batch.
        // The discriminant hasn't changed. Now we apply all deferred updates.
        for (market_thoughts, candle_misses, grid_misses, grid_results) in batch_results {
            all_misses.extend(candle_misses);
            all_misses.extend(grid_misses);

            // Cache market thoughts
            if post_idx < self.market_thoughts_cache.len() {
                self.market_thoughts_cache[post_idx] = market_thoughts;
            }

            // Apply broker mutations sequentially (propose + register paper)
            let price = self.posts[post_idx].current_price();
            for (slot_idx, composed, dists, _) in grid_results {
                self.posts[post_idx].registry[slot_idx].propose(&composed);
                self.posts[post_idx].registry[slot_idx].register_paper(composed, price, dists);
            }

            // Tick papers
            let (resolutions, tick_logs) = self.step_tick(post_idx);
            all_logs.extend(tick_logs);

            // Propagate
            let prop_logs = self.step_propagate(post_idx, resolutions);
            all_logs.extend(prop_logs);
        }

        // Phase 4: Treasury operations for the full batch
        let fund_logs = self.step_collect_fund();
        all_logs.extend(fund_logs);

        (all_logs, all_misses)
    }

    /// Step 1: RESOLVE + PROPAGATE.
    /// Settle triggered trades, propagate outcomes to observers.
    fn step_resolve_and_propagate(&mut self) -> Vec<LogEntry> {
        // Collect current prices from each post
        let mut current_prices: HashMap<(String, String), f64> = HashMap::new();
        for p in &self.posts {
            current_prices.insert(
                (p.source_asset.name.clone(), p.target_asset.name.clone()),
                p.current_price(),
            );
        }

        // Treasury settles triggered trades
        let (settlements, mut settle_logs) = self.treasury.settle_triggered(&current_prices);

        // For each settlement: compute direction + optimal, propagate
        for stl in settlements {
            let t = &stl.trade;
            let post_idx = t.post_idx;
            let slot = t.broker_slot_idx;

            // Derive direction from price movement
            let direction = if stl.exit_price > t.entry_price {
                Direction::Up
            } else {
                Direction::Down
            };

            // Compute optimal distances from trade's price history
            let optimal = compute_optimal_distances(&t.price_history, direction);

            // Propagate to the post
            if post_idx < self.posts.len() {
                let recalib = 500; // default recalib interval
                let prop_logs = self.posts[post_idx].propagate(
                    slot,
                    &stl.composed_thought,
                    stl.outcome,
                    stl.amount,
                    direction,
                    &optimal,
                    recalib,
                );
                settle_logs.extend(prop_logs);
            }
        }

        settle_logs
    }

    /// Step 2: COMPUTE + DISPATCH.
    /// Post encodes, composes, proposes.
    fn step_compute_dispatch(
        &mut self,
        post_idx: usize,
        rc: &RawCandle,
        ctx: &Ctx,
    ) -> (Vec<crate::proposal::Proposal>, Vec<Vector>, Vec<(ThoughtAST, Vector)>) {
        self.posts[post_idx].on_candle(rc, ctx)
    }

    /// Step 3a: TICK — parallel tick of all brokers' papers.
    /// pmap: each broker touches ONLY its own papers. Disjoint. Lock-free.
    fn step_tick(&mut self, post_idx: usize) -> (Vec<Resolution>, Vec<LogEntry>) {
        let price = self.posts[post_idx].current_price();

        // par_iter_mut: each broker is disjoint. collect() is the synchronization.
        let results: Vec<Vec<Resolution>> = self.posts[post_idx]
            .registry
            .par_iter_mut()
            .map(|broker| broker.tick_papers(price))
            .collect();

        // Sequential: flatten and produce logs
        let mut all_resolutions = Vec::new();
        let mut all_logs = Vec::new();
        for resolutions in results {
            for res in &resolutions {
                all_logs.push(LogEntry::PaperResolved {
                    broker_slot_idx: res.broker_slot_idx,
                    outcome: res.outcome,
                    optimal_distances: res.optimal_distances,
                });
            }
            all_resolutions.extend(resolutions);
        }

        (all_resolutions, all_logs)
    }

    /// Step 3b: PROPAGATE (paper resolutions).
    /// Three phases: compute update messages (parallel), group by recipient, apply (parallel per scope).
    fn step_propagate(
        &mut self,
        post_idx: usize,
        resolutions: Vec<Resolution>,
    ) -> Vec<LogEntry> {
        let recalib = 500; // default
        let post = &mut self.posts[post_idx];
        let m = post.exit_observers.len();

        // Phase 1: parallel — compute update messages as values.
        // Each broker produces PropagationFacts. No observer mutation.
        let facts_list: Vec<_> = resolutions
            .par_iter()
            .map(|res| {
                let _broker = &post.registry[res.broker_slot_idx];
                // Compute what the broker WOULD produce — but don't mutate yet.
                // We need the indices and the data for routing.
                let mi = res.broker_slot_idx / m;
                let ei = res.broker_slot_idx % m;
                (
                    res.broker_slot_idx,
                    mi,
                    ei,
                    res.composed_thought.clone(),
                    res.outcome,
                    res.amount,
                    res.direction,
                    res.optimal_distances,
                )
            })
            .collect();

        // Phase 2: group by recipient.
        // broker_updates[slot_idx] = Vec of (thought, outcome, weight, direction, optimal)
        // market_updates[mi] = Vec of (thought, direction, weight)
        // exit_updates[ei] = Vec of (composed, optimal, weight)
        let n_brokers = post.registry.len();
        let n_market = post.market_observers.len();
        let n_exit = post.exit_observers.len();

        let mut broker_updates: Vec<Vec<(&Vector, Outcome, f64, Direction, &Distances)>> =
            vec![Vec::new(); n_brokers];
        let mut market_updates: Vec<Vec<(&Vector, Direction, f64)>> =
            vec![Vec::new(); n_market];
        let mut exit_updates: Vec<Vec<(&Vector, Distances, f64)>> =
            vec![Vec::new(); n_exit];

        // Collect references grouped by recipient
        for (slot, mi, ei, ref thought, outcome, weight, direction, ref optimal) in &facts_list {
            broker_updates[*slot].push((thought, *outcome, *weight, *direction, optimal));
            market_updates[*mi].push((thought, *direction, *weight));
            exit_updates[*ei].push((thought, *optimal, *weight));
        }

        // Phase 3a: parallel — apply broker updates (each broker is its own scope)
        post.registry
            .par_iter_mut()
            .enumerate()
            .for_each(|(slot_idx, broker)| {
                for &(thought, outcome, weight, direction, optimal) in &broker_updates[slot_idx] {
                    broker.propagate(
                        thought,
                        outcome,
                        weight,
                        direction,
                        optimal,
                        recalib,
                        ctx_scalar_encoder_placeholder(),
                    );
                }
            });

        // Phase 3b: parallel — apply market observer updates
        post.market_observers
            .par_iter_mut()
            .enumerate()
            .for_each(|(mi, obs)| {
                for &(thought, direction, weight) in &market_updates[mi] {
                    obs.resolve(thought, direction, weight, recalib);
                }
            });

        // Phase 3c: parallel — apply exit observer updates
        post.exit_observers
            .par_iter_mut()
            .enumerate()
            .for_each(|(ei, obs)| {
                for &(thought, ref optimal, weight) in &exit_updates[ei] {
                    obs.observe_distances(thought, optimal, weight);
                }
            });

        // Logs
        facts_list
            .iter()
            .map(|(slot, _, _, _, _, _, _, _)| LogEntry::Propagated {
                broker_slot_idx: *slot,
                observers_updated: 2,
            })
            .collect()
    }

    /// Step 3c: UPDATE TRIGGERS.
    /// Query exit observers for fresh distances on active trades.
    fn step_update_triggers(
        &mut self,
        post_idx: usize,
        market_thoughts: &[Vector],
        ctx: &Ctx,
    ) -> Vec<(ThoughtAST, Vector)> {
        let trades: Vec<_> = self
            .treasury
            .trades_for_post(post_idx)
            .into_iter()
            .map(|(tid, t)| (tid, t.clone()))
            .collect();

        let trade_refs: Vec<_> = trades.iter().map(|(tid, t)| (*tid, t)).collect();

        let (level_updates, misses) =
            self.posts[post_idx].update_triggers(&trade_refs, market_thoughts, ctx);

        // Apply level updates to treasury
        for (tid, lvls) in level_updates {
            self.treasury.update_trade_stops(tid, lvls);
        }

        misses
    }

    /// Step 4: COLLECT + FUND.
    fn step_collect_fund(&mut self) -> Vec<LogEntry> {
        self.treasury.fund_proposals()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::raw_candle::Asset;

    #[test]
    fn test_enterprise_construct() {
        let mut balances = std::collections::HashMap::new();
        balances.insert("USDC".into(), 10000.0);
        let treasury = Treasury::new(Asset::new("USD"), balances, 0.001, 0.0025);
        let ent = Enterprise::new(Vec::new(), treasury);
        assert_eq!(ent.posts.len(), 0);
        assert_eq!(ent.market_thoughts_cache.len(), 0);
        assert_eq!(ent.treasury.total_equity(), 10000.0);
    }

    #[test]
    fn test_enterprise_cache_per_post() {
        let mut balances = std::collections::HashMap::new();
        balances.insert("USDC".into(), 10000.0);
        let treasury = Treasury::new(Asset::new("USD"), balances, 0.001, 0.0025);

        // Create two empty posts
        let posts = vec![
            Post::new(
                0,
                Asset::new("USDC"),
                Asset::new("WBTC"),
                crate::indicator_bank::IndicatorBank::new(),
                200,
                vec![],
                vec![],
                vec![],
            ),
            Post::new(
                1,
                Asset::new("USDC"),
                Asset::new("WETH"),
                crate::indicator_bank::IndicatorBank::new(),
                200,
                vec![],
                vec![],
                vec![],
            ),
        ];

        let ent = Enterprise::new(posts, treasury);
        assert_eq!(ent.market_thoughts_cache.len(), 2);
    }

    #[test]
    fn test_step_resolve_no_trades() {
        let mut balances = std::collections::HashMap::new();
        balances.insert("USDC".into(), 10000.0);
        let treasury = Treasury::new(Asset::new("USD"), balances, 0.001, 0.0025);
        let mut ent = Enterprise::new(Vec::new(), treasury);

        // No trades -> no settlements
        let logs = ent.step_resolve_and_propagate();
        assert!(logs.is_empty());
    }

    #[test]
    fn test_step_collect_fund_no_proposals() {
        let mut balances = std::collections::HashMap::new();
        balances.insert("USDC".into(), 10000.0);
        let treasury = Treasury::new(Asset::new("USD"), balances, 0.001, 0.0025);
        let mut ent = Enterprise::new(Vec::new(), treasury);

        let logs = ent.step_collect_fund();
        assert!(logs.is_empty());
    }
}
