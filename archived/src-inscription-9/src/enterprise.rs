/// Enterprise — coordination plane. Three fields, four-step loop.

use std::collections::HashMap;

use holon::kernel::vector::Vector;

use crate::broker::Resolution;
use crate::ctx::Ctx;
use crate::enums::{Direction, ThoughtAST};
use crate::log_entry::LogEntry;
use crate::post::Post;
use crate::raw_candle::RawCandle;
use crate::simulation::compute_optimal_distances;
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

    /// Step 1: RESOLVE + PROPAGATE.
    /// Settlement and propagation use pre-existing vectors. No encoding.
    fn step_resolve_and_propagate(&mut self) -> Vec<LogEntry> {
        // Collect current prices from each post
        let mut current_prices: HashMap<(String, String), f64> = HashMap::new();
        for p in &self.posts {
            current_prices.insert(
                (p.source_asset.name.clone(), p.target_asset.name.clone()),
                p.current_price(),
            );
        }

        // Settle triggered trades
        let (settlements, mut settle_logs) = self.treasury.settle_triggered(&current_prices);

        // For each settlement, compute direction + optimal and propagate
        for stl in settlements {
            let t = &stl.trade;
            let post_idx = t.post_idx;
            let slot = t.broker_slot_idx;
            let thought = &stl.composed_thought;
            let outcome = &stl.outcome;
            let weight = stl.amount;

            // Derive direction from price movement
            let direction = if stl.exit_price > t.entry_rate {
                Direction::Up
            } else {
                Direction::Down
            };

            // Compute optimal distances from trade's price history
            let optimal = compute_optimal_distances(&t.price_history, &direction);

            // Propagate to the post
            if post_idx < self.posts.len() {
                let prop_logs = self.posts[post_idx].propagate(
                    slot, thought, outcome, weight, &direction, &optimal,
                );
                settle_logs.extend(prop_logs);
            }
        }

        settle_logs
    }

    /// Step 2: COMPUTE + DISPATCH.
    fn step_compute_dispatch(
        &mut self,
        post_idx: usize,
        rc: &RawCandle,
        ctx: &Ctx,
    ) -> (Vec<crate::proposal::Proposal>, Vec<Vector>, Vec<(ThoughtAST, Vector)>) {
        let (proposals, market_thoughts, misses) = self.posts[post_idx].on_candle(rc, ctx);

        // Cache market thoughts
        if post_idx < self.market_thoughts_cache.len() {
            self.market_thoughts_cache[post_idx] = market_thoughts.clone();
        }

        (proposals, market_thoughts, misses)
    }

    /// Step 3a: TICK — parallel tick of all brokers' papers.
    fn step_tick(&mut self, post_idx: usize) -> (Vec<Resolution>, Vec<LogEntry>) {
        let price = self.posts[post_idx].current_price();
        let mut all_resolutions = Vec::new();
        let mut all_logs = Vec::new();

        for broker in &mut self.posts[post_idx].registry {
            let (resolutions, logs) = broker.tick_papers(price);
            all_resolutions.extend(resolutions);
            all_logs.extend(logs);
        }

        (all_resolutions, all_logs)
    }

    /// Step 3b: PROPAGATE (paper resolutions).
    fn step_propagate(
        &mut self,
        post_idx: usize,
        resolutions: Vec<Resolution>,
    ) -> Vec<LogEntry> {
        let mut all_logs = Vec::new();

        for res in resolutions {
            let logs = self.posts[post_idx].propagate(
                res.broker_slot_idx,
                &res.composed_thought,
                &res.outcome,
                res.amount,
                &res.direction,
                &res.optimal_distances,
            );
            all_logs.extend(logs);
        }

        all_logs
    }

    /// Step 3c: UPDATE TRIGGERS.
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
                p.source_asset.name == rc.source_asset.name
                    && p.target_asset.name == rc.target_asset.name
            })
            .unwrap_or(0);

        // Step 1: RESOLVE + PROPAGATE
        let mut all_logs = self.step_resolve_and_propagate();

        // Step 2: COMPUTE + DISPATCH
        let (proposals, market_thoughts, mut all_misses) =
            self.step_compute_dispatch(post_idx, rc, ctx);

        // Submit proposals to treasury
        for prop in proposals {
            self.treasury.submit_proposal(prop);
        }

        // Step 3a: TICK
        let (resolutions, tick_logs) = self.step_tick(post_idx);
        all_logs.extend(tick_logs);

        // Step 3b: PROPAGATE (sequential)
        let prop_logs = self.step_propagate(post_idx, resolutions);
        all_logs.extend(prop_logs);

        // Step 3c: UPDATE TRIGGERS
        let trigger_misses = self.step_update_triggers(post_idx, &market_thoughts, ctx);
        all_misses.extend(trigger_misses);

        // Step 4: COLLECT + FUND
        let fund_logs = self.step_collect_fund();
        all_logs.extend(fund_logs);

        // Clear market-thoughts-cache for this post
        if post_idx < self.market_thoughts_cache.len() {
            self.market_thoughts_cache[post_idx].clear();
        }

        (all_logs, all_misses)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::raw_candle::Asset;

    #[test]
    fn test_enterprise_construct() {
        let mut balances = std::collections::HashMap::new();
        balances.insert("BTC".into(), 10.0);
        let treasury = Treasury::new(Asset::new("BTC"), balances, 0.001, 0.0025);
        let ent = Enterprise::new(Vec::new(), treasury);
        assert_eq!(ent.posts.len(), 0);
        assert_eq!(ent.market_thoughts_cache.len(), 0);
        assert_eq!(ent.treasury.total_equity(), 10.0);
    }
}
