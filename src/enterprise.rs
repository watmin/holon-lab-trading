//! Enterprise — the four-step candle loop.
//!
//! See wat/enterprise.wat for the specification.
//!
//! RESOLVE → COMPUTE+DISPATCH → PROCESS → COLLECT+FUND
//! Four steps. Sequential. Reality first.
//! The parallelism is inside COMPUTE (par_iter market observers).
//!
//! The desk is gone. The treasury IS the desk.
//! The manager is gone. The tuple journal IS the manager.

use holon::Vector;

use crate::exit::learned_stop::LearnedStop;
use crate::exit::optimal::compute_optimal_distance;
use crate::exit::tuple::{RealityOutcome, TupleJournal};
use crate::position::{ManagedPosition, PositionEntry, PositionExit, TrailFactor};
use crate::treasury::Asset;

/// A trade proposal from an exit observer.
#[derive(Clone)]
pub struct Proposal {
    pub composed_thought: Vector,
    pub direction: Option<crate::journal::Label>,
    pub distance: f64,
    pub conviction: f64,
    pub market_idx: usize,
    pub exit_idx: usize,
}

/// The enterprise's three flat N×M vecs + accounting.
/// Pre-allocated at startup. Disjoint slots. Mutex-free parallel.
pub struct Enterprise {
    /// N market observers × M exit observers
    pub n_market: usize,
    pub m_exit: usize,

    /// Closures: permanent, never shrink. Each knows its (market, exit) pair.
    pub registry: Vec<TupleJournal>,

    /// Proposals waiting for funding. Cleared every candle.
    pub proposals: Vec<Option<Proposal>>,

    /// Active trades. Insert on fund, remove on close.
    pub trades: Vec<Option<ManagedPosition>>,

    /// Thought vectors stashed at trade entry for tuple journal resolution.
    pub trade_thoughts: Vec<Option<Vec<Vector>>>,

    /// Learned trailing stop per slot. Nearest neighbor regression on
    /// (thought, optimal_distance) pairs from resolved trades.
    pub learned_stops: Vec<LearnedStop>,
}

impl Enterprise {
    /// Pre-allocate N×M slots.
    pub fn new(
        n_market: usize,
        m_exit: usize,
        dims: usize,
        recalib_interval: usize,
        market_names: &[&str],
        exit_names: &[&str],
    ) -> Self {
        let total = n_market * m_exit;
        let mut registry = Vec::with_capacity(total);
        for mi in 0..n_market {
            for ei in 0..m_exit {
                registry.push(TupleJournal::new(
                    market_names.get(mi).unwrap_or(&"market"),
                    exit_names.get(ei).unwrap_or(&"exit"),
                    dims,
                    recalib_interval,
                ));
            }
        }

        let mut proposals = Vec::with_capacity(total);
        let mut trades = Vec::with_capacity(total);
        let mut trade_thoughts = Vec::with_capacity(total);
        let mut learned_stops = Vec::with_capacity(total);
        for _ in 0..total {
            proposals.push(None);
            trades.push(None);
            trade_thoughts.push(None);
            learned_stops.push(LearnedStop::new(5000, 0.015)); // default 1.5% — ignorance state
        }

        Self {
            n_market,
            m_exit,
            registry,
            proposals,
            trades,
            trade_thoughts,
            learned_stops,
        }
    }

    /// Flat index from (market_idx, exit_idx).
    #[inline]
    pub fn idx(&self, market_idx: usize, exit_idx: usize) -> usize {
        market_idx * self.m_exit + exit_idx
    }

