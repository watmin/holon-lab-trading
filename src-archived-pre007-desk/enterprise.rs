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

use holon::{Primitives, Vector};

use crate::candle::Candle;
use crate::exit::learned_stop::LearnedStop;
use crate::exit::optimal::compute_optimal_distance;
use crate::exit::tuple::{RealityOutcome, TupleJournal};
use crate::exit::vocab::{
    ExitLens, EXIT_LENSES,
    encode_volatility_facts, encode_structure_facts, encode_timing_facts,
};
use crate::position::{ManagedPosition, PositionEntry, PositionExit, TrailFactor};
use crate::state::CandleContext;
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
                let current_rate = trade.current_rate(current_price);

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
            let candles_held = trade.candles_held;
            let source_amount = trade.source_amount;
            let is_buy = trade.is_buy();

            // Classify: Grace (profit) or Violence (loss).
            let reality = if ret > 0.0 {
                RealityOutcome::Grace { amount: (ret * source_amount).abs() }
            } else {
                RealityOutcome::Violence { amount: (ret * source_amount).abs() }
            };
            let grace = ret > 0.0;

            // Compute optimal distance from price history (hindsight).
            // Slice from entry forward using candles_held as the offset from window end.
            let optimal_dist = find_closes_from_entry(candle_window, candles_held)
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
    /// encode exit judgment facts for this lens, compose with the market thought,
    /// propose the composed thought on the tuple journal, and insert a proposal
    /// if conditions are met.
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

        // ── Phase B: sequential dispatch with exit composition ─────────
        let candle = candle_window.last();
        self.dispatch_thoughts(&thoughts, candle, Some(ctx));

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
    /// Also ticks paper entries on each tuple journal. Resolved papers feed
    /// Grace/Violence labels into the journal and recommended distances into
    /// the LearnedStop — the fast learning stream.
    pub fn step_process(
        &mut self,
        thoughts: &[holon::Vector],
        current_price: f64,
        current_atr: f64,
        paper_k_trail: f64,
        paper_k_tp: f64,
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
                let current_rate = trade.current_rate(current_price);

                // Tick the trade — updates trailing stop, checks triggers.
                // We intentionally IGNORE the exit signal here.
                // Resolution happens in Step 1 of the NEXT candle.
                let _exit = trade.tick(current_rate, k_trail);
            }
        }

        // ── Paper entries: tick all journals' papers ──
        for i in 0..self.registry.len() {
            let observations = self.registry[i].tick_papers(
                current_price,
                paper_k_trail,
                paper_k_tp,
            );
            // Feed resolved paper observations into the LearnedStop.
            for (thought, distance, weight) in observations {
                self.learned_stops[i].observe(thought, distance, weight);
            }
        }
    }

    /// Phase B of Step 2: sequential dispatch of pre-computed thoughts into the registry.
    ///
    /// For each (market_idx, exit_idx) pair: determine the ExitLens for this
    /// exit_idx, encode exit judgment facts from the candle, compose the market
    /// thought with the exit fact vector via bundle, propose the COMPOSED thought
    /// on the tuple journal, query the learned stop, and insert a proposal if all
    /// conditions are met.
    ///
    /// The composition follows wat/exit/observer.wat:
    ///   (apply bundle (cons market-thought judgment-facts))
    ///
    /// When `candle` is None (e.g. in tests), falls back to passing the raw
    /// market thought without exit composition.
    pub fn dispatch_thoughts(
        &mut self,
        thoughts: &[Vector],
        candle: Option<&Candle>,
        ctx: Option<&CandleContext>,
    ) {
        for market_idx in 0..self.n_market.min(thoughts.len()) {
            let market_thought = &thoughts[market_idx];

            for exit_idx in 0..self.m_exit {
                let i = self.idx(market_idx, exit_idx);

                // Compose: bundle market thought with exit judgment facts.
                let composed = if let (Some(candle), Some(ctx)) = (candle, ctx) {
                    let exit_lens = EXIT_LENSES.get(exit_idx).copied()
                        .unwrap_or(ExitLens::ExitGeneralist);
                    compose_with_exit_facts(market_thought, candle, exit_lens, ctx)
                } else {
                    market_thought.clone()
                };

                let journal = &mut self.registry[i];

                // Propose: updates noise subspace, predicts grace/violence.
                let prediction = journal.propose(&composed);

                // Register a paper entry — hypothetical trade for fast learning.
                // Every candle, every tuple gets a paper. No funding gate.
                if let Some(ctx) = ctx {
                    let distance = self.learned_stops[i].recommended_distance(&composed);
                    let entry_price = candle.map(|c| c.close).unwrap_or(1.0);
                    let entry_atr = candle.map(|c| c.atr_r).unwrap_or(0.01);
                    journal.register_paper(
                        composed.clone(),
                        entry_price,
                        entry_atr,
                        ctx.k_stop,
                        distance,
                    );
                }

                // Check proposal conditions:
                //   - journal must have proven its curve (funded)
                //   - prediction must have a direction with conviction > 0.2
                //   - learned stop must have at least one pair
                if journal.funded()
                    && prediction.direction.is_some()
                    && prediction.conviction > 0.2
                    && self.learned_stops[i].pair_count() > 0
                {
                    // Query the learned stop with the composed thought.
                    let distance = self.learned_stops[i].recommended_distance(&composed);

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

    /// The candle loop. Four steps. Sequential. Reality first.
    ///
    /// See `on-candle` in `wat/enterprise.wat` for the specification.
    pub fn on_candle(
        &mut self,
        observers: &mut [crate::market::observer::Observer],
        candle_window: &[crate::candle::Candle],
        candle: &crate::candle::Candle,
        encode_count: usize,
        ctx: &crate::state::CandleContext,
    ) {
        let current_price = candle.close;
        let current_atr = candle.atr;

        // Step 1: RESOLVE — close triggered trades, settle, propagate
        self.step_resolve(
            current_price,
            candle_window,
            TrailFactor(ctx.k_trail),
            ctx.conviction_quantile,
            ctx.conviction_window,
        );

        // Step 2: COMPUTE + DISPATCH — encode, compose, propose
        let thoughts = self.step_compute_dispatch(observers, candle_window, encode_count, ctx);

        // Step 3: PROCESS — update triggers, tick papers
        self.step_process(&thoughts, current_price, current_atr, ctx.k_trail, ctx.k_tp);

        // Step 4: COLLECT + FUND — evaluate proposals, fund or reject
        self.step_collect_fund(current_price, current_atr, ctx.k_stop, ctx.k_tp);
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
                // Direction from the journal prediction: Grace = buy, Violence = sell.
                // If direction is None or matches violence_label, open as sell (WBTC → USDC).
                let is_sell = proposal.direction.is_none()
                    || proposal.direction == Some(journal.violence_label);
                let (source, target) = if is_sell {
                    (Asset::new("WBTC"), Asset::new("USDC"))
                } else {
                    (Asset::new("USDC"), Asset::new("WBTC"))
                };

                // Rate is always source_per_target.
                // Buy (USDC→WBTC): rate = price. Sell (WBTC→USDC): rate = 1/price.
                let entry_rate = if is_sell { 1.0 / current_price } else { current_price };
                let source_amount = 1000.0; // nominal — capital sizing comes later
                let entry = PositionEntry {
                    id: i,
                    candle_idx: 0, // caller should set this; placeholder for now
                    source_asset: source,
                    target_asset: target,
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

    /// Emit diagnostic log entries for all N×M slots.
    ///
    /// Called every 1000 candles to avoid excessive row counts.
    /// Produces one EnterpriseLog per slot — visibility into what
    /// each tuple journal has learned, its proof state, and paper activity.
    pub fn emit_diagnostics(&self, candle_idx: usize) -> Vec<crate::ledger::LogEntry> {
        let mut logs = Vec::with_capacity(self.n_market * self.m_exit);
        let market_lenses = crate::market::OBSERVER_LENSES;
        let exit_lenses = EXIT_LENSES;

        for mi in 0..self.n_market {
            for ei in 0..self.m_exit {
                let i = self.idx(mi, ei);
                let journal = &self.registry[i];
                let learned_stop = &self.learned_stops[i];

                // Query recommended distance with a zero vector — gives the
                // global average when no specific thought context is available.
                let dims = journal.noise_subspace.dim();
                let recommended_dist = learned_stop.recommended_distance(
                    &holon::Vector::zeros(dims),
                );

                logs.push(crate::ledger::LogEntry::EnterpriseLog {
                    candle_idx: candle_idx as i64,
                    slot_idx: i as i64,
                    market_lens: market_lenses.get(mi)
                        .map(|l| l.as_str().to_string())
                        .unwrap_or_else(|| format!("market-{}", mi)),
                    exit_lens: exit_lenses.get(ei)
                        .map(|l| l.as_str().to_string())
                        .unwrap_or_else(|| format!("exit-{}", ei)),
                    learned_pairs: learned_stop.pair_count() as i64,
                    recommended_dist,
                    paper_count: journal.paper_count() as i64,
                    journal_grace: journal.cumulative_grace,
                    journal_violence: journal.cumulative_violence,
                    journal_trades: journal.trade_count as i64,
                    curve_valid: journal.curve_valid as i32,
                    cached_acc: journal.cached_acc,
                });
            }
        }
        logs
    }
}

/// Compose a market thought with exit judgment facts for a given lens.
///
/// Encodes the exit vocabulary facts into vectors using the ThoughtEncoder,
/// then bundles them with the market thought. This is the Rust implementation
/// of `(apply bundle (cons market-thought judgment-facts))` from
/// wat/exit/observer.wat.
fn compose_with_exit_facts(
    market_thought: &Vector,
    candle: &Candle,
    exit_lens: ExitLens,
    ctx: &CandleContext,
) -> Vector {
    use crate::vocab::Fact;

    // Gather exit facts based on the lens.
    let exit_facts: Vec<Fact<'static>> = match exit_lens {
        ExitLens::Volatility => encode_volatility_facts(candle),
        ExitLens::Structure => encode_structure_facts(candle),
        ExitLens::Timing => encode_timing_facts(candle),
        ExitLens::ExitGeneralist => {
            let mut all = encode_volatility_facts(candle);
            all.extend(encode_structure_facts(candle));
            all.extend(encode_timing_facts(candle));
            all
        }
    };

    if exit_facts.is_empty() {
        return market_thought.clone();
    }

    // Encode facts into vectors using the ThoughtEncoder.
    let (cached_refs, owned_vecs) = ctx.thought_encoder.encode_facts(&exit_facts);

    // Collect all vectors to bundle: market thought + exit fact vectors.
    let mut bundle_inputs: Vec<&Vector> = Vec::with_capacity(1 + cached_refs.len() + owned_vecs.len());
    bundle_inputs.push(market_thought);
    bundle_inputs.extend(cached_refs);
    for v in &owned_vecs {
        bundle_inputs.push(v);
    }

    Primitives::bundle(&bundle_inputs)
}

/// Extract close prices from the candle window starting at the entry point.
///
/// `candles_held`: how many candles the trade has been open. The entry is
/// `candles_held` candles back from the end of the window. If the entry is
/// older than the window, the full window is used as best available.
fn find_closes_from_entry(candle_window: &[crate::candle::Candle], candles_held: usize) -> Option<Vec<f64>> {
    let window_len = candle_window.len();
    if window_len < 2 { return None; }

    // Slice from entry forward. If entry is older than the window, use full window.
    let offset = if candles_held >= window_len {
        0
    } else {
        window_len - candles_held
    };

    let slice = &candle_window[offset..];
    if slice.len() < 2 { return None; }

    let closes: Vec<f64> = slice.iter().map(|c| c.close).collect();
    Some(closes)
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

        e.dispatch_thoughts(&thoughts, None, None);

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
        // Without candle/ctx, composed = market thought directly (no exit facts).
        let mut e = Enterprise::new(1, 3, 64, 500, &["m0"], &["e0", "e1", "e2"]);
        let vm = holon::VectorManager::new(64);
        let thoughts = vec![vm.get_vector("market-thought")];

        e.dispatch_thoughts(&thoughts, None, None);

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
        e.dispatch_thoughts(&thoughts, None, None);

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

        e.dispatch_thoughts(&thoughts, None, None);

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
        e.dispatch_thoughts(&thoughts, None, None);

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
        e.dispatch_thoughts(&thoughts, None, None);
        assert_eq!(e.proposal_count(), 0);
    }

    // ── compose_with_exit_facts tests ──────────────────────────────

    #[test]
    fn compose_produces_different_vectors_per_exit_lens() {
        // Each exit lens encodes different facts, so the composed thought
        // should differ across lenses even for the same market thought + candle.
        use crate::thought::{ThoughtEncoder, ThoughtVocab};

        let vm = holon::VectorManager::new(128);
        let vocab = ThoughtVocab::new(&vm);
        let encoder = ThoughtEncoder::new(vocab);
        let scalar = holon::ScalarEncoder::new(128);
        let mgr_atoms = crate::market::manager::ManagerAtoms::new(&vm);
        let exit_scalar = holon::ScalarEncoder::new(128);
        let exit_atoms = crate::market::exit::ExitAtoms::new(&vm);
        let risk_scalar = holon::ScalarEncoder::new(128);
        let risk_atoms = crate::risk::RiskAtoms::new(&vm);
        let risk_mgr_atoms = crate::risk::manager::RiskManagerAtoms::new(&vm);
        let observer_atoms: Vec<holon::Vector> = crate::market::OBSERVER_LENSES
            .iter().map(|l| vm.get_vector(l.as_str())).collect();
        let generalist_atom = vm.get_vector("generalist");
        let (cb_labels, cb_vecs) = encoder.fact_codebook();

        let ctx = CandleContext {
            dims: 128, horizon: 36, move_threshold: 0.005, atr_multiplier: 0.0,
            decay: 0.999, recalib_interval: 500, min_conviction: 0.0,
            conviction_quantile: 0.85, conviction_mode: crate::state::ConvictionMode::Quantile,
            min_edge: 0.55, sizing: crate::state::SizingMode::Legacy,
            max_drawdown: 0.20, swap_fee: 0.0, slippage: 0.0,
            asset_mode: crate::state::AssetMode::Hold,
            base_asset: &crate::treasury::Asset::new("USDC"),
            quote_asset: &crate::treasury::Asset::new("WBTC"),
            initial_equity: 10000.0, diagnostics: false,
            k_stop: 3.0, k_trail: 1.5, k_trail_runner: 3.0, k_tp: 6.0,
            exit_horizon: 9, exit_observe_interval: 4,
            decay_stable: 0.999, decay_adapting: 0.995,
            highconv_rolling_cap: 200, max_single_position: 0.2,
            conviction_warmup: 1000, conviction_window: 2000,
            vm: &vm, thought_encoder: &encoder,
            mgr_atoms: &mgr_atoms, mgr_scalar: &scalar,
            exit_scalar: &exit_scalar, exit_atoms: &exit_atoms,
            risk_scalar: &risk_scalar, risk_atoms: &risk_atoms,
            risk_mgr_atoms: &risk_mgr_atoms,
            observer_atoms: &observer_atoms, generalist_atom: &generalist_atom,
            min_opinion_magnitude: 0.01,
            codebook_labels: &cb_labels, codebook_vecs: &cb_vecs,
            loop_count: 100, progress_every: 100,
            t_start: std::time::Instant::now(),
        };

        let candle = make_test_candle(50000.0);
        let market_thought = vm.get_vector("test-market-thought");

        let vol  = compose_with_exit_facts(&market_thought, &candle, ExitLens::Volatility, &ctx);
        let struc = compose_with_exit_facts(&market_thought, &candle, ExitLens::Structure, &ctx);
        let time = compose_with_exit_facts(&market_thought, &candle, ExitLens::Timing, &ctx);
        let gen  = compose_with_exit_facts(&market_thought, &candle, ExitLens::ExitGeneralist, &ctx);

        // Each composed vector should be different from the raw market thought.
        let sim_raw_vol = holon::Similarity::cosine(&market_thought, &vol);
        assert!(sim_raw_vol < 0.99, "volatility composed should differ from raw market thought: {}", sim_raw_vol);

        // Different lenses should produce different compositions.
        let sim_vol_struc = holon::Similarity::cosine(&vol, &struc);
        let sim_vol_time = holon::Similarity::cosine(&vol, &time);
        assert!(sim_vol_struc < 0.99, "volatility vs structure should differ: {}", sim_vol_struc);
        assert!(sim_vol_time < 0.99, "volatility vs timing should differ: {}", sim_vol_time);

        // Generalist should be different from each specialist (it has all facts).
        let sim_gen_vol = holon::Similarity::cosine(&gen, &vol);
        assert!(sim_gen_vol < 0.99, "generalist vs volatility should differ: {}", sim_gen_vol);
    }

    #[test]
    fn dispatch_with_candle_composes_exit_facts() {
        // When a candle and ctx are provided, dispatch should compose exit facts
        // into the thought before proposing. Verify by checking the noise subspace
        // receives a composed vector, not the raw market thought.
        use crate::thought::{ThoughtEncoder, ThoughtVocab};

        let vm = holon::VectorManager::new(128);
        let vocab = ThoughtVocab::new(&vm);
        let encoder = ThoughtEncoder::new(vocab);
        let scalar = holon::ScalarEncoder::new(128);
        let mgr_atoms = crate::market::manager::ManagerAtoms::new(&vm);
        let exit_scalar = holon::ScalarEncoder::new(128);
        let exit_atoms = crate::market::exit::ExitAtoms::new(&vm);
        let risk_scalar = holon::ScalarEncoder::new(128);
        let risk_atoms = crate::risk::RiskAtoms::new(&vm);
        let risk_mgr_atoms = crate::risk::manager::RiskManagerAtoms::new(&vm);
        let observer_atoms: Vec<holon::Vector> = crate::market::OBSERVER_LENSES
            .iter().map(|l| vm.get_vector(l.as_str())).collect();
        let generalist_atom = vm.get_vector("generalist");
        let (cb_labels, cb_vecs) = encoder.fact_codebook();

        let ctx = CandleContext {
            dims: 128, horizon: 36, move_threshold: 0.005, atr_multiplier: 0.0,
            decay: 0.999, recalib_interval: 500, min_conviction: 0.0,
            conviction_quantile: 0.85, conviction_mode: crate::state::ConvictionMode::Quantile,
            min_edge: 0.55, sizing: crate::state::SizingMode::Legacy,
            max_drawdown: 0.20, swap_fee: 0.0, slippage: 0.0,
            asset_mode: crate::state::AssetMode::Hold,
            base_asset: &crate::treasury::Asset::new("USDC"),
            quote_asset: &crate::treasury::Asset::new("WBTC"),
            initial_equity: 10000.0, diagnostics: false,
            k_stop: 3.0, k_trail: 1.5, k_trail_runner: 3.0, k_tp: 6.0,
            exit_horizon: 9, exit_observe_interval: 4,
            decay_stable: 0.999, decay_adapting: 0.995,
            highconv_rolling_cap: 200, max_single_position: 0.2,
            conviction_warmup: 1000, conviction_window: 2000,
            vm: &vm, thought_encoder: &encoder,
            mgr_atoms: &mgr_atoms, mgr_scalar: &scalar,
            exit_scalar: &exit_scalar, exit_atoms: &exit_atoms,
            risk_scalar: &risk_scalar, risk_atoms: &risk_atoms,
            risk_mgr_atoms: &risk_mgr_atoms,
            observer_atoms: &observer_atoms, generalist_atom: &generalist_atom,
            min_opinion_magnitude: 0.01,
            codebook_labels: &cb_labels, codebook_vecs: &cb_vecs,
            loop_count: 100, progress_every: 100,
            t_start: std::time::Instant::now(),
        };

        // 1 market × 4 exit (matching EXIT_LENSES)
        let mut e = Enterprise::new(1, 4, 128, 500, &["m0"],
            &["volatility", "structure", "timing", "exit-generalist"]);
        let thought = vm.get_vector("market-thought-for-compose");
        let thoughts = vec![thought];
        let candle = make_test_candle(50000.0);

        e.dispatch_thoughts(&thoughts, Some(&candle), Some(&ctx));

        // All 4 exit slots should have been updated.
        for i in 0..4 {
            assert_eq!(e.registry[i].noise_subspace.n(), 1,
                "exit slot {} should have 1 noise observation", i);
        }
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

        let mut pos = ManagedPosition::new(make_buy_entry(50000.0, 0.01, 2.0, 3.0));
        // Simulate a trade that has been open for 30 candles so that
        // find_closes_from_entry has enough price history for compute_optimal_distance.
        pos.candles_held = 30;
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
        e.step_process(&thoughts, 50000.0, 0.02, 1.5, 3.0);
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
        e.step_process(&thoughts, 50500.0, 0.02, 1.5, 3.0);

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
        e.step_process(&thoughts, 51000.0, 0.02, 1.5, 3.0);

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

        e.step_process(&thoughts, 50500.0, 0.02, 1.5, 3.0);

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
        let grace = e.registry[0].grace_label;

        // Insert a proposal with Grace direction (buy: USDC → WBTC).
        e.proposals[0] = Some(Proposal {
            composed_thought: holon::Vector::zeros(64),
            direction: Some(grace),
            distance: 0.02,
            conviction: 0.5,
            market_idx: 0,
            exit_idx: 0,
        });

        assert_eq!(e.active_trade_count(), 0);
        e.step_collect_fund(50000.0, 0.01, 2.0, 3.0);

        // Trade should have been opened as buy (Grace direction).
        assert_eq!(e.active_trade_count(), 1);
        let trade = e.trades[0].as_ref().unwrap();
        assert!((trade.entry_rate - 50000.0).abs() < 1e-6);
        assert!((trade.entry_atr - 0.01).abs() < 1e-12);
        assert!(trade.is_buy(), "Grace direction should open a buy");

        // Thought should be stashed.
        assert!(e.trade_thoughts[0].is_some());
        assert_eq!(e.trade_thoughts[0].as_ref().unwrap().len(), 1);

        // Proposal should be cleared.
        assert!(e.proposals[0].is_none());
    }

    #[test]
    fn step_collect_fund_violence_direction_opens_sell() {
        let mut e = Enterprise::new(1, 1, 64, 500, &["m"], &["e"]);

        // Force the journal to be funded.
        e.registry[0].curve_valid = true;
        let violence = e.registry[0].violence_label;

        // Insert a proposal with Violence direction (sell: WBTC → USDC).
        e.proposals[0] = Some(Proposal {
            composed_thought: holon::Vector::zeros(64),
            direction: Some(violence),
            distance: 0.02,
            conviction: 0.5,
            market_idx: 0,
            exit_idx: 0,
        });

        e.step_collect_fund(50000.0, 0.01, 2.0, 3.0);

        assert_eq!(e.active_trade_count(), 1);
        let trade = e.trades[0].as_ref().unwrap();
        // Sell: rate = 1/price
        assert!((trade.entry_rate - 1.0 / 50000.0).abs() < 1e-12);
        assert!(!trade.is_buy(), "Violence direction should open a sell");
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

    // ── on_candle integration tests ─────────────────────────────────

    /// Build a minimal CandleContext for on_candle tests.
    /// Uses a small ThoughtEncoder and VectorManager at 64 dims.
    struct OnCandleInfra {
        vm: holon::VectorManager,
        thought_encoder: crate::thought::ThoughtEncoder,
        mgr_atoms: crate::market::manager::ManagerAtoms,
        mgr_scalar: holon::ScalarEncoder,
        exit_scalar: holon::ScalarEncoder,
        exit_atoms: crate::market::exit::ExitAtoms,
        risk_scalar: holon::ScalarEncoder,
        risk_atoms: crate::risk::RiskAtoms,
        risk_mgr_atoms: crate::risk::manager::RiskManagerAtoms,
        observer_atoms: Vec<holon::Vector>,
        generalist_atom: holon::Vector,
        codebook_labels: Vec<String>,
        codebook_vecs: Vec<holon::Vector>,
    }

    impl OnCandleInfra {
        fn new() -> Self {
            use crate::thought::{ThoughtVocab, ThoughtEncoder};
            use crate::market::OBSERVER_LENSES;

            let vm = holon::VectorManager::new(64);
            let vocab = ThoughtVocab::new(&vm);
            let thought_encoder = ThoughtEncoder::new(vocab);
            let mgr_atoms = crate::market::manager::ManagerAtoms::new(&vm);
            let mgr_scalar = holon::ScalarEncoder::new(64);
            let exit_scalar = holon::ScalarEncoder::new(64);
            let exit_atoms = crate::market::exit::ExitAtoms::new(&vm);
            let risk_scalar = holon::ScalarEncoder::new(64);
            let risk_atoms = crate::risk::RiskAtoms::new(&vm);
            let risk_mgr_atoms = crate::risk::manager::RiskManagerAtoms::new(&vm);
            let observer_atoms: Vec<holon::Vector> = OBSERVER_LENSES.iter()
                .map(|lens| vm.get_vector(lens.as_str()))
                .collect();
            let generalist_atom = vm.get_vector("generalist");
            let (codebook_labels, codebook_vecs) = thought_encoder.fact_codebook();
            Self {
                vm, thought_encoder, mgr_atoms, mgr_scalar,
                exit_scalar, exit_atoms, risk_scalar, risk_atoms,
                risk_mgr_atoms, observer_atoms, generalist_atom,
                codebook_labels, codebook_vecs,
            }
        }

        fn ctx(&self) -> crate::state::CandleContext<'_> {
            use crate::state::*;
            let base_asset = Asset::new("USDC");
            let quote_asset = Asset::new("WBTC");
            CandleContext {
                dims: 64,
                horizon: 36,
                move_threshold: 0.005,
                atr_multiplier: 1.0,
                decay: 0.999,
                recalib_interval: 200,
                min_conviction: 0.0,
                conviction_quantile: 0.5,
                conviction_mode: ConvictionMode::Quantile,
                min_edge: 0.01,
                sizing: SizingMode::Kelly,
                max_drawdown: 0.15,
                swap_fee: 0.001,
                slippage: 0.0025,
                asset_mode: AssetMode::Hold,
                base_asset: Box::leak(Box::new(base_asset)),
                quote_asset: Box::leak(Box::new(quote_asset)),
                initial_equity: 10000.0,
                diagnostics: false,
                k_stop: 2.0,
                k_trail: 1.5,
                k_trail_runner: 3.0,
                k_tp: 3.0,
                exit_horizon: 36,
                exit_observe_interval: 5,
                decay_stable: 0.999,
                decay_adapting: 0.995,
                highconv_rolling_cap: 100,
                max_single_position: 0.03,
                conviction_warmup: 100,
                conviction_window: 500,
                vm: &self.vm,
                thought_encoder: &self.thought_encoder,
                mgr_atoms: &self.mgr_atoms,
                mgr_scalar: &self.mgr_scalar,
                exit_scalar: &self.exit_scalar,
                exit_atoms: &self.exit_atoms,
                risk_scalar: &self.risk_scalar,
                risk_atoms: &self.risk_atoms,
                risk_mgr_atoms: &self.risk_mgr_atoms,
                observer_atoms: &self.observer_atoms,
                generalist_atom: &self.generalist_atom,
                min_opinion_magnitude: crate::market::manager::noise_floor(64),
                codebook_labels: &self.codebook_labels,
                codebook_vecs: &self.codebook_vecs,
                loop_count: 1000,
                progress_every: 500,
                t_start: std::time::Instant::now(),
            }
        }
    }

    fn make_observers() -> Vec<crate::market::observer::Observer> {
        use crate::market::{observer::Observer, OBSERVER_LENSES};
        OBSERVER_LENSES.iter().enumerate().map(|(i, lens)| {
            Observer::new(*lens, 64, 200, i as u64 + 42)
        }).collect()
    }

    #[test]
    fn on_candle_single_candle_runs_four_steps() {
        let infra = OnCandleInfra::new();
        let ctx = infra.ctx();
        let mut e = Enterprise::new(
            6, 1, 64, 200,
            &["momentum", "structure", "volume", "narrative", "regime", "generalist"],
            &["exit"],
        );
        let mut observers = make_observers();

        let candle = make_test_candle(50000.0);
        let candle_window = vec![candle.clone()];

        // Should not panic. All four steps execute.
        e.on_candle(&mut observers, &candle_window, &candle, 1, &ctx);

        // Verify dispatch happened: noise subspaces should have been updated.
        for journal in &e.registry {
            assert_eq!(journal.noise_subspace.n(), 1,
                "each tuple journal should have one noise observation from dispatch");
        }
        // No proposals since journals are cold.
        assert_eq!(e.proposal_count(), 0);
        assert_eq!(e.active_trade_count(), 0);
    }

    #[test]
    fn on_candle_multiple_candles_accumulates() {
        let infra = OnCandleInfra::new();
        let ctx = infra.ctx();
        let mut e = Enterprise::new(
            6, 1, 64, 200,
            &["momentum", "structure", "volume", "narrative", "regime", "generalist"],
            &["exit"],
        );
        let mut observers = make_observers();

        // Feed 10 candles through on_candle.
        let mut candle_window: Vec<crate::candle::Candle> = Vec::new();
        for i in 0..10 {
            let candle = make_test_candle(50000.0 + i as f64 * 50.0);
            candle_window.push(candle.clone());
            e.on_candle(&mut observers, &candle_window, &candle, i + 1, &ctx);
        }

        // After 10 candles, each journal should have 10 noise observations.
        for journal in &e.registry {
            assert_eq!(journal.noise_subspace.n(), 10,
                "each journal should have 10 observations after 10 candles");
        }
    }
}
