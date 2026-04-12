/// Enterprise — the coordination plane. Compiled from wat/enterprise.wat.
///
/// Three fields: posts, treasury, market_thoughts_cache.
/// The binary reimplements the four-step loop through pipes.
/// This struct holds the shared state that pipes read/write.

use holon::kernel::vector::Vector;

use crate::post::Post;
use crate::treasury::Treasury;

#[cfg(test)]
use std::collections::HashMap;
#[cfg(test)]
use crate::enums::Direction;
#[cfg(test)]
use crate::log_entry::LogEntry;
#[cfg(test)]
use crate::newtypes::Price;
#[cfg(test)]
use crate::simulation::compute_optimal_distances;

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
    /// Settle triggered trades, propagate outcomes to observers.
    /// (Test-only — the binary reimplements via pipes.)
    #[cfg(test)]
    fn step_resolve_and_propagate(&mut self) -> Vec<LogEntry> {
        // Collect current prices from each post
        let mut current_prices: HashMap<(String, String), Price> = HashMap::new();
        for p in &self.posts {
            current_prices.insert(
                (p.source_asset.name.clone(), p.target_asset.name.clone()),
                p.last_close(),
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
            let direction = if stl.exit_price.0 > t.entry_price.0 {
                Direction::Up
            } else {
                Direction::Down
            };

            // Compute optimal distances from trade's price history
            let optimal = compute_optimal_distances(&t.price_history, direction, 0.0035);

            // Propagate to the post
            if post_idx < self.posts.len() {
                let recalib = 500; // default recalib interval
                let prop_logs = self.posts[post_idx].propagate(
                    slot,
                    &stl.composed_thought,
                    &stl.market_thought,
                    &stl.exit_thought,
                    stl.outcome,
                    stl.amount.0,
                    direction,
                    &optimal,
                    recalib,
                );
                settle_logs.extend(prop_logs);
            }
        }

        settle_logs
    }

    /// Step 4: COLLECT + FUND.
    /// (Test-only — the binary reimplements via pipes.)
    #[cfg(test)]
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
        balances.insert("USDC".into(), crate::newtypes::Amount(10000.0));
        let treasury = Treasury::new(Asset::new("USD"), balances, 0.001, 0.0025);
        let ent = Enterprise::new(Vec::new(), treasury);
        assert_eq!(ent.posts.len(), 0);
        assert_eq!(ent.market_thoughts_cache.len(), 0);
        assert_eq!(ent.treasury.total_equity(), 10000.0);
    }

    #[test]
    fn test_enterprise_cache_per_post() {
        let mut balances = std::collections::HashMap::new();
        balances.insert("USDC".into(), crate::newtypes::Amount(10000.0));
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
        balances.insert("USDC".into(), crate::newtypes::Amount(10000.0));
        let treasury = Treasury::new(Asset::new("USD"), balances, 0.001, 0.0025);
        let mut ent = Enterprise::new(Vec::new(), treasury);

        // No trades -> no settlements
        let logs = ent.step_resolve_and_propagate();
        assert!(logs.is_empty());
    }

    #[test]
    fn test_step_collect_fund_no_proposals() {
        let mut balances = std::collections::HashMap::new();
        balances.insert("USDC".into(), crate::newtypes::Amount(10000.0));
        let treasury = Treasury::new(Asset::new("USD"), balances, 0.001, 0.0025);
        let mut ent = Enterprise::new(Vec::new(), treasury);

        let logs = ent.step_collect_fund();
        assert!(logs.is_empty());
    }
}