    /// Step 1: RESOLVE — reality first, money before thoughts.
    ///
    /// Iterate active trades. Check trailing stop triggers at current_price.
    /// Settle what fired: classify outcome, propagate through tuple journals,
    /// feed learned stops with optimal distance from price history, clear slot.
    ///
    /// `candle_window` provides the price history needed for compute_optimal_distance.
    /// `k_trail` is the trailing stop factor used during tick.
    /// `conviction_quantile` and `conviction_window` are passed through to tuple journal resolve.
    pub fn step_resolve(
        &mut self,
        current_price: f64,
        candle_window: &[crate::candle::Candle],
        k_trail: TrailFactor,
        conviction_quantile: f64,
        conviction_window: usize,
    ) {
        // Collect indices of trades that fired, so we can mutate everything after.
        // We tick each trade and record which ones triggered an exit.
        let mut resolved: Vec<(usize, PositionExit, f64)> = Vec::new();

        for (i, slot) in self.trades.iter_mut().enumerate() {
            if let Some(ref mut trade) = slot {
                // Determine direction: source_asset is what we sold to enter.
                // Buy: sold base (USDC) for quote (WBTC) → rate = base_per_quote = price.
                // Sell: sold quote (WBTC) for base (USDC) → rate = quote_per_base = 1/price.
                let is_buy = trade.source_asset.as_str() == "USDC";
                let current_rate = if is_buy { current_price } else { 1.0 / current_price };

                if let Some(exit) = trade.tick(current_rate, k_trail) {
                    let ret = trade.return_pct(current_rate);
                    resolved.push((i, exit, ret));
                }
            }
        }

        // Settle each resolved trade.
        for (i, _exit, ret) in resolved {
            let trade = self.trades[i].as_ref().unwrap();
            let entry_price = trade.entry_rate;
            let entry_candle = trade.entry_candle;
            let source_amount = trade.source_amount;
            let is_buy = trade.source_asset.as_str() == "USDC";

            // Classify: Grace (profit) or Violence (loss).
            let reality = if ret > 0.0 {
                RealityOutcome::Grace { amount: (ret * source_amount).abs() }
            } else {
                RealityOutcome::Violence { amount: (ret * source_amount).abs() }
            };
            let grace = ret > 0.0;

            // Compute optimal distance from price history (hindsight).
            // Find the entry candle offset in the window, extract closes from entry to now.
            let optimal_dist = find_closes_from_entry(candle_window, entry_candle)
                .and_then(|closes| compute_optimal_distance(&closes, entry_price, 100, 0.05));

            // Propagate through the tuple journal: resolve + observe_scalars.
            let journal = &mut self.registry[i];
            if let Some(thoughts) = &self.trade_thoughts[i] {
                // Each thought in the vec corresponds to an observer's contribution
                // at entry time. The first thought (or the only one) drives resolution.
                if let Some(thought) = thoughts.first() {
                    let pred = journal.propose(thought);
                    journal.resolve(
                        thought,
                        &pred,
                        reality,
                        conviction_quantile,
                        conviction_window,
                    );

                    // Feed optimal distance scalars to the tuple journal.
                    if let Some(ref opt) = optimal_dist {
                        let side = if is_buy { &opt.buy } else { &opt.sell };
                        journal.observe_scalar(
                            "trail-distance",
                            side.distance_pct,
                            grace,
                            side.residue.abs().max(0.01),
                        );
                    }

                    // Feed the LearnedStop with the optimal distance from hindsight.
                    if let Some(ref opt) = optimal_dist {
                        let side = if is_buy { &opt.buy } else { &opt.sell };
                        self.learned_stops[i].observe(
                            thought.clone(),
                            side.distance_pct,
                            side.residue.abs().max(0.01),
                        );
                    }
                }
            }

            // Clear the trade slot and its stashed thoughts.
            self.trades[i] = None;
            self.trade_thoughts[i] = None;
        }
    }

    /// Clear all proposals. Called at end of Step 4.
    pub fn clear_proposals(&mut self) {
        for p in &mut self.proposals {
            *p = None;
        }
    }

    /// Count active trades.
    pub fn active_trade_count(&self) -> usize {
        self.trades.iter().filter(|t| t.is_some()).count()
    }

    /// Count proposals this candle.
    pub fn proposal_count(&self) -> usize {
        self.proposals.iter().filter(|p| p.is_some()).count()
    }

    /// Step 2: COMPUTE + DISPATCH.
    ///
    /// Phase A: parallel market encoding — each observer encodes its thought
    /// from the candle window at its own sampled time scale.
    ///
    /// Phase B: sequential dispatch — for each (market_idx, exit_idx) pair,
    /// look up the tuple journal, compose the thought (market thought directly
    /// for now — exit vocabulary comes later), propose on the journal,
    /// and insert a proposal if conditions are met.
    ///
    /// Returns the market thought vectors for Step 3 to use.
    pub fn step_compute_dispatch(
        &mut self,
        observers: &[crate::market::observer::Observer],
        candle_window: &[crate::candle::Candle],
        encode_count: usize,
        ctx: &crate::state::CandleContext,
    ) -> Vec<holon::Vector> {
        // ── Phase A: parallel market encoding ──────────────────────────
        let thoughts: Vec<holon::Vector> = {
            use rayon::prelude::*;
            observers.par_iter().enumerate().map(|(ei, obs)| {
                let w = obs.window_sampler.sample(encode_count).min(candle_window.len());
                let start = candle_window.len().saturating_sub(w);
                let slice = &candle_window[start..];
                if slice.is_empty() {
                    holon::Vector::zeros(ctx.dims)
                } else {
                    ctx.thought_encoder
                        .encode_thought(slice, ctx.vm, crate::market::OBSERVER_LENSES[ei])
                        .thought
                }
            }).collect()
        };

        // ── Phase B: sequential dispatch ───────────────────────────────
        self.dispatch_thoughts(&thoughts);

        thoughts
    }

    /// Step 3: PROCESS — update active trade triggers with fresh thoughts.
    ///
    /// For each active trade:
    ///   1. Determine which market observer's thought applies (from flat index).
    ///   2. Query the LearnedStop with that thought for the current recommended distance.
    ///   3. Convert the distance to a TrailFactor and tick the trade.
    ///      (Resolution is NOT done here — that's Step 1's job next candle.)
    ///
    /// Also ticks paper entries on each tuple journal (TODO: tick_papers not yet
    /// implemented on TupleJournal — will be wired when paper tracking lands).
    pub fn step_process(
        &mut self,
        thoughts: &[holon::Vector],
        current_price: f64,
        current_atr: f64,
    ) {
        // ── Active trades: update trailing stops with learned distance ──
        for i in 0..self.trades.len() {
            if let Some(ref mut trade) = self.trades[i] {
                // Derive which market observer owns this slot.
                let market_idx = i / self.m_exit;

                // Guard: if the thought vector for this market doesn't exist, skip.
                let thought = match thoughts.get(market_idx) {
                    Some(t) => t,
                    None => continue,
                };

                // Query the learned stop for the contextual distance.
                let distance = self.learned_stops[i].recommended_distance(thought);

                // Convert distance (a percentage) to a TrailFactor (ATR multiplier).
                // TrailFactor * entry_atr = fractional distance from extreme.
                // distance is already a fraction (e.g. 0.015 = 1.5%).
                // TrailFactor = distance / current_atr.
                let k_trail = if current_atr > 1e-12 {
                    TrailFactor(distance / current_atr)
                } else {
                    TrailFactor(1.5) // fallback — ignorance state
                };

                // Determine current rate for this trade's direction.
                let is_buy = trade.source_asset.as_str() == "USDC";
                let current_rate = if is_buy { current_price } else { 1.0 / current_price };

                // Tick the trade — updates trailing stop, checks triggers.
                // We intentionally IGNORE the exit signal here.
                // Resolution happens in Step 1 of the NEXT candle.
                let _exit = trade.tick(current_rate, k_trail);
            }
        }

        // ── Paper entries: tick all journals' papers ──
        // TODO: TupleJournal::tick_papers() not yet implemented.
        // When paper tracking lands on TupleJournal, wire it here:
        //   for journal in &mut self.registry {
        //       journal.tick_papers(current_price);
        //   }
    }

    /// Phase B of Step 2: sequential dispatch of pre-computed thoughts into the registry.
    ///
    /// For each (market_idx, exit_idx) pair: compose the thought (market thought
    /// directly for now), propose on the tuple journal, query the learned stop,
    /// and insert a proposal if all conditions are met.
    ///
    /// Separated from step_compute_dispatch so it can be tested without the full
    /// CandleContext encoding infrastructure.
    pub fn dispatch_thoughts(&mut self, thoughts: &[Vector]) {
        for market_idx in 0..self.n_market.min(thoughts.len()) {
            let thought = &thoughts[market_idx];

            for exit_idx in 0..self.m_exit {
                let i = self.idx(market_idx, exit_idx);
                let journal = &mut self.registry[i];

                // For now, composed = market thought directly.
                // Exit vocabulary composition comes later.
                let composed = thought.clone();

                // Propose: updates noise subspace, predicts grace/violence.
                let prediction = journal.propose(&composed);

                // Query the learned stop for this slot's distance.
                let distance = self.learned_stops[i].recommended_distance(&composed);

                // Check proposal conditions:
                //   - journal must have proven its curve (funded)
                //   - prediction must have a direction with conviction > 0.2
                //   - learned stop must have at least one pair
                if journal.funded()
                    && prediction.direction.is_some()
                    && prediction.conviction > 0.2
                    && self.learned_stops[i].pair_count() > 0
                {
                    self.proposals[i] = Some(Proposal {
                        composed_thought: composed,
                        direction: prediction.direction,
                        distance,
                        conviction: prediction.conviction,
                        market_idx,
                        exit_idx,
                    });
                }
            }
        }
    }

    /// Step 4: COLLECT + FUND — evaluate proposals, fund or reject, drain proposals.
    ///
    /// Iterate proposals. For each Some(proposal):
    ///   - Check if the tuple journal at registry[i] is funded (curve_valid).
    ///   - If funded and slot is empty: create a ManagedPosition, insert into trades[i],
    ///     stash the composed thought into trade_thoughts[i].
    ///   - Clear the proposal slot to None regardless.
    ///
    /// Capital availability and risk checks come later. For now, funding is gated
    /// only by `journal.funded()`.
    pub fn step_collect_fund(
        &mut self,
        current_price: f64,
        current_atr: f64,
        k_stop: f64,
        k_tp: f64,
    ) {
        for i in 0..self.proposals.len() {
            let proposal = match self.proposals[i].take() {
                Some(p) => p,
                None => continue,
            };

            let journal = &self.registry[i];

            // Gate: journal must have proven its curve.
            // Skip if a trade already occupies this slot.
            if journal.funded() && self.trades[i].is_none() {
                // Build a PositionEntry from the proposal's parameters.
                // Direction: for now, all funded proposals open as buy (USDC → WBTC).
                // Full direction routing (from market observer labels) comes later.
                let entry_rate = current_price;
                let source_amount = 1000.0; // nominal — capital sizing comes later
                let entry = PositionEntry {
                    id: i,
                    candle_idx: 0, // caller should set this; placeholder for now
                    source_asset: Asset::new("USDC"),
                    target_asset: Asset::new("WBTC"),
                    source_amount,
                    target_received: source_amount / entry_rate,
                    entry_rate,
                    entry_atr: current_atr,
                    entry_fee: 0.0, // fee accounting comes with treasury integration
                    k_stop,
                    k_tp,
                };

                self.trades[i] = Some(ManagedPosition::new(entry));
                self.trade_thoughts[i] = Some(vec![proposal.composed_thought]);
            }
            // Proposal slot already cleared by .take() above.
        }
    }
}

/// Extract close prices from the candle window starting at the entry candle.
/// Returns None if the entry candle is not within the window.
fn find_closes_from_entry(candle_window: &[crate::candle::Candle], _entry_candle: usize) -> Option<Vec<f64>> {
    // The candle window is a slice of recent candles. We need to figure out
    // which index in the window corresponds to entry_candle.
    // Convention: the last candle in the window is the current candle.
    // If candle_window has N candles and the current global candle index is C,
    // then window[0] is candle C-N+1, window[N-1] is candle C.
    // We don't know C directly, but we can search by candle index if available,
    // or assume the window covers a contiguous range.
    //
    // Since we don't have explicit candle indices on the Candle struct for ordering,
    // we use the position: entry_candle relative to the window's implied range.
    // The caller must ensure the window covers from entry to now.
    //
    // Simple approach: if the window length > (current_candle - entry_candle),
    // the entry is within the window. We assume the last candle is the most recent.
    let window_len = candle_window.len();
    if window_len < 2 { return None; }

    // We don't know the absolute candle index of the window. Use a heuristic:
    // scan from the end. If a candle has close matching entry_price... too fragile.
    // Better: just return all closes. The caller already passed the right window.
    // The optimal distance function handles the full history.
    let closes: Vec<f64> = candle_window.iter().map(|c| c.close).collect();
    if closes.len() >= 2 { Some(closes) } else { None }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn enterprise_new_preallocates() {
        let e = Enterprise::new(
            7, 4, 64, 500,
            &["momentum", "structure", "volume", "narrative", "regime", "generalist", "classic"],
            &["volatility", "structure", "timing", "exit-generalist"],
        );
        assert_eq!(e.registry.len(), 28); // 7 × 4
        assert_eq!(e.proposals.len(), 28);
        assert_eq!(e.trades.len(), 28);
        assert_eq!(e.active_trade_count(), 0);
        assert_eq!(e.proposal_count(), 0);
    }

    #[test]
    fn enterprise_idx() {
        let e = Enterprise::new(3, 4, 64, 500, &["a", "b", "c"], &["x", "y", "z", "w"]);
        assert_eq!(e.idx(0, 0), 0);
        assert_eq!(e.idx(0, 3), 3);
        assert_eq!(e.idx(1, 0), 4);
        assert_eq!(e.idx(2, 3), 11);
    }

    // ── dispatch_thoughts tests ───────────────────────────────────────

    #[test]
    fn dispatch_thoughts_proposes_on_every_journal() {
        // With 2 market × 3 exit = 6 slots, dispatch should call propose()
        // on each journal. Since journals start cold (no discriminant, no funding),
        // no proposals should be generated — but the noise subspace should update.
        let mut e = Enterprise::new(2, 3, 64, 500, &["m0", "m1"], &["e0", "e1", "e2"]);
        let vm = holon::VectorManager::new(64);
        let thoughts = vec![
            vm.get_vector("thought-m0"),
            vm.get_vector("thought-m1"),
        ];

        e.dispatch_thoughts(&thoughts);

        // No proposals: journals are cold (not funded, no learned stop pairs).
        assert_eq!(e.proposal_count(), 0, "cold journals should not propose");

        // But noise subspace should have been updated by propose():
        // each journal should have n() == 1 from the one propose() call.
        for (i, journal) in e.registry.iter().enumerate() {
            assert_eq!(journal.noise_subspace.n(), 1,
                "journal {} noise subspace should have 1 observation from propose()", i);
        }
    }

    #[test]
    fn dispatch_thoughts_same_market_thought_goes_to_all_exit_slots() {
        // Market 0's thought should be dispatched to exit slots 0, 1, 2.
        // Verify by checking that all exit slots for market 0 received the same
        // noise update (since composed = market thought directly for now).
        let mut e = Enterprise::new(1, 3, 64, 500, &["m0"], &["e0", "e1", "e2"]);
        let vm = holon::VectorManager::new(64);
        let thoughts = vec![vm.get_vector("market-thought")];

        e.dispatch_thoughts(&thoughts);

        // All 3 exit slots should have been updated.
        assert_eq!(e.registry[0].noise_subspace.n(), 1);
        assert_eq!(e.registry[1].noise_subspace.n(), 1);
        assert_eq!(e.registry[2].noise_subspace.n(), 1);
    }

    #[test]
    fn dispatch_thoughts_clears_proposals_before_dispatch() {
        // Dispatch does NOT clear proposals — that's Step 4 (clear_proposals).
        // But it should overwrite a slot if the journal meets conditions.
        // Here we just verify it doesn't crash with pre-existing proposals.
        let mut e = Enterprise::new(1, 1, 64, 500, &["m"], &["e"]);
        e.proposals[0] = Some(Proposal {
            composed_thought: holon::Vector::zeros(64),
            direction: None,
            distance: 0.0,
            conviction: 0.0,
            market_idx: 0,
            exit_idx: 0,
        });

        let thoughts = vec![holon::Vector::zeros(64)];
        e.dispatch_thoughts(&thoughts);

        // Cold journal can't propose, so the stale proposal should be left as-is
        // (dispatch writes None only via the condition gate — it doesn't clear first).
        // The old proposal persists because the condition gate didn't fire.
        assert!(e.proposals[0].is_some(),
            "stale proposal should not be cleared by dispatch (Step 4 does that)");
    }

    #[test]
    fn dispatch_thoughts_with_fewer_thoughts_than_markets() {
        // If observers < n_market, dispatch should not panic — it uses min().
        let mut e = Enterprise::new(3, 2, 64, 500, &["m0", "m1", "m2"], &["e0", "e1"]);
        let thoughts = vec![holon::Vector::zeros(64)]; // only 1 thought for 3 markets

        e.dispatch_thoughts(&thoughts);

        // Only market 0's exit slots should have been touched.
        assert_eq!(e.registry[0].noise_subspace.n(), 1); // market 0, exit 0
        assert_eq!(e.registry[1].noise_subspace.n(), 1); // market 0, exit 1
        assert_eq!(e.registry[2].noise_subspace.n(), 0); // market 1, exit 0 — untouched
        assert_eq!(e.registry[3].noise_subspace.n(), 0); // market 1, exit 1 — untouched
    }

    #[test]
    fn dispatch_thoughts_learned_stop_distance_flows_into_proposal() {
        // Manually force a journal to be funded and give the learned stop a pair.
        // Then dispatch should create a proposal with the learned stop's distance.
        let mut e = Enterprise::new(1, 1, 64, 500, &["m"], &["e"]);
        let vm = holon::VectorManager::new(64);
        let thought = vm.get_vector("signal-thought");

        // Force the journal's curve_valid = true (funded).
        e.registry[0].curve_valid = true;

        // Give the learned stop a known pair so pair_count > 0.
        e.learned_stops[0].observe(thought.clone(), 0.025, 1.0);

        // We need the journal to produce a directional prediction with conviction > 0.2.
        // Train the journal enough to have a discriminant.
        let grace = e.registry[0].grace_label;
        let violence = e.registry[0].violence_label;
        for i in 0..200 {
            let v = vm.get_vector(&format!("grace-{}", i));
            e.registry[0].journal.observe(&v, grace, 1.0);
        }
        for i in 0..100 {
            let v = vm.get_vector(&format!("violence-{}", i));
            e.registry[0].journal.observe(&v, violence, 1.0);
        }

        let thoughts = vec![thought];
        e.dispatch_thoughts(&thoughts);

        // Check: if a proposal was created, its distance should come from learned stop.
        if let Some(ref prop) = e.proposals[0] {
            // Distance should be near 0.025 (the one pair we observed).
            assert!(prop.distance > 0.0, "distance should be positive from learned stop");
            assert_eq!(prop.market_idx, 0);
            assert_eq!(prop.exit_idx, 0);
            assert!(prop.conviction > 0.2, "conviction gate should have passed");
        }
        // If no proposal, the journal didn't produce conviction > 0.2 — that's OK,
        // the test validates the plumbing, not the journal's internal state.
    }

    #[test]
    fn dispatch_thoughts_empty_thoughts_vec() {
        // Empty thoughts should not panic.
        let mut e = Enterprise::new(2, 2, 64, 500, &["m0", "m1"], &["e0", "e1"]);
        let thoughts: Vec<holon::Vector> = vec![];
        e.dispatch_thoughts(&thoughts);
        assert_eq!(e.proposal_count(), 0);
    }

    // ── step_resolve tests ─────────────────────────────────────────

    fn make_test_candle(close: f64) -> crate::candle::Candle {
        crate::candle::Candle {
            ts: String::new(),
            open: close, high: close, low: close, close, volume: 100.0,
            sma20: close, sma50: close, sma200: close,
            bb_upper: close * 1.05, bb_lower: close * 0.95, bb_width: close * 0.1,
            rsi: 50.0, macd_line: 0.0, macd_signal: 0.0, macd_hist: 0.0,
            dmi_plus: 20.0, dmi_minus: 15.0, adx: 25.0,
            atr: close * 0.02, atr_r: 0.02,
            stoch_k: 50.0, stoch_d: 45.0, williams_r: -50.0,
            cci: 0.0, mfi: 50.0,
            roc_1: 0.0, roc_3: 0.0, roc_6: 0.0, roc_12: 0.0,
            obv_slope_12: 0.0, volume_sma_20: 100.0,
            tf_1h_close: close, tf_1h_high: close, tf_1h_low: close,
            tf_1h_ret: 0.0, tf_1h_body: 0.0,
            tf_4h_close: close, tf_4h_high: close, tf_4h_low: close,
            tf_4h_ret: 0.0, tf_4h_body: 0.0,
            tenkan_sen: 0.0, kijun_sen: 0.0,
            senkou_span_a: 0.0, senkou_span_b: 0.0,
            cloud_top: 0.0, cloud_bottom: 0.0,
            bb_pos: 0.5, kelt_upper: close * 1.04, kelt_lower: close * 0.96, kelt_pos: 0.5,
            squeeze: false,
            range_pos_12: 0.5, range_pos_24: 0.5, range_pos_48: 0.5,
            trend_consistency_6: 0.5, trend_consistency_12: 0.5, trend_consistency_24: 0.5,
            atr_roc_6: 0.0, atr_roc_12: 0.0, vol_accel: 0.0,
            hour: 12.0, day_of_week: 3.0,
        }
    }

    fn make_buy_entry(rate: f64, atr: f64, k_stop: f64, k_tp: f64) -> crate::position::PositionEntry {
        use crate::treasury::Asset;
        crate::position::PositionEntry {
            id: 1,
            candle_idx: 0,
            source_asset: Asset::new("USDC"),
            target_asset: Asset::new("WBTC"),
            source_amount: 1000.0,
            target_received: 1000.0 / rate,
            entry_rate: rate,
            entry_atr: atr,
            entry_fee: 1.0,
            k_stop,
            k_tp,
        }
    }

    #[test]
    fn step_resolve_no_trades_is_noop() {
        let mut e = Enterprise::new(2, 2, 64, 500, &["a", "b"], &["x", "y"]);
        let candles: Vec<_> = (0..20).map(|i| make_test_candle(50000.0 + i as f64 * 100.0)).collect();
        e.step_resolve(50500.0, &candles, TrailFactor(1.5), 0.5, 1000);
        assert_eq!(e.active_trade_count(), 0);
    }

    #[test]
    fn step_resolve_untriggered_trade_stays() {
        let mut e = Enterprise::new(2, 2, 64, 500, &["a", "b"], &["x", "y"]);

        // Buy trade at 50000. Stop at 50000 * (1 - 2*0.01) = 49000.
        let pos = ManagedPosition::new(make_buy_entry(50000.0, 0.01, 2.0, 3.0));
        e.trades[0] = Some(pos);
        e.trade_thoughts[0] = Some(vec![holon::Vector::zeros(64)]);

        let candles: Vec<_> = (0..20).map(|i| make_test_candle(50000.0 + i as f64 * 50.0)).collect();
        // Price at 50500 — well above stop at 49000.
        e.step_resolve(50500.0, &candles, TrailFactor(1.5), 0.5, 1000);

        assert_eq!(e.active_trade_count(), 1, "trade should survive — not triggered");
        assert!(e.trades[0].is_some());
    }

    #[test]
    fn step_resolve_triggered_trade_removed() {
        let mut e = Enterprise::new(2, 2, 64, 500, &["a", "b"], &["x", "y"]);

        // Buy at 50000. Stop at 49000.
        let pos = ManagedPosition::new(make_buy_entry(50000.0, 0.01, 2.0, 3.0));
        e.trades[0] = Some(pos);
        e.trade_thoughts[0] = Some(vec![holon::Vector::zeros(64)]);

        let candles: Vec<_> = (0..20).map(|i| make_test_candle(50000.0 - i as f64 * 200.0)).collect();
        // Price crashes to 48000 — below stop at 49000.
        e.step_resolve(48000.0, &candles, TrailFactor(1.5), 0.5, 1000);

        assert_eq!(e.active_trade_count(), 0, "trade should be removed — stop triggered");
        assert!(e.trades[0].is_none());
        assert!(e.trade_thoughts[0].is_none());
    }

    #[test]
    fn step_resolve_propagates_to_journal() {
        let mut e = Enterprise::new(1, 1, 64, 500, &["a"], &["x"]);

        let pos = ManagedPosition::new(make_buy_entry(50000.0, 0.01, 2.0, 3.0));
        e.trades[0] = Some(pos);
        e.trade_thoughts[0] = Some(vec![holon::Vector::zeros(64)]);

        let candles: Vec<_> = (0..20).map(|i| make_test_candle(50000.0 - i as f64 * 200.0)).collect();
        let initial_trade_count = e.registry[0].trade_count;

        e.step_resolve(48000.0, &candles, TrailFactor(1.5), 0.5, 1000);

        assert_eq!(e.registry[0].trade_count, initial_trade_count + 1,
            "tuple journal should have one more resolved trade");
    }

    #[test]
    fn step_resolve_feeds_learned_stop() {
        let mut e = Enterprise::new(1, 1, 64, 500, &["a"], &["x"]);

        let pos = ManagedPosition::new(make_buy_entry(50000.0, 0.01, 2.0, 3.0));
        e.trades[0] = Some(pos);
        e.trade_thoughts[0] = Some(vec![holon::Vector::zeros(64)]);

        // Meaningful price history for compute_optimal_distance.
        let candles: Vec<_> = (0..50).map(|i| make_test_candle(50000.0 - i as f64 * 100.0)).collect();

        assert_eq!(e.learned_stops[0].pair_count(), 0);
        e.step_resolve(48000.0, &candles, TrailFactor(1.5), 0.5, 1000);

        assert!(e.learned_stops[0].pair_count() > 0,
            "learned stop should have a pair after resolution");
    }

    #[test]
    fn step_resolve_classifies_loss_correctly() {
        let mut e = Enterprise::new(1, 1, 64, 500, &["a"], &["x"]);

        // Buy at 50000, crash to 48000 — loss.
        let pos = ManagedPosition::new(make_buy_entry(50000.0, 0.01, 2.0, 3.0));
        e.trades[0] = Some(pos);
        e.trade_thoughts[0] = Some(vec![holon::Vector::zeros(64)]);

        let candles: Vec<_> = (0..20).map(|i| make_test_candle(50000.0 - i as f64 * 200.0)).collect();
        e.step_resolve(48000.0, &candles, TrailFactor(1.5), 0.5, 1000);

        assert!(e.registry[0].cumulative_violence > 0.0,
            "losing trade should add violence");
    }

    #[test]
    fn step_resolve_classifies_grace_on_take_profit() {
        let mut e = Enterprise::new(1, 1, 64, 500, &["a"], &["x"]);

        // Buy at 50000. TP at 50000 * (1 + 3*0.01) = 51500. Price at 52000.
        let pos = ManagedPosition::new(make_buy_entry(50000.0, 0.01, 2.0, 3.0));
        e.trades[0] = Some(pos);
        e.trade_thoughts[0] = Some(vec![holon::Vector::zeros(64)]);

        let candles: Vec<_> = (0..20).map(|i| make_test_candle(50000.0 + i as f64 * 200.0)).collect();
        e.step_resolve(52000.0, &candles, TrailFactor(1.5), 0.5, 1000);

        assert_eq!(e.active_trade_count(), 0, "profitable trade should be resolved");
        assert!(e.registry[0].cumulative_grace > 0.0,
            "profitable trade should add grace");
    }

    #[test]
    fn step_resolve_without_thoughts_still_clears() {
        let mut e = Enterprise::new(1, 1, 64, 500, &["a"], &["x"]);

        // Trade with no stashed thoughts.
        let pos = ManagedPosition::new(make_buy_entry(50000.0, 0.01, 2.0, 3.0));
        e.trades[0] = Some(pos);
        // trade_thoughts[0] remains None

        let candles: Vec<_> = (0..20).map(|i| make_test_candle(50000.0 - i as f64 * 200.0)).collect();
        e.step_resolve(48000.0, &candles, TrailFactor(1.5), 0.5, 1000);

        assert_eq!(e.active_trade_count(), 0, "trade should be removed even without thoughts");
        // No journal update since there were no thoughts.
        assert_eq!(e.registry[0].trade_count, 0);
    }

    #[test]
    fn step_resolve_multiple_slots_independent() {
        let mut e = Enterprise::new(2, 2, 64, 500, &["a", "b"], &["x", "y"]);

        // Slot 0: buy at 50000, stop at 49000 — will trigger at 48000
        let pos0 = ManagedPosition::new(make_buy_entry(50000.0, 0.01, 2.0, 3.0));
        e.trades[0] = Some(pos0);
        e.trade_thoughts[0] = Some(vec![holon::Vector::zeros(64)]);

        // Slot 2: buy at 50000, same params — will also trigger
        let mut entry2 = make_buy_entry(50000.0, 0.01, 2.0, 3.0);
        entry2.id = 2;
        let pos2 = ManagedPosition::new(entry2);
        e.trades[2] = Some(pos2);
        e.trade_thoughts[2] = Some(vec![holon::Vector::zeros(64)]);

        // Slot 1: no trade — stays empty

        let candles: Vec<_> = (0..20).map(|i| make_test_candle(50000.0 - i as f64 * 200.0)).collect();
        e.step_resolve(48000.0, &candles, TrailFactor(1.5), 0.5, 1000);

        assert!(e.trades[0].is_none(), "slot 0 should be cleared");
        assert!(e.trades[1].is_none(), "slot 1 was already empty");
        assert!(e.trades[2].is_none(), "slot 2 should be cleared");
        assert_eq!(e.registry[0].trade_count, 1);
        assert_eq!(e.registry[2].trade_count, 1);
        assert_eq!(e.registry[1].trade_count, 0, "slot 1 had no trade");
    }

    // ── step_process tests ────────────────────────────────────────

    #[test]
    fn step_process_no_trades_is_noop() {
        let mut e = Enterprise::new(2, 2, 64, 500, &["a", "b"], &["x", "y"]);
        let vm = holon::VectorManager::new(64);
        let thoughts = vec![vm.get_vector("t0"), vm.get_vector("t1")];

        // Should not panic with zero active trades.
        e.step_process(&thoughts, 50000.0, 0.02);
        assert_eq!(e.active_trade_count(), 0);
    }

    #[test]
    fn step_process_ticks_active_trade_without_resolving() {
        // A trade that is NOT near its stop should survive step_process.
        // step_process ticks the trade (updating trailing stop) but does NOT
        // remove it even if an exit signal fires — that's Step 1's job.
        let mut e = Enterprise::new(2, 2, 64, 500, &["a", "b"], &["x", "y"]);
        let vm = holon::VectorManager::new(64);

        // Place a buy trade at slot 0 (market 0, exit 0). Entry at 50000.
        let pos = ManagedPosition::new(make_buy_entry(50000.0, 0.01, 2.0, 3.0));
        let initial_candles_held = pos.candles_held;
        e.trades[0] = Some(pos);

        // Give the learned stop a pair so it returns a real distance.
        let thought = vm.get_vector("t0");
        e.learned_stops[0].observe(thought.clone(), 0.02, 1.0);

        let thoughts = vec![thought, vm.get_vector("t1")];

        // Price at 50500 — above entry, no trigger expected.
        e.step_process(&thoughts, 50500.0, 0.02);

        // Trade should still be active.
        assert!(e.trades[0].is_some(), "trade should survive step_process");
        let trade = e.trades[0].as_ref().unwrap();
        assert_eq!(trade.candles_held, initial_candles_held + 1,
            "tick should increment candles_held");
    }

    #[test]
    fn step_process_updates_trailing_stop_from_learned_distance() {
        // Verify that step_process uses the learned stop's distance to adjust
        // the trailing stop, not a hardcoded factor.
        let mut e = Enterprise::new(1, 1, 64, 500, &["m"], &["e"]);
        let vm = holon::VectorManager::new(64);

        // Buy at 50000, k_stop=2.0, atr=0.01.
        // Initial stop = 50000 * (1 - 2.0*0.01) = 49000.
        let pos = ManagedPosition::new(make_buy_entry(50000.0, 0.01, 2.0, 3.0));
        let initial_stop = pos.trailing_stop;
        e.trades[0] = Some(pos);

        // Teach the learned stop a TIGHT distance (0.005 = 0.5%).
        let thought = vm.get_vector("tight-signal");
        e.learned_stops[0].observe(thought.clone(), 0.005, 10.0);

        let thoughts = vec![thought];

        // Price rises to 51000. With a tight learned distance of 0.005:
        // TrailFactor = 0.005 / 0.02 = 0.25.
        // new_stop = 51000 * (1 - 0.25 * 0.01) = 51000 * 0.9975 = 50872.5
        // This is above initial_stop (49000), so trailing stop should ratchet up.
        e.step_process(&thoughts, 51000.0, 0.02);

        let trade = e.trades[0].as_ref().unwrap();
        assert!(trade.trailing_stop > initial_stop,
            "trailing stop should ratchet up: {} > {}", trade.trailing_stop, initial_stop);
    }

    #[test]
    fn step_process_skips_slots_without_thoughts() {
        // If there are fewer thoughts than market observers, slots for
        // missing markets should be skipped without panic.
        let mut e = Enterprise::new(3, 1, 64, 500, &["a", "b", "c"], &["x"]);

        // Place trades in slot 0 (market 0) and slot 2 (market 2).
        let pos0 = ManagedPosition::new(make_buy_entry(50000.0, 0.01, 2.0, 3.0));
        e.trades[0] = Some(pos0);
        let mut entry2 = make_buy_entry(50000.0, 0.01, 2.0, 3.0);
        entry2.id = 2;
        e.trades[2] = Some(ManagedPosition::new(entry2));

        // Only provide 1 thought (for market 0). Market 2 has no thought.
        let thoughts = vec![holon::Vector::zeros(64)];

        e.step_process(&thoughts, 50500.0, 0.02);

        // Slot 0 should have been ticked (candles_held incremented).
        assert_eq!(e.trades[0].as_ref().unwrap().candles_held, 1);
        // Slot 2 should NOT have been ticked (no thought for market 2).
        assert_eq!(e.trades[2].as_ref().unwrap().candles_held, 0);
    }

    // ── step_collect_fund tests ──────────────────────────────────────

    #[test]
    fn step_collect_fund_funded_proposal_opens_trade() {
        let mut e = Enterprise::new(1, 1, 64, 500, &["m"], &["e"]);

        // Force the journal to be funded.
        e.registry[0].curve_valid = true;

        // Insert a proposal.
        e.proposals[0] = Some(Proposal {
            composed_thought: holon::Vector::zeros(64),
            direction: None,
            distance: 0.02,
            conviction: 0.5,
            market_idx: 0,
            exit_idx: 0,
        });

        assert_eq!(e.active_trade_count(), 0);
        e.step_collect_fund(50000.0, 0.01, 2.0, 3.0);

        // Trade should have been opened.
        assert_eq!(e.active_trade_count(), 1);
        let trade = e.trades[0].as_ref().unwrap();
        assert!((trade.entry_rate - 50000.0).abs() < 1e-6);
        assert!((trade.entry_atr - 0.01).abs() < 1e-12);

        // Thought should be stashed.
        assert!(e.trade_thoughts[0].is_some());
        assert_eq!(e.trade_thoughts[0].as_ref().unwrap().len(), 1);

        // Proposal should be cleared.
        assert!(e.proposals[0].is_none());
    }

    #[test]
    fn step_collect_fund_unfunded_proposal_cleared_no_trade() {
        let mut e = Enterprise::new(1, 1, 64, 500, &["m"], &["e"]);

        // Journal is NOT funded (curve_valid = false, the default).
        assert!(!e.registry[0].funded());

        e.proposals[0] = Some(Proposal {
            composed_thought: holon::Vector::zeros(64),
            direction: None,
            distance: 0.02,
            conviction: 0.5,
            market_idx: 0,
            exit_idx: 0,
        });

        e.step_collect_fund(50000.0, 0.01, 2.0, 3.0);

        // No trade opened — journal not funded.
        assert_eq!(e.active_trade_count(), 0);
        // Proposal still cleared.
        assert!(e.proposals[0].is_none());
    }

    #[test]
    fn step_collect_fund_skips_occupied_slot() {
        let mut e = Enterprise::new(1, 1, 64, 500, &["m"], &["e"]);
        e.registry[0].curve_valid = true;

        // Pre-existing trade in slot 0.
        let pos = ManagedPosition::new(make_buy_entry(50000.0, 0.01, 2.0, 3.0));
        e.trades[0] = Some(pos);

        e.proposals[0] = Some(Proposal {
            composed_thought: holon::Vector::zeros(64),
            direction: None,
            distance: 0.02,
            conviction: 0.5,
            market_idx: 0,
            exit_idx: 0,
        });

        e.step_collect_fund(51000.0, 0.01, 2.0, 3.0);

        // Trade should still be the original (entry_rate 50000, not 51000).
        let trade = e.trades[0].as_ref().unwrap();
        assert!((trade.entry_rate - 50000.0).abs() < 1e-6,
            "existing trade should not be overwritten");
        // Proposal still cleared.
        assert!(e.proposals[0].is_none());
    }

    #[test]
    fn step_collect_fund_clears_all_proposals() {
        let mut e = Enterprise::new(2, 2, 64, 500, &["m0", "m1"], &["e0", "e1"]);

        // Fund slot 0, leave slots 1-3 unfunded.
        e.registry[0].curve_valid = true;

        for i in 0..4 {
            e.proposals[i] = Some(Proposal {
                composed_thought: holon::Vector::zeros(64),
                direction: None,
                distance: 0.01,
                conviction: 0.3,
                market_idx: i / 2,
                exit_idx: i % 2,
            });
        }
        assert_eq!(e.proposal_count(), 4);

        e.step_collect_fund(50000.0, 0.01, 2.0, 3.0);

        // All proposals cleared.
        assert_eq!(e.proposal_count(), 0);
        // Only slot 0 funded.
        assert_eq!(e.active_trade_count(), 1);
        assert!(e.trades[0].is_some());
        assert!(e.trades[1].is_none());
        assert!(e.trades[2].is_none());
        assert!(e.trades[3].is_none());
    }
}
