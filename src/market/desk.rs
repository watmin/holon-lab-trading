//! Desk — a trading pair's full enterprise tree.
//!
//! Each desk trades one pair (source / target). It owns the complete
//! prediction + learning stack for that pair:
//!   - Observer panel (5 specialists + 1 generalist)
//!   - Manager journal (aggregates observer opinions)
//!   - Exit expert journal (learns hold/exit from position state)
//!   - Positions (managed allocations from the treasury)
//!   - Pending entries (learning queue)
//!   - Conviction + curve (Kelly sizing)
//!   - Panel engram (expert agreement reaction)
//!   - Adaptive decay
//!
//! Risk lives on the enterprise, not the desk. Risk measures portfolio health
//! across ALL desks. The desk produces signals. Risk gates them.
//!
//! The desk is a value. The enterprise iterates Vec<Desk>.

use std::collections::VecDeque;

use holon::Vector;
use holon::memory::{Journal, OnlineSubspace};

use crate::candle::Candle;
use crate::journal::{Label, Direction, Prediction};
use crate::ledger::LogEntry;
use crate::market::manager::{ManagerContext, encode_manager_thought, find_proven_band};
use crate::market::observer::Observer;
use crate::portfolio::{Phase, Portfolio};
use crate::position::{CrossingSnapshot, ExitObservation, ExitReason, ManagedPosition, Pending, PositionEntry, PositionExit, PositionPhase, TrailFactor};
use crate::sizing::{curve_win_rate, half_kelly_position, kelly_frac, signal_weight};
use crate::treasury::{Asset, Treasury};
use crate::window_sampler::WindowSampler;
use crate::market::exit::encode_exit_thought;
use crate::state::{
    AssetMode, CandleContext, SizingMode, TradePnl,
    GENERALIST_IDX,
};

use super::OBSERVER_LENSES;

/// Maximum base position fraction before risk scaling.
/// Derived from typical proven-band edge (~3% of portfolio at full conviction).
const MAX_BASE_POSITION: f64 = 0.03;

/// Minimum position size as fraction of equity. The enterprise never fully stops betting.
const MIN_BET: f64 = 0.01;
/// Risk multiplier threshold — below this, no new positions.
const RISK_GATE_THRESHOLD: f64 = 0.3;

/// The enterprise's shared mutable state, passed to each desk's fold step.
/// Groups what the desk needs to mutate that it doesn't own.
/// 5 fields instead of 5 separate &mut parameters.
pub struct SharedState<'a> {
    pub treasury: &'a mut Treasury,
    pub portfolio: &'a mut Portfolio,
    pub risk_mult: f64,
    pub peak_equity: &'a mut f64,
    pub db_batch: &'a mut usize,
}

/// Configuration for creating a desk.
pub struct DeskConfig {
    pub name: String,
    pub source_asset: Asset,
    pub target_asset: Asset,
    pub dims: usize,
    pub recalib_interval: usize,
    pub window: usize,
    pub max_window_size: usize,
    pub decay: f64,
}

/// Observer seed spacing prime — same seed logic as the old EnterpriseState::new.
const OBSERVER_SEED_PRIME: u64 = 7919;

/// A desk — one pair's full enterprise tree.
///
/// Contains indicators, candle window, observers, manager, exit expert,
/// positions, pending, conviction, panel engram, adaptive decay, accounting.
/// Everything per-pair. No global candle buffer.
///
/// Risk lives on the enterprise (shared across desks).
/// Treasury lives on the enterprise (shared across desks).
/// Portfolio lives on the enterprise (shared across desks).
pub struct Desk {

    // ── Streaming indicators + candle window ────────────────────────────
    pub indicator_bank: crate::indicators::IndicatorBank,
    pub candle_window: std::collections::VecDeque<crate::candle::Candle>,
    pub max_window_size: usize,

    // ── Observer panel ──────────────────────────────────────────────────
    pub observers: Vec<Observer>,

    // ── Manager ─────────────────────────────────────────────────────────
    pub manager_journal: Journal,
    pub manager_buy: Label,
    pub manager_sell: Label,
    pub manager_resolved: VecDeque<(f64, bool)>,
    pub manager_curve_valid: bool,
    pub manager_proven_band: (f64, f64),
    pub prev_manager_thought: Option<Vector>,

    // ── Exit expert ─────────────────────────────────────────────────────
    pub exit_journal: Journal,
    pub exit_hold: Label,
    pub exit_exit: Label,
    pub exit_pending: Vec<ExitObservation>,

    // ── Positions ───────────────────────────────────────────────────────
    pub positions: Vec<ManagedPosition>,
    pub pending: VecDeque<Pending>,
    pub next_position_id: usize,
    pub last_exit_price: f64,
    pub last_exit_atr: f64,

    // ── Conviction + curve ──────────────────────────────────────────────
    pub conviction_history: VecDeque<f64>,
    pub conviction_threshold: f64,
    pub resolved_preds: VecDeque<(f64, bool)>,
    pub kelly_curve_valid: bool,
    pub cached_curve_a: f64,
    pub cached_curve_b: f64,

    // ── Panel engram ────────────────────────────────────────────────────
    pub panel_engram: OnlineSubspace,
    pub panel_recalib_wins: u32,
    pub panel_recalib_total: u32,

    // ── Adaptive decay ──────────────────────────────────────────────────
    pub adaptive_decay: f64,
    pub in_adaptation: bool,
    pub highconv_wins: VecDeque<bool>,

    // ── Tracking (per-desk, merged to enterprise in on_event) ───────────
    pub move_sum: f64,
    pub move_count: usize,
    pub labeled_count: usize,
    pub noise_count: usize,

    // ── Accounting ──────────────────────────────────────────────────────
    pub encode_count: usize,
    pub position_swaps: usize,
    pub position_wins: usize,
    pub log_step: i64,
    pub pending_logs: Vec<LogEntry>,
}

impl Desk {
    /// Create a desk for one trading pair.
    pub fn new(config: DeskConfig) -> Self {
        let dims = config.dims;
        let recalib = config.recalib_interval;

        // ── Observer panel ──────────────────────────────────────────
        let mut observers: Vec<Observer> = OBSERVER_LENSES
            .iter()
            .enumerate()
            .map(|(ei, &lens)| {
                Observer::new(
                    lens,
                    dims,
                    recalib,
                    dims as u64 + ei as u64 * OBSERVER_SEED_PRIME,
                    &["Buy", "Sell"],
                )
            })
            .collect();

        // Both generalists use fixed windows.
        observers[GENERALIST_IDX].window_sampler = WindowSampler::new(
            dims as u64 + 5 * OBSERVER_SEED_PRIME,
            config.window, config.window,
        );
        // gen-classic: fixed 48, same as old trader3
        let gen_classic_idx = OBSERVER_LENSES.len() - 1;
        observers[gen_classic_idx].window_sampler = WindowSampler::new(
            dims as u64 + 6 * OBSERVER_SEED_PRIME,
            config.window, config.window,
        );

        // ── Manager journal ─────────────────────────────────────────
        let mut mgr_journal = Journal::new("manager", dims, recalib);
        let mgr_buy = mgr_journal.register("Buy");
        let mgr_sell = mgr_journal.register("Sell");

        // ── Exit expert journal ─────────────────────────────────────
        let mut exit_journal = Journal::new("exit-expert", dims, recalib);
        let exit_hold = exit_journal.register("Hold");
        let exit_exit = exit_journal.register("Exit");

        // ── Panel engram ────────────────────────────────────────────
        let panel_dim = OBSERVER_LENSES.len();
        let panel_engram = OnlineSubspace::with_params(panel_dim, 4, 2.0, 0.01, 3.5, 100);

        let max_window_size = config.max_window_size;

        Self {
            indicator_bank: crate::indicators::IndicatorBank::new(),
            candle_window: VecDeque::with_capacity(max_window_size + 1),
            max_window_size,
            observers,
            manager_journal: mgr_journal,
            manager_buy: mgr_buy,
            manager_sell: mgr_sell,
            manager_resolved: VecDeque::new(),
            manager_curve_valid: false,
            manager_proven_band: (0.0, 0.0),
            prev_manager_thought: None,
            exit_journal,
            exit_hold,
            exit_exit,
            exit_pending: Vec::new(),
            positions: Vec::new(),
            pending: VecDeque::new(),
            next_position_id: 0,
            last_exit_price: 0.0,
            last_exit_atr: 0.0,
            conviction_history: VecDeque::new(),
            conviction_threshold: 0.0,
            resolved_preds: VecDeque::new(),
            kelly_curve_valid: false,
            cached_curve_a: 0.0,
            cached_curve_b: 0.0,
            panel_engram,
            panel_recalib_wins: 0,
            panel_recalib_total: 0,
            adaptive_decay: 0.0, // Set by enterprise after construction
            in_adaptation: false,
            highconv_wins: VecDeque::new(),
            move_sum: 0.0,
            move_count: 0,
            labeled_count: 0,
            noise_count: 0,
            encode_count: 0,
            position_swaps: 0,
            position_wins: 0,
            log_step: 0,
            pending_logs: Vec::new(),
        }
    }

    /// The generalist's Buy label.
    fn tht_buy(&self) -> Label { self.observers[GENERALIST_IDX].primary_label }

    /// The generalist's Sell label (second registered label).
    fn tht_sell(&self) -> Label { self.observers[GENERALIST_IDX].journal.labels()[1] }

    /// The desk's fold step. One candle, one step.
    ///
    /// Called from EnterpriseState::on_candle_raw. The enterprise passes
    /// the raw OHLCV and shared resources. The desk computes its own indicators.
    /// The desk's fold step. One raw candle → indicators → thoughts → positions → learn.
    /// SharedState groups the enterprise's mutable state (3 params instead of 5).
    pub fn on_candle(
        &mut self,
        i: usize,
        raw: &crate::indicators::RawCandle,
        shared: &mut SharedState,
        ctx: &CandleContext,
    ) {
        // Destructure for body compatibility — the fold uses these names throughout.
        let treasury = &mut *shared.treasury;
        let portfolio = &mut *shared.portfolio;
        let risk_mult = shared.risk_mult;
        let peak_equity = &mut *shared.peak_equity;
        let db_batch = &mut *shared.db_batch;
        // Step indicator bank → computed candle (wat: tick-indicators)
        let candle = self.indicator_bank.tick(raw);

        // Push clone to window, keep owned candle for this fold step.
        // One clone instead of two — the window needs its copy, we need ours.
        self.candle_window.push_back(candle.clone());
        if self.candle_window.len() > self.max_window_size {
            self.candle_window.pop_front();
        }

        // Tempered: cache frequently-accessed scalars at function entry.
        let mgr_buy = self.manager_buy;
        let mgr_sell = self.manager_sell;
        let candle_ts = candle.ts.clone(); // one clone, used 4 times below
        self.encode_count += 1;

        // ── Observer thought encoding from candle window ────────────────
        let window_slice = self.candle_window.make_contiguous();
        let observer_vecs = Self::encode_observers(
            &self.observers, window_slice, self.encode_count, ctx);

        // ── Observer predictions (pmap: each journal.predict is independent) ──
        let observer_preds: Vec<Prediction> = {
            use rayon::prelude::*;
            self.observers.par_iter().zip(observer_vecs.par_iter())
                .map(|(obs, vec)| obs.journal.predict(vec))
                .collect()
        };

        // The generalist's prediction — used for manager encoding and logging.
        let tht_pred = observer_preds[GENERALIST_IDX].clone();
        let tht_vec = observer_vecs[GENERALIST_IDX].clone();

        // ── Manager: encodes observer opinions via manager.rs ─────────
        // Single canonical encoding path. See manager.rs and wat/manager.wat.
        // The first 5 observers are specialists; observer[5] is the generalist.
        // ManagerContext takes the 5 specialists for observer_* fields,
        // and the generalist separately.
        let mut obs_curve_valid = [false; 5];
        let mut obs_resolved_lens = [0usize; 5];
        let mut obs_resolved_accs = [0.0f64; 5];
        for (obs_idx, obs) in self.observers[..5].iter().enumerate() {
            obs_curve_valid[obs_idx] = obs.curve_valid;
            obs_resolved_lens[obs_idx] = obs.resolved.len();
            obs_resolved_accs[obs_idx] = obs.cached_acc;
        }
        let mgr_ctx = ManagerContext {
            observer_preds: &observer_preds[..5],
            observer_atoms: &ctx.observer_atoms[..5],
            observer_curve_valid: &obs_curve_valid,
            observer_resolved_lens: &obs_resolved_lens,
            observer_resolved_accs: &obs_resolved_accs,
            observer_vecs: &observer_vecs[..5],
            generalist_pred: &tht_pred,
            generalist_atom: ctx.generalist_atom,
            generalist_curve_valid: self.observers[GENERALIST_IDX].curve_valid,
            candle_atr: candle.atr_r,
            candle_hour: candle.hour,
            candle_day: candle.day_of_week,
            disc_strength: self.observers[GENERALIST_IDX].journal.last_disc_strength(),
        };
        let mgr_facts = encode_manager_thought(&mgr_ctx, ctx.mgr_atoms, ctx.mgr_scalar, ctx.min_opinion_magnitude);

        // Bundle facts + delta into one thought. Manager owns its motion encoding.
        let (mgr_pred, stored_mgr_thought) = if let Some((final_thought, raw)) =
            crate::market::manager::bundle_manager_thought(
                mgr_facts, self.prev_manager_thought.as_ref(), ctx.mgr_atoms)
        {
            self.prev_manager_thought = Some(raw);
            let pred = self.manager_journal.predict(&final_thought);
            (pred, Some(final_thought))
        } else {
            (Prediction::default(), None)
        };

        // Panel state for engram (Template 2 — reaction layer)
        // Panel state: observer raw cosines, fed to panel_engram.update() at recalibration
        // and used in progress display for engram familiarity check.
        let mut panel_state = vec![0.0f64; self.observers.len()];
        for (pi, ep) in observer_preds.iter().enumerate() { panel_state[pi] = ep.raw_cos; }
        // Manager's prediction drives direction + conviction.
        let meta_dir = mgr_pred.direction;
        let meta_conviction = mgr_pred.conviction;

        // Track conviction history for dynamic threshold computation.
        // Window spans recalib_interval * 100 candles (~6 months at 5m).
        // Large enough to be stable across week-to-week regime noise;
        // small enough to adapt as market structure shifts over quarters.
        self.conviction_history.push_back(meta_conviction);
        if self.conviction_history.len() > ctx.conviction_window {
            self.conviction_history.pop_front();
        }
        // Recompute flip threshold every recalib_interval candles, after warmup.
        if self.conviction_history.len() >= ctx.conviction_warmup
            && self.encode_count % ctx.recalib_interval == 0
        {
            if let Some(thresh) = crate::sizing::compute_conviction_threshold(
                &self.conviction_history,
                &self.resolved_preds,
                ctx.conviction_mode,
                ctx.conviction_quantile,
                ctx.min_edge,
                ctx.conviction_warmup,
            ) {
                self.conviction_threshold = thresh;
            }
        }

        // No flip. The enterprise doesn't invert its own decisions.

        // ── Position management: tick all open positions ─────────
        let quote_price = candle.close;
        let fee_rate = ctx.swap_fee + ctx.slippage;
        // Treasury equity: the source of truth. Token-agnostic.
        let prices = treasury.price_map(&[(ctx.quote_asset, quote_price)]);
        let treasury_equity = treasury.total_value(&prices);
        if treasury_equity > *peak_equity {
            *peak_equity = treasury_equity;
        }
        // ── Exit expert: encode each position's state, predict, learn ──
        // Resolve pending exit observations (did holding improve the position?)
        // Two-phase: collect resolved, then learn + drain. Avoids borrow conflict
        // between exit_pending (mut), positions (shared), and exit_journal (mut).
        {
            let mut resolved_exit_indices: Vec<usize> = Vec::new();
            for (idx, obs) in self.exit_pending.iter().enumerate() {
                if i - obs.snapshot_candle >= ctx.exit_horizon {
                    resolved_exit_indices.push(idx);
                }
            }
            for &idx in resolved_exit_indices.iter().rev() {
                let obs = self.exit_pending.remove(idx);
                if let Some(pos) = self.positions.iter().find(|p| p.id == obs.pos_id) {
                    let current_pnl = pos.return_pct(quote_price);
                    let improved = current_pnl > obs.snapshot_pnl;
                    let label = if improved { self.exit_hold } else { self.exit_exit };
                    self.exit_journal.observe(&obs.thought, label, 1.0);
                }
            }
        }

        // Pass 1: observe exit expert + tick positions, collect exit signals.
        let mut exit_signals: Vec<(usize, PositionExit, f64, bool)> = Vec::new();
        for (pi, pos) in self.positions.iter_mut().enumerate() {
            if pos.phase == PositionPhase::Closed { continue; }

            // rune:forge(bare-type) — is_buy is local, derived from asset comparison,
            // consumed within the same block. Direction enum adds ceremony without safety here.
            let is_buy = pos.source_asset == *ctx.base_asset;
            let current_rate = if is_buy { quote_price } else { 1.0 / quote_price };
            if pos.candles_held > 0 && pos.candles_held % ctx.exit_observe_interval == 0 {
                let pnl_frac = pos.return_pct(current_rate);
                let exit_thought = encode_exit_thought(pos, pnl_frac, current_rate,
                    ctx.exit_atoms, ctx.exit_scalar, candle.atr_r, is_buy);
                self.exit_pending.push(ExitObservation {
                    thought: exit_thought,
                    pos_id: pos.id,
                    snapshot_pnl: pnl_frac,
                    snapshot_candle: i,
                });
            }

            if let Some(exit) = pos.tick(current_rate, TrailFactor(ctx.k_trail)) {
                exit_signals.push((pi, exit, current_rate, is_buy));
            }
        }

        // Pass 2: settle each exit — treasury, accounting, logging.
        // Symmetric: release target, swap target→source, update accounting.
        for &(pos_idx, ref exit, current_rate, is_buy) in &exit_signals {
            let pos = &mut self.positions[pos_idx];

            // Determine how much target to sell and what phase to enter.
            // Take profit: reclaim source principal. Runner: ride the rest.
            let (sell_target, next_phase) = match exit {
                PositionExit::TakeProfit if pos.phase == PositionPhase::Active => {
                    // Reclaim enough target to cover source principal + fees + 1% profit.
                    // Convert source amount to target units: source / rate = target.
                    let reclaim_source = pos.source_amount + pos.total_fees + pos.source_amount * 0.01;
                    let reclaim_target = (reclaim_source / current_rate) / (1.0 - fee_rate);
                    if reclaim_target < pos.target_held {
                        (reclaim_target, PositionPhase::Runner)
                    } else {
                        (pos.target_held, PositionPhase::Closed)
                    }
                }
                _ => (pos.target_held, PositionPhase::Closed),
            };

            // Settlement: release target → swap target→source → accounting
            if sell_target > 0.0 {
                treasury.release(&pos.target_asset, sell_target);
                // Swap rate = from_per_to. Swapping target→source: rate = target_per_source = 1/rate.
                let exit_rate = crate::treasury::Rate(1.0 / current_rate);
                let (sold, received) = treasury.swap(
                    &pos.target_asset, &pos.source_asset,
                    sell_target, exit_rate, fee_rate,
                );
                pos.target_held -= sold;
                pos.source_reclaimed += received;
                pos.total_fees += sold * exit_rate.0 * fee_rate;
            }
            pos.phase = next_phase;
            self.position_swaps += 1;

            let ret = pos.return_pct(current_rate);
            if next_phase == PositionPhase::Runner || ret > 0.0 {
                self.position_wins += 1;
            }
            if next_phase == PositionPhase::Closed {
                self.last_exit_price = quote_price;
                self.last_exit_atr = candle.atr_r;
            }
            let direction = if is_buy { Direction::Long } else { Direction::Short };
            let exit_type = match (exit, pos.phase) {
                (PositionExit::TakeProfit, PositionPhase::Runner) => "RunnerTP",
                (PositionExit::TakeProfit, _) => "PartialProfit",
                (PositionExit::StopLoss, _) => "StopLoss",
            };
            self.pending_logs.push(LogEntry::PositionExit {
                step: self.log_step,
                candle_idx: i as i64,
                timestamp: candle_ts.clone(),
                direction,
                entry_price: pos.entry_rate,
                exit_price: current_rate,
                gross_return_pct: ret * 100.0,
                position_usd: pos.source_amount,
                swap_fee_pct: fee_rate * 100.0,
                horizon_candles: pos.candles_held as i64,
                won: (ret > 0.0) as i32,
                exit_reason: exit_type.to_string(),
            });
        }
        // Remove closed positions
        self.positions.retain(|p| p.phase != PositionPhase::Closed);

        // ── Open new position: manager BUY in proven band ────────
        let in_proven_band = meta_conviction >= self.manager_proven_band.0
            && meta_conviction < self.manager_proven_band.1;
        // Cooldown: has the market moved enough since last exit?
        // Not a timer — a condition. The market tells us when it's ready.
        let market_moved = if self.last_exit_price > 0.0 {
            let move_since_exit = (quote_price - self.last_exit_price).abs() / self.last_exit_price;
            move_since_exit > ctx.k_stop * self.last_exit_atr
        } else {
            true // no prior exit — ready
        };
        // ── Open position: BUY or SELL in proven band ──────────────
        // One path for both directions. The direction determines which
        // asset to deploy. Everything else is the same.
        // rune:scry(aspirational) — risk.wat specifies conviction-based risk rejection: the risk
        // manager predicts Healthy/Unhealthy and modulates sizing by risk conviction. Code uses a
        // simple threshold (cached_risk_mult > 0.3) — no risk discriminant, no risk conviction.
        let risk_allows = risk_mult > RISK_GATE_THRESHOLD;
        let should_open = ctx.asset_mode == AssetMode::Hold
            && portfolio.phase != Phase::Observe
            && self.manager_curve_valid && in_proven_band && market_moved && risk_allows
            && (meta_dir == Some(mgr_buy) || meta_dir == Some(mgr_sell));

        if should_open {
            let expected_move = candle.atr_r * 6.0;
            if expected_move > 2.0 * fee_rate {
                let band_edge: f64 = MAX_BASE_POSITION;
                let frac = ((band_edge / 2.0) * risk_mult).min(ctx.max_single_position);
                let dir_label = meta_dir.unwrap();
                // rune:forge(bare-type) — same pattern as position loop; local, derived, consumed here.
                let is_buy = dir_label == mgr_buy;

                // Source/target: Buy sells USDC for WBTC, Sell sells WBTC for USDC.
                // rune:forge(bare-type) — Rate wraps at treasury boundary; intermediate arithmetic clearer as f64.
                // Rate = source_per_target. For Buy: USDC/WBTC = price. For Sell: WBTC/USDC = 1/price.
                let (source_asset, target_asset, source_avail, rate) = if is_buy {
                    (ctx.base_asset.clone(), ctx.quote_asset.clone(),
                     treasury.balance(ctx.base_asset), quote_price)
                } else {
                    (ctx.quote_asset.clone(), ctx.base_asset.clone(),
                     treasury.balance(ctx.quote_asset), 1.0 / quote_price)
                };
                let deploy_amount = source_avail * frac;
                // Value in USDC for minimum position check
                let usd_value = if is_buy { deploy_amount } else { deploy_amount * quote_price };

                if usd_value > 10.0 {
                    let (spent, received) = treasury.swap(
                        &source_asset, &target_asset, deploy_amount,
                        crate::treasury::Rate(rate), fee_rate);

                    // Symmetric claim: lock the received target in deployed.
                    treasury.claim(&target_asset, received);

                    let entry_fee = usd_value * fee_rate;
                    let pos = ManagedPosition::new(PositionEntry {
                        id: self.next_position_id,
                        candle_idx: i,
                        source_asset: source_asset.clone(),
                        target_asset: target_asset.clone(),
                        source_amount: spent,
                        target_received: received,
                        entry_rate: rate,
                        entry_atr: candle.atr_r,
                        entry_fee,
                        k_stop: ctx.k_stop,
                        k_tp: ctx.k_tp,
                    });
                    self.next_position_id += 1;
                    self.position_swaps += 1;
                    let direction = if is_buy { Direction::Long } else { Direction::Short };
                    self.pending_logs.push(LogEntry::PositionOpen {
                        step: self.log_step,
                        candle_idx: i as i64,
                        timestamp: candle_ts.clone(),
                        direction,
                        entry_price: quote_price,
                        position_usd: usd_value,
                        swap_fee_pct: fee_rate * 100.0,
                    });
                    self.positions.push(pos);
                }
            }
        }

        // Position sizing: Kelly from the curve × drawdown cap.
        // The curve handles selectivity. The drawdown cap handles survival.
        // Nothing else. No graduated gate, no stability gate, no phase gate.
        // rune:scry(evolved) — enterprise.wat evaluates risk every candle; Rust caches at recalib
        // intervals for efficiency. Functionally equivalent given the gate conditions.

        // The treasury doesn't move until the portfolio has proven edge.
        // Two requirements:
        // 1. Past the observe period (enough data to form a discriminant)
        // 2. Curve is valid (the conviction-accuracy relationship exists)
        // Before both are met, predictions are hypothetical — recorded in the
        // ledger but the treasury withholds capital.
        let portfolio_proven = portfolio.phase != Phase::Observe && self.manager_curve_valid;
        let position_frac = if meta_dir.is_some()
            && portfolio_proven
            && (self.conviction_threshold <= 0.0 || meta_conviction >= self.conviction_threshold)
        {
            let mt = if ctx.atr_multiplier > 0.0 {
                ctx.atr_multiplier * candle.atr_r
            } else { ctx.move_threshold };

            match ctx.sizing {
                SizingMode::Kelly => {
                    // Fast path: evaluate cached curve params. No sorting.
                    let kelly_result = if self.kelly_curve_valid && self.cached_curve_b > 0.0 {
                        let win_rate = curve_win_rate(meta_conviction, self.cached_curve_a, self.cached_curve_b);
                        half_kelly_position(win_rate, mt)
                    } else { None };
                    match kelly_result {
                        Some(frac) => {
                            let frac = frac.min(ctx.max_single_position);
                            let drawdown_pct = if *peak_equity > 0.0 {
                                (*peak_equity - treasury_equity) / *peak_equity
                            } else { 0.0 };
                            let dd_room = (ctx.max_drawdown - drawdown_pct).max(0.0);
                            let cap = (dd_room / (4.0 * mt)).min(1.0);
                            let sized = frac.min(cap) * risk_mult;
                            // NEVER zero. Always learn. Minimum 1% position.
                            // The wat machine never quits — it gets quiet.
                            Some(sized.max(MIN_BET))
                        }
                        None => None
                    }
                }
                _ => {
                    // Legacy sizing with flip zone gate
                    if self.conviction_threshold > 0.0 && meta_conviction < self.conviction_threshold {
                        None
                    } else {
                        portfolio.position_frac(meta_conviction, ctx.min_conviction, self.conviction_threshold)
                    }
                }
            }
        } else { None };

        // Pending entries are for LEARNING, not for treasury. They record the
        // prediction so observers and manager can resolve against the outcome.
        // The treasury moves through ManagedPosition lifecycle (swap/claim/release),
        // NOT through pending entry resolution. No double-spending.
        self.pending.push_back(Pending {
            candle_idx:    i,
            tht_vec,
            tht_pred,
            meta_dir,
            high_conviction:   self.conviction_threshold > 0.0 && meta_conviction >= self.conviction_threshold,
            meta_conviction,
            position_frac,
            observer_vecs,
            observer_preds,
            mgr_thought:   stored_mgr_thought,
            crossing:      None,
            entry_price:       candle.close,
            entry_ts:          candle_ts.clone(),
            entry_atr:         candle.atr_r,
            max_favorable:     0.0,
            max_adverse:       0.0,
            exit_reason:       None,
            exit_pct:          0.0,
        });

        // Candle snapshot: every indicator value at entry time.
        // Keyed by candle_idx. Join with trade_ledger.candle_idx → trade_facts.step
        // to verify facts match the indicator state that produced them.
        self.pending_logs.push(LogEntry::CandleSnapshot {
            candle_idx: i as i64,
            ts: candle_ts.clone(),
            open: candle.open, high: candle.high, low: candle.low,
            close: candle.close, volume: candle.volume,
            sma20: candle.sma20, sma50: candle.sma50, sma200: candle.sma200,
            bb_upper: candle.bb_upper, bb_lower: candle.bb_lower,
            bb_width: candle.bb_width, bb_pos: candle.bb_pos,
            rsi: candle.rsi,
            macd_line: candle.macd_line, macd_signal: candle.macd_signal,
            macd_hist: candle.macd_hist,
            dmi_plus: candle.dmi_plus, dmi_minus: candle.dmi_minus, adx: candle.adx,
            atr: candle.atr, atr_r: candle.atr_r,
            stoch_k: candle.stoch_k, stoch_d: candle.stoch_d,
            williams_r: candle.williams_r, cci: candle.cci, mfi: candle.mfi,
            roc_1: candle.roc_1, roc_3: candle.roc_3,
            roc_6: candle.roc_6, roc_12: candle.roc_12,
            obv_slope_12: candle.obv_slope_12,
            volume_sma_20: candle.volume_sma_20, vol_accel: candle.vol_accel,
            tf_1h_close: candle.tf_1h_close, tf_1h_high: candle.tf_1h_high,
            tf_1h_low: candle.tf_1h_low, tf_1h_ret: candle.tf_1h_ret,
            tf_1h_body: candle.tf_1h_body,
            tf_4h_close: candle.tf_4h_close, tf_4h_high: candle.tf_4h_high,
            tf_4h_low: candle.tf_4h_low, tf_4h_ret: candle.tf_4h_ret,
            tf_4h_body: candle.tf_4h_body,
            tenkan_sen: candle.tenkan_sen, kijun_sen: candle.kijun_sen,
            senkou_span_a: candle.senkou_span_a, senkou_span_b: candle.senkou_span_b,
            cloud_top: candle.cloud_top, cloud_bottom: candle.cloud_bottom,
            kelt_upper: candle.kelt_upper, kelt_lower: candle.kelt_lower,
            kelt_pos: candle.kelt_pos, squeeze: candle.squeeze as i32,
            range_pos_12: candle.range_pos_12, range_pos_24: candle.range_pos_24,
            range_pos_48: candle.range_pos_48,
            trend_consistency_6: candle.trend_consistency_6,
            trend_consistency_12: candle.trend_consistency_12,
            trend_consistency_24: candle.trend_consistency_24,
            atr_roc_6: candle.atr_roc_6, atr_roc_12: candle.atr_roc_12,
            hour: candle.hour, day_of_week: candle.day_of_week,
        });

        // pfor-each: each observer's journal is independent. Manager decays separately.
        self.manager_journal.decay(self.adaptive_decay);
        {
            use rayon::prelude::*;
            let adaptive = self.adaptive_decay;
            let fixed = ctx.decay;
            self.observers.par_iter_mut().enumerate().for_each(|(obs_idx, observer)| {
                let d = if obs_idx == GENERALIST_IDX { adaptive } else { fixed };
                observer.journal.decay(d);
            });
        }

        // ── Event-driven learning ─────────────────────────────────────
        // Snapshot recalib counts before scanning so we can detect if
        // any recalibration fired during this candle's learning.
        let tht_recalib_before = self.observers[GENERALIST_IDX].journal.recalib_count();
        let tht_buy = self.tht_buy();
        let tht_sell = self.tht_sell();

        let current_price = candle.close;
        for entry in self.pending.iter_mut() {
            let entry_price = entry.entry_price;
            let pct         = (current_price - entry_price) / entry_price;
            let abs_pct     = pct.abs();

            // Track directional excursion relative to predicted direction.
            let directional_pct = if entry.meta_dir == Some(tht_buy) {
                pct
            } else if entry.meta_dir == Some(tht_sell) {
                -pct
            } else {
                pct.abs() // no direction → track absolute
            };
            if directional_pct > entry.max_favorable {
                entry.max_favorable = directional_pct;
            }
            if directional_pct < entry.max_adverse {
                entry.max_adverse = directional_pct; // most negative = worst drawdown
            }

            // Learn only on the first threshold crossing per pending entry.
            if entry.crossing.is_none() {
                let thresh = if ctx.atr_multiplier > 0.0 {
                    ctx.atr_multiplier * entry.entry_atr
                } else {
                    ctx.move_threshold
                };
                let outcome = if pct > thresh       { Some(tht_buy)  }
                              else if pct < -thresh { Some(tht_sell) }
                              else                  { None };

                if let Some(o) = outcome {
                    let signal_wt = signal_weight(abs_pct, &mut self.move_sum, &mut self.move_count);
                    // pfor-each: each observer resolves independently (disjoint journals).
                    // Logs collected in parallel, merged after.
                    let obs_logs: Vec<Option<(String, f64, String, i32)>> = {
                        use rayon::prelude::*;
                        self.observers.par_iter_mut().enumerate().map(|(ei, obs)| {
                            if ei < entry.observer_vecs.len() {
                                if let Some(log) = obs.resolve(
                                    &entry.observer_vecs[ei], &entry.observer_preds[ei], o, signal_wt,
                                    ctx.conviction_quantile, ctx.conviction_window,
                                ) {
                                    return Some((
                                        log.name.as_str().to_string(),
                                        log.conviction,
                                        obs.journal.label_name(log.direction).unwrap_or("?").to_string(),
                                        log.correct as i32,
                                    ));
                                }
                            }
                            None
                        }).collect()
                    };
                    if ctx.diagnostics {
                        for log in obs_logs.into_iter().flatten() {
                            self.pending_logs.push(LogEntry::ObserverLog {
                                step: self.log_step,
                                observer: log.0,
                                conviction: log.1,
                                direction: log.2,
                                correct: log.3,
                            });
                        }
                    }
                    entry.crossing = Some(CrossingSnapshot {
                        label:   o,
                        pct,
                        candles: i - entry.candle_idx,
                        ts:      candle_ts.clone(),
                        price:   candle.close,
                    });
                }
            }
        }

        // Recalibration: four independent concerns, one trigger.
        if self.observers[GENERALIST_IDX].journal.recalib_count() != tht_recalib_before {
            self.on_recalibration(&candle, &panel_state, tht_buy, tht_sell, ctx);
        }

        // ── Resolve entries: horizon expiry ──────────────────────────
        // ManagedPosition owns trade lifecycle (stop/TP).
        // Pending entries resolve at safety max (10× horizon) for learning.
        let max_pending_age = ctx.horizon * 10;
        let mut resolved_indices: Vec<usize> = Vec::new();
        for (qi, entry) in self.pending.iter().enumerate() {
            let age = i - entry.candle_idx;
            if age >= max_pending_age {
                resolved_indices.push(qi);
            }
        }
        // Drain in reverse order to preserve indices.
        let mut resolved_entries: Vec<Pending> = Vec::new();
        for &qi in resolved_indices.iter().rev() {
            // VecDeque::remove returns Option, but we just found these indices
            if let Some(entry) = self.pending.remove(qi) {
                resolved_entries.push(entry);
            }
        }
        resolved_entries.reverse(); // restore chronological order

        for mut entry in resolved_entries {
            // Pending entries always resolve at horizon — ManagedPosition owns trade lifecycle.
            entry.exit_reason = Some(ExitReason::HorizonExpiry);
            entry.exit_pct = (current_price - entry.entry_price) / entry.entry_price;
            let final_out: Option<Label> = entry.crossing.as_ref().map(|c| c.label);
            if final_out.is_none() {
                self.noise_count += 1;
            } else {
                self.labeled_count += 1;
            }

            // Rolling accuracy: generalist tracks via observer resolved deque.
            if let Some(_outcome) = final_out {
                // ── Manager learns from ALL non-Noise outcomes ──────────
                self.learn_manager_from_entry(&entry, current_price, ctx.conviction_window);
            }

            // Every prediction goes to the ledger — hypothetical or real.
            // Traders predict on paper. The treasury decides whether to act.
            // The paper trail is how traders prove themselves.
            if let Some(dir) = entry.meta_dir {
                let frac = entry.position_frac.unwrap_or(0.0);
                let is_live = frac > 0.0; // treasury committed capital

                // ── Accounting: pure computation ─────────────────────
                let pnl = TradePnl::compute(
                    entry.exit_pct, dir == mgr_buy,
                    ctx.swap_fee + ctx.slippage,
                    is_live, treasury_equity, frac,
                );

                // Portfolio tracks win/loss for phase transitions — every resolved prediction,
                // not just ones with capital. Treasury is NOT touched here — capital moves
                // through ManagedPosition lifecycle only.
                {
                    let trade_dir = if dir == mgr_buy { Direction::Long } else { Direction::Short };
                    portfolio.record_trade(entry.exit_pct, frac, trade_dir,
                                        ctx.swap_fee, ctx.slippage);
                }

                // ── Ledger: ALWAYS records. Paper trail for all. ─────
                {
                    let cx = entry.crossing.as_ref();
                    let exit_ts = cx.map(|c| c.ts.clone());
                    let exit_price = cx.map(|c| c.price)
                        .unwrap_or(candle.close);
                    let crossing_elapsed = cx.map(|c| c.candles as i64);
                    self.pending_logs.push(LogEntry::TradeLedger {
                        step: self.log_step,
                        candle_idx: entry.candle_idx as i64,
                        timestamp: entry.entry_ts.clone(),
                        exit_candle_idx: cx.map(|c| (entry.candle_idx + c.candles) as i64),
                        exit_timestamp: exit_ts,
                        direction: self.manager_journal.label_name(dir).unwrap_or("?").to_string(),
                        conviction: entry.meta_conviction,
                        high_conviction: entry.high_conviction as i32,
                        entry_price: entry.entry_price,
                        exit_price,
                        position_frac: frac,
                        position_usd: pnl.pos_usd,
                        gross_return_pct: pnl.gross_ret * 100.0,
                        swap_fee_pct: pnl.entry_cost_frac * 100.0,
                        slippage_pct: pnl.exit_cost_frac * 100.0,
                        net_return_pct: pnl.net_ret * 100.0,
                        pnl_usd: pnl.trade_pnl,
                        equity_after: treasury_equity,
                        max_favorable_pct: entry.max_favorable * 100.0,
                        max_adverse_pct: entry.max_adverse * 100.0,
                        crossing_candles: crossing_elapsed,
                        horizon_candles: (i - entry.candle_idx) as i64,
                        outcome: final_out.map(|l| self.observers[GENERALIST_IDX].journal.label_name(l).unwrap_or("?").to_string()).unwrap_or_else(|| "Noise".to_string()),
                        won: (pnl.net_ret > 0.0) as i32,
                        exit_reason: match entry.exit_reason {
                            Some(ExitReason::TrailingStop) => "TrailingStop",
                            Some(ExitReason::TakeProfit) => "TakeProfit",
                            Some(ExitReason::HorizonExpiry) => "HorizonExpiry",
                            None => "HorizonExpiry",
                        }.to_string(),
                    });
                }

                // Log which facts were active in this thought vector.
                // Decode: cosine each codebook entry against the thought, log positives.
                for (label, vec) in ctx.codebook_labels.iter().zip(ctx.codebook_vecs.iter()) {
                    let cos = holon::Similarity::cosine(&entry.tht_vec, vec);
                    if cos.abs() > 0.05 {
                        self.pending_logs.push(LogEntry::TradeFact {
                            step: self.log_step,
                            fact_label: label.clone(),
                        });
                    }
                }

                // Panel tracking (all predictions, not just live)
                self.panel_recalib_total += 1;
                if final_out == Some(dir) { self.panel_recalib_wins += 1; }

                // ── Risk/diagnostics: only for live trades ───────────
                if is_live {
                    self.update_risk_from_trade(&entry, dir, final_out, treasury_equity, portfolio, *peak_equity, ctx);
                }
            } // if let Some(dir)

            self.log_candle(&entry, final_out, treasury_equity, treasury, ctx);
            self.log_step += 1;
            *db_batch += 1;
            if *db_batch >= 5_000 {
                self.pending_logs.push(LogEntry::BatchCommit);
                *db_batch = 0;
            }

            portfolio.tick_observe();
        }

        // ── Progress line ─────────────────────────────────────────────
        if self.encode_count % ctx.progress_every == 0 {
            let elapsed = ctx.t_start.elapsed().as_secs_f64();
            let rate    = self.encode_count as f64 / elapsed;
            let eta     = (ctx.loop_count - self.encode_count) as f64 / rate;
            let gen_resolved = &self.observers[GENERALIST_IDX].resolved;
            let tht_acc = if gen_resolved.is_empty() { 0.0 }
                else { gen_resolved.iter().filter(|(_, c)| *c).count() as f64 / gen_resolved.len() as f64 * 100.0 };
            let ret = (treasury_equity - ctx.initial_equity) / ctx.initial_equity * 100.0;
            let atr_now = candle.atr_r;
            let exit_info = format!(" | ATR={:.2}% sl={:.2}% tp={:.2}% tr={:.2}% open={}",
                atr_now * 100.0,
                ctx.k_stop * atr_now * 100.0,
                ctx.k_tp * atr_now * 100.0,
                ctx.k_trail * atr_now * 100.0,
                self.positions.len());
            eprintln!(
                "  {}/{} ({:.0}/s ETA {:.0}s) | {} | {} | tht={:.1}% | trades={} win={:.1}% | ${:.0} ({:+.1}%) | thresh={:.3} {}{}",
                self.encode_count, ctx.loop_count, rate, eta,
                &candle.ts[..10],
                portfolio.phase,
                tht_acc,
                portfolio.trades_taken, portfolio.win_rate(),
                treasury_equity, ret,
                self.conviction_threshold,
                if !self.manager_curve_valid { "CALIBRATING" }
                else if self.panel_engram.n() >= 10
                    && self.panel_engram.residual(&panel_state) < self.panel_engram.threshold() { "ENGRAM" }
                else if self.in_adaptation { "ADAPT" }
                else { "STABLE" },
                exit_info,
            );
            if ctx.asset_mode == AssetMode::Hold {
                let proven: Vec<&str> = self.observers.iter()
                    .filter(|e| e.curve_valid).map(|e| e.lens.as_str()).collect();
                // generalist is in the observer list, no separate check needed
                let proven_str = if proven.is_empty() { "none".to_string() }
                    else { proven.join(",") };
                let band_str = if self.manager_curve_valid {
                    format!(" band=[{:.3},{:.3}]", self.manager_proven_band.0, self.manager_proven_band.1)
                } else { " band=none".to_string() };
                // rune:temper(rare-path) — diagnostics display, not hot path
                let base_units = treasury.balance(ctx.base_asset) + treasury.deployed(ctx.base_asset);
                let quote_units = treasury.balance(ctx.quote_asset) + treasury.deployed(ctx.quote_asset);
                let base_usd = base_units * prices.get(ctx.base_asset).copied().unwrap_or(1.0);
                let quote_usd = quote_units * prices.get(ctx.quote_asset).copied().unwrap_or(1.0);
                eprintln!("    {} {:.2} (${:.0}) | {} {:.6} (${:.0}) | pos={} swaps={} wins={} | proven=[{}]{}",
                    ctx.base_asset, base_units, base_usd,
                    ctx.quote_asset, quote_units, quote_usd,
                    self.positions.len(), self.position_swaps, self.position_wins, proven_str, band_str);
            }
        }
    }

    // ─── Pure phases (extractable, pmap-ready) ──────────────────────────

    /// Encode all observers from the candle window. Pure: reads window + samplers,
    /// produces vectors. Each observer is independent — future pmap candidate.
    /// pmap: encode all observers in parallel. Each observer is independent —
    /// reads its own window slice, encodes through its own lens. Pure function.
    fn encode_observers(
        observers: &[Observer],
        window: &[Candle],
        encode_count: usize,
        ctx: &CandleContext,
    ) -> Vec<Vector> {
        use rayon::prelude::*;
        observers.par_iter().enumerate().map(|(ei, obs)| {
            let w = obs.window_sampler.sample(encode_count).min(window.len());
            let start = window.len().saturating_sub(w);
            let slice = &window[start..];
            if slice.is_empty() {
                holon::Vector::zeros(ctx.dims)
            } else {
                ctx.thought_encoder.encode_thought(slice, ctx.vm, crate::market::OBSERVER_LENSES[ei]).thought
            }
        }).collect()
    }

    // ─── Recalibration ──────────────────────────────────────────────────

    /// Four independent concerns triggered by a journal recalibration:
    /// 1. Kelly curve fit from resolved predictions
    /// 2. Manager proven band discovery
    /// 3. Panel engram feed (if recent accuracy was good)
    /// 4. Recalib log + discriminant decode
    fn on_recalibration(
        &mut self,
        candle: &Candle,
        panel_state: &[f64],
        tht_buy: Label,
        tht_sell: Label,
        ctx: &CandleContext,
    ) {
        // 1. Kelly curve fit
        if let Some((_, a, b)) = kelly_frac(0.15, &self.resolved_preds,
            if ctx.atr_multiplier > 0.0 { ctx.atr_multiplier * candle.atr_r } else { ctx.move_threshold }) {
            self.cached_curve_a = a;
            self.cached_curve_b = b;
            self.kelly_curve_valid = true;
        }

        // 2. Manager proven band
        if let Some((lo, hi, _acc)) = find_proven_band(&self.manager_resolved, ctx.dims) {
            self.manager_curve_valid = true;
            self.manager_proven_band = (lo, hi);
        } else {
            self.manager_curve_valid = false;
            self.manager_proven_band = (0.0, 0.0);
        }

        // 3. Panel engram feed
        if self.panel_recalib_total >= crate::state::PANEL_ENGRAM_MIN_TOTAL {
            let acc = self.panel_recalib_wins as f64 / self.panel_recalib_total as f64;
            if acc > crate::state::PANEL_ENGRAM_MIN_ACC {
                self.panel_engram.update(&panel_state);
            }
        }
        self.panel_recalib_wins = 0;
        self.panel_recalib_total = 0;

        // 4. Recalib log — ALL observers, not just generalist
        for obs in &self.observers {
            let health = obs.journal.prototype_health().unwrap_or((0.0, 0.0, 0.0));
            self.pending_logs.push(LogEntry::RecalibLog {
                step: self.encode_count as i64,
                journal: obs.lens.as_str().to_string(),
                cos_raw: obs.journal.last_cos_raw(),
                disc_strength: obs.journal.last_disc_strength(),
                buy_count: obs.journal.label_count(tht_buy) as i64,
                sell_count: obs.journal.label_count(tht_sell) as i64,
                buy_norm: health.0,
                sell_norm: health.1,
                proto_cosine: health.2,
            });
        }

        // Discriminant decode against fact codebook
        // rune:temper(rare-path) — recalibration frequency, ~200 candle intervals
        if let Some(disc) = self.observers[GENERALIST_IDX].journal.discriminant(tht_buy) {
            let disc_vec = Vector::from_f64(disc);
            let mut decoded: Vec<(String, f64)> = ctx.codebook_vecs.iter().zip(ctx.codebook_labels.iter())
                .map(|(v, l)| (l.clone(), holon::Similarity::cosine(&disc_vec, v)))
                .collect();
            decoded.sort_by(|a, b| b.1.abs().partial_cmp(&a.1.abs()).unwrap());
            for (rank, (label, cos)) in decoded.iter().take(20).enumerate() {
                self.pending_logs.push(LogEntry::DiscDecode {
                    step: self.encode_count as i64,
                    journal: "thought".to_string(),
                    rank: (rank + 1) as i64,
                    fact_label: label.clone(),
                    cosine: *cos,
                });
            }
        }
    }

    // ─── Resolution helpers ───────────────────────────────────────────────

    /// Manager learns direction from expert intensity patterns.
    /// Called once per non-Noise resolved entry.
    fn learn_manager_from_entry(
        &mut self,
        entry: &Pending,
        current_price: f64,
        conviction_window: usize,
    ) {
        // Skip if observers have no majority — nothing to learn from a tie.
        let buy_label = self.tht_buy();
        let (buys, sells) = entry.observer_preds.iter().fold((0, 0), |(b, s), ep| {
            if ep.direction == Some(buy_label) { (b + 1, s) }
            else if ep.direction.is_some() { (b, s + 1) }
            else { (b, s) }
        });
        if buys == sells { return; }

        // Manager learns raw price direction from intensity patterns.
        let price_change = (current_price - entry.entry_price)
            / entry.entry_price;
        let mgr_label = if price_change > 0.0 { self.manager_buy } else { self.manager_sell };

        // Learn from the SAME thought the manager predicted with.
        // Stored at prediction time, delta-enriched. One encoding path.
        if let Some(ref mgr_vec) = entry.mgr_thought {
            self.manager_journal.observe(mgr_vec, mgr_label, 1.0);
        }

        // Track for proof gate: did the manager predict the right direction?
        let mgr_correct = if let Some(mgr_dir) = entry.meta_dir {
            mgr_dir == mgr_label
        } else {
            false
        };
        // Two deques, same data, different windows — intentional.
        // mgr_resolved (cap 5000): long memory for band scan (find_proven_band).
        // resolved_preds (cap conviction_window): short memory for Kelly curve + conviction threshold.
        self.manager_resolved.push_back((entry.meta_conviction, mgr_correct));
        if self.manager_resolved.len() > 5000 { self.manager_resolved.pop_front(); }
        self.resolved_preds.push_back((entry.meta_conviction, mgr_correct));
        if self.resolved_preds.len() > conviction_window {
            self.resolved_preds.pop_front();
        }
    }

    /// Log a resolved entry to candle_log. Called from on_candle resolution
    /// and from enterprise.rs post-loop drain. One LogEntry, one definition.
    pub fn log_candle(
        &mut self,
        entry: &Pending,
        final_out: Option<Label>,
        treasury_equity: f64,
        treasury: &Treasury,
        ctx: &CandleContext,
    ) {
        self.pending_logs.push(LogEntry::CandleLog {
            step: self.log_step,
            candle_idx: entry.candle_idx as i64,
            timestamp: entry.entry_ts.clone(),
            tht_cos: entry.tht_pred.raw_cos,
            tht_conviction: entry.tht_pred.conviction,
            tht_pred: entry.tht_pred.direction.and_then(|d| self.observers[GENERALIST_IDX].journal.label_name(d).map(|s| s.to_string())),
            meta_pred: entry.meta_dir.and_then(|d| self.manager_journal.label_name(d).map(|s| s.to_string())),
            meta_conviction: entry.meta_conviction,
            actual: final_out.and_then(|l| self.observers[GENERALIST_IDX].journal.label_name(l).map(|s| s.to_string())).unwrap_or_else(|| "Noise".to_string()),
            traded: entry.position_frac.is_some() as i32,
            position_frac: entry.position_frac,
            equity: treasury_equity,
            outcome_pct: entry.crossing.as_ref().map(|c| c.pct).unwrap_or(0.0),
            usdc_bal: treasury.balance(ctx.base_asset),
            wbtc_bal: treasury.balance(ctx.quote_asset),
            usdc_deployed: treasury.deployed(ctx.base_asset),
            wbtc_deployed: treasury.deployed(ctx.quote_asset),
        });
    }

    /// Risk diagnostics + adaptive decay for a resolved live trade.
    fn update_risk_from_trade(
        &mut self,
        entry: &Pending,
        dir: Label,
        final_out: Option<Label>,
        treasury_equity: f64,
        portfolio: &Portfolio,
        peak_equity: f64,
        ctx: &CandleContext,
    ) {
        let drawdown_pct = if peak_equity > 0.0 {
            (peak_equity - treasury_equity) / peak_equity * 100.0
        } else { 0.0 };
        let streak_val = portfolio.streak();
        let streak_len = streak_val.abs() as i32;
        let streak_dir = if streak_val >= 0.0 { "winning" } else { "losing" };
        let recent_acc = portfolio.rolling_acc();
        let eq_pct = (treasury_equity - ctx.initial_equity) / ctx.initial_equity * 100.0;
        let won = (final_out == Some(dir)) as i32;
        if ctx.diagnostics { self.pending_logs.push(LogEntry::RiskLog {
            step: self.log_step,
            drawdown_pct,
            streak_len,
            streak_dir: streak_dir.to_string(),
            recent_acc,
            equity_pct: eq_pct,
            won,
        }); }

        // Adaptive decay state machine
        if entry.high_conviction {
            let won = final_out == Some(dir);
            self.highconv_wins.push_back(won);
            if self.highconv_wins.len() > ctx.highconv_rolling_cap {
                self.highconv_wins.pop_front();
            }
            if self.highconv_wins.len() >= 30 {
                let wr = self.highconv_wins.iter().filter(|&&w| w).count() as f64
                       / self.highconv_wins.len() as f64;
                if !self.in_adaptation && wr < 0.50 {
                    self.in_adaptation = true;
                    self.adaptive_decay = ctx.decay_adapting;
                } else if self.in_adaptation && wr > 0.55 {
                    self.in_adaptation = false;
                    self.adaptive_decay = ctx.decay_stable;
                }
            }
        }

        // Store thought vectors for engram analysis.
        if entry.high_conviction && ctx.diagnostics {
            let won = (final_out == Some(dir)) as i32;
            let tht_bytes: Vec<u8> = entry.tht_vec.data().iter()
                .map(|&v| v as u8).collect();
            self.pending_logs.push(LogEntry::TradeVector {
                step: self.log_step,
                won,
                tht_data: tht_bytes,
            });
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::indicators::RawCandle;
    use crate::market::manager::{ManagerAtoms, noise_floor};
    use crate::market::exit::ExitAtoms;
    use crate::market::OBSERVER_LENSES;
    use crate::thought::{ThoughtVocab, ThoughtEncoder};
    use crate::state::{AssetMode, CandleContext, ConvictionMode, SizingMode};
    use holon::{ScalarEncoder, VectorManager, Vector};

    const TEST_DIMS: usize = 64;

    fn make_raw_candle(i: usize) -> RawCandle {
        let base = 50000.0 + (i as f64) * 10.0;
        RawCandle {
            ts: format!("2024-01-01T{:02}:00:00Z", i % 24),
            open: base,
            high: base + 50.0,
            low: base - 50.0,
            close: base + 20.0,
            volume: 100.0 + (i as f64),
        }
    }

    fn make_desk() -> Desk {
        let base = Asset::new("USDC");
        let target = Asset::new("WBTC");
        Desk::new(DeskConfig {
            name: "test-desk".to_string(),
            source_asset: base,
            target_asset: target,
            dims: TEST_DIMS,
            recalib_interval: 200,
            window: 100,
            max_window_size: 2016,
            decay: 0.999,
        })
    }

    struct TestInfra {
        vm: VectorManager,
        thought_encoder: ThoughtEncoder,
        mgr_atoms: ManagerAtoms,
        mgr_scalar: ScalarEncoder,
        exit_scalar: ScalarEncoder,
        exit_atoms: ExitAtoms,
        risk_scalar: ScalarEncoder,
        risk_atoms: crate::risk::RiskAtoms,
        risk_mgr_atoms: crate::risk::manager::RiskManagerAtoms,
        observer_atoms: Vec<Vector>,
        generalist_atom: Vector,
        codebook_labels: Vec<String>,
        codebook_vecs: Vec<Vector>,
    }

    impl TestInfra {
        fn new() -> Self {
            let vm = VectorManager::new(TEST_DIMS);
            let vocab = ThoughtVocab::new(&vm);
            let thought_encoder = ThoughtEncoder::new(vocab);
            let mgr_atoms = ManagerAtoms::new(&vm);
            let mgr_scalar = ScalarEncoder::new(TEST_DIMS);
            let exit_scalar = ScalarEncoder::new(TEST_DIMS);
            let exit_atoms = ExitAtoms::new(&vm);
            let risk_scalar = ScalarEncoder::new(TEST_DIMS);
            let risk_atoms = crate::risk::RiskAtoms::new(&vm);
            let risk_mgr_atoms = crate::risk::manager::RiskManagerAtoms::new(&vm);
            let observer_atoms: Vec<Vector> = OBSERVER_LENSES.iter()
                .map(|lens| vm.get_vector(lens.as_str()))
                .collect();
            let generalist_atom = vm.get_vector("generalist");
            let (codebook_labels, codebook_vecs) = thought_encoder.fact_codebook();
            Self {
                vm,
                thought_encoder,
                mgr_atoms,
                mgr_scalar,
                exit_scalar,
                exit_atoms,
                risk_scalar,
                risk_atoms,
                risk_mgr_atoms,
                observer_atoms,
                generalist_atom,
                codebook_labels,
                codebook_vecs,
            }
        }

        fn ctx(&self) -> CandleContext<'_> {
            let base_asset = Asset::new("USDC");
            let quote_asset = Asset::new("WBTC");
            CandleContext {
                dims: TEST_DIMS,
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
                min_opinion_magnitude: noise_floor(TEST_DIMS),
                codebook_labels: &self.codebook_labels,
                codebook_vecs: &self.codebook_vecs,
                loop_count: 1000,
                progress_every: 500,
                t_start: std::time::Instant::now(),
            }
        }
    }

    #[test]
    fn desk_new_creates() {
        let desk = make_desk();
        assert_eq!(desk.observers.len(), 6, "should have 6 observers (5 specialists + 1 generalist)");
        assert_eq!(desk.encode_count, 0);
        assert_eq!(desk.candle_window.len(), 0);
    }

    #[test]
    fn desk_on_candle_no_panic() {
        let infra = TestInfra::new();
        let ctx = infra.ctx();
        let mut desk = make_desk();
        desk.adaptive_decay = 0.999;

        let mut treasury = Treasury::new(3, 0.5);
        treasury.deposit(&Asset::new("USDC"), 10000.0);
        let mut portfolio = crate::portfolio::Portfolio::new(10000.0, 100);
        let mut peak = 10000.0;
        let mut db_batch = 0usize;

        let raw = make_raw_candle(0);
        let mut shared = SharedState {
            treasury: &mut treasury,
            portfolio: &mut portfolio,
            risk_mult: 0.5,
            peak_equity: &mut peak,
            db_batch: &mut db_batch,
        };
        desk.on_candle(0, &raw, &mut shared, &ctx);
        // No panic means success
    }

    #[test]
    fn desk_on_candle_increments_encode_count() {
        let infra = TestInfra::new();
        let ctx = infra.ctx();
        let mut desk = make_desk();
        desk.adaptive_decay = 0.999;

        let mut treasury = Treasury::new(3, 0.5);
        treasury.deposit(&Asset::new("USDC"), 10000.0);
        let mut portfolio = crate::portfolio::Portfolio::new(10000.0, 100);
        let mut peak = 10000.0;
        let mut db_batch = 0usize;

        for i in 0..5 {
            let raw = make_raw_candle(i);
            let mut shared = SharedState {
                treasury: &mut treasury,
                portfolio: &mut portfolio,
                risk_mult: 0.5,
                peak_equity: &mut peak,
                db_batch: &mut db_batch,
            };
            desk.on_candle(i, &raw, &mut shared, &ctx);
        }

        assert_eq!(desk.encode_count, 5, "encode_count should be 5 after 5 candles");
    }

    #[test]
    fn desk_candle_window_fills() {
        let infra = TestInfra::new();
        let ctx = infra.ctx();
        let mut desk = make_desk();
        desk.adaptive_decay = 0.999;

        let mut treasury = Treasury::new(3, 0.5);
        treasury.deposit(&Asset::new("USDC"), 10000.0);
        let mut portfolio = crate::portfolio::Portfolio::new(10000.0, 100);
        let mut peak = 10000.0;
        let mut db_batch = 0usize;

        for i in 0..50 {
            let raw = make_raw_candle(i);
            let mut shared = SharedState {
                treasury: &mut treasury,
                portfolio: &mut portfolio,
                risk_mult: 0.5,
                peak_equity: &mut peak,
                db_batch: &mut db_batch,
            };
            desk.on_candle(i, &raw, &mut shared, &ctx);
        }

        assert_eq!(desk.candle_window.len(), 50, "candle_window should have 50 entries after 50 candles");
    }

    // ─── Deep integration tests ─────────────────────────────────────────────

    /// Helper: run N candles through a desk, returning the shared state scalars.
    /// Reduces boilerplate across integration tests.
    fn run_candles(desk: &mut Desk, n: usize, ctx: &CandleContext) -> (Treasury, crate::portfolio::Portfolio, f64) {
        let mut treasury = Treasury::new(3, 0.5);
        treasury.deposit(&Asset::new("USDC"), 10000.0);
        let mut portfolio = crate::portfolio::Portfolio::new(10000.0, 100);
        let mut peak = 10000.0;
        let mut db_batch = 0usize;

        for i in 0..n {
            let raw = make_raw_candle(i);
            let mut shared = SharedState {
                treasury: &mut treasury,
                portfolio: &mut portfolio,
                risk_mult: 0.8,
                peak_equity: &mut peak,
                db_batch: &mut db_batch,
            };
            desk.on_candle(i, &raw, &mut shared, ctx);
        }
        (treasury, portfolio, peak)
    }

    /// Helper: make a raw candle with an explicit price.
    fn make_priced_candle(i: usize, price: f64) -> RawCandle {
        RawCandle {
            ts: format!("2024-01-01T{:02}:00:00Z", i % 24),
            open: price - 10.0,
            high: price + 50.0,
            low: price - 50.0,
            close: price,
            volume: 100.0 + (i as f64),
        }
    }

    #[test]
    fn desk_processes_many_candles_builds_pending() {
        let infra = TestInfra::new();
        let ctx = infra.ctx();
        let mut desk = make_desk();
        desk.adaptive_decay = 0.999;

        let (_treasury, _portfolio, _peak) = run_candles(&mut desk, 250, &ctx);

        // After 250 candles, pending should have accumulated entries.
        // Each candle pushes one Pending. Resolution happens at horizon*10 = 360 candles.
        // So with 250 candles, none should have expired yet — all 250 should be pending.
        assert_eq!(desk.pending.len(), 250,
            "all 250 entries should still be pending (horizon*10 = 360)");
        assert_eq!(desk.encode_count, 250);
        // Pending entries should have threshold crossings from ascending prices.
        let crossed = desk.pending.iter().filter(|p| p.crossing.is_some()).count();
        assert!(crossed > 0,
            "ascending prices should cause threshold crossings on earlier entries");
    }

    #[test]
    fn desk_position_opening_when_conditions_met() {
        let infra = TestInfra::new();
        let ctx = infra.ctx();
        let mut desk = make_desk();
        desk.adaptive_decay = 0.999;

        let mut treasury = Treasury::new(3, 0.5);
        treasury.deposit(&Asset::new("USDC"), 10000.0);
        let mut portfolio = crate::portfolio::Portfolio::new(10000.0, 0);
        portfolio.phase = Phase::Tentative;
        let mut peak = 10000.0;
        let mut db_batch = 0usize;

        // Seed the manager journal with observations so it can predict a direction.
        // We need enough for recalibration to fire (builds discriminants).
        // Manager has recalib_interval=200, so we feed 201 observations.
        let buy_vec = infra.vm.get_vector("seed_buy_pattern");
        let sell_vec = infra.vm.get_vector("seed_sell_pattern");
        let mgr_buy = desk.manager_buy;
        let mgr_sell = desk.manager_sell;
        for _ in 0..120 {
            desk.manager_journal.observe(&buy_vec, mgr_buy, 1.0);
        }
        for _ in 0..81 {
            desk.manager_journal.observe(&sell_vec, mgr_sell, 1.0);
        }
        // After 201 observe calls (120+81), recalib should have fired,
        // building discriminants so predict() returns a direction.

        // Force conditions for position opening
        desk.manager_curve_valid = true;
        desk.manager_proven_band = (0.0, 1.0);
        desk.last_exit_price = 0.0;

        // Run candles with ascending prices
        let mut opened = false;
        for i in 0..200 {
            let raw = make_raw_candle(i);
            let mut shared = SharedState {
                treasury: &mut treasury,
                portfolio: &mut portfolio,
                risk_mult: 0.8,
                peak_equity: &mut peak,
                db_batch: &mut db_batch,
            };
            desk.on_candle(i, &raw, &mut shared, &ctx);
            // Re-force conditions each candle since recalibration may reset them
            desk.manager_curve_valid = true;
            desk.manager_proven_band = (0.0, 1.0);
            desk.last_exit_price = 0.0;
            if !desk.positions.is_empty() {
                opened = true;
                break;
            }
        }

        assert!(opened, "a position should have opened when all conditions are met");
        assert!(desk.position_swaps > 0, "swap count should have incremented");
        assert!(desk.pending_logs.iter().any(|l| matches!(l, LogEntry::PositionOpen { .. })),
            "position open log should have been emitted");
    }

    #[test]
    fn desk_pending_resolves_at_horizon() {
        let infra = TestInfra::new();
        let ctx = infra.ctx();
        let mut desk = make_desk();
        desk.adaptive_decay = 0.999;

        // First, run a few candles so the desk has valid indicator state.
        let mut treasury = Treasury::new(3, 0.5);
        treasury.deposit(&Asset::new("USDC"), 10000.0);
        let mut portfolio = crate::portfolio::Portfolio::new(10000.0, 100);
        let mut peak = 10000.0;
        let mut db_batch = 0usize;

        // Warm up with 10 candles
        for i in 0..10 {
            let raw = make_raw_candle(i);
            let mut shared = SharedState {
                treasury: &mut treasury,
                portfolio: &mut portfolio,
                risk_mult: 0.5,
                peak_equity: &mut peak,
                db_batch: &mut db_batch,
            };
            desk.on_candle(i, &raw, &mut shared, &ctx);
        }

        // Now we have 10 pending entries with candle_idx 0..9.
        assert_eq!(desk.pending.len(), 10);

        // max_pending_age = horizon * 10 = 36 * 10 = 360.
        // To resolve entry at candle_idx=0, we need i >= 360.
        // Run candle at i=370, which should resolve entries 0..9 (all age >= 360).
        // But we also need indicator state, so run candles 10..370.
        for i in 10..371 {
            let raw = make_raw_candle(i);
            let mut shared = SharedState {
                treasury: &mut treasury,
                portfolio: &mut portfolio,
                risk_mult: 0.5,
                peak_equity: &mut peak,
                db_batch: &mut db_batch,
            };
            desk.on_candle(i, &raw, &mut shared, &ctx);
        }

        // Entries from candle 0..9 should have been resolved (age = 370 - idx >= 361).
        // New entries 10..370 (361 entries) added, minus those resolved too.
        // Entries with candle_idx <= 10 have age >= 360, so at least the first 11 are resolved.
        // Total added: 371. Resolved: those with age >= 360 at time of processing.
        // The resolution check runs after push, so candle i=370 resolves idx 0..10 (11 entries).
        // Let's just verify pending shrank vs total candles run.
        assert!(desk.pending.len() < 371,
            "some entries should have been resolved at horizon");
        // Verify CandleLog entries were emitted (resolution produces log entries)
        let candle_log_count = desk.pending_logs.iter()
            .filter(|l| matches!(l, LogEntry::CandleLog { .. }))
            .count();
        assert!(candle_log_count > 0, "resolved entries should produce CandleLog entries");
    }

    #[test]
    fn desk_recalibration_fires() {
        // Journal recalibrates after recalib_interval observe() calls, not candles.
        // Each threshold crossing triggers one observe() per observer.
        // We use a desk with a small recalib_interval (20) and volatile prices
        // so crossings accumulate quickly enough to trigger recalibration.
        let infra = TestInfra::new();
        let mut desk = Desk::new(DeskConfig {
            name: "test-desk".to_string(),
            source_asset: Asset::new("USDC"),
            target_asset: Asset::new("WBTC"),
            dims: TEST_DIMS,
            recalib_interval: 20,  // small interval for faster recalibration
            window: 100,
            max_window_size: 2016,
            decay: 0.999,
        });
        desk.adaptive_decay = 0.999;

        // Build ctx with matching recalib_interval
        let base_asset = Asset::new("USDC");
        let quote_asset = Asset::new("WBTC");
        let ctx = CandleContext {
            dims: TEST_DIMS,
            horizon: 36,
            move_threshold: 0.005,
            atr_multiplier: 1.0,
            decay: 0.999,
            recalib_interval: 20,
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
            k_tp: 3.0,
            exit_horizon: 36,
            exit_observe_interval: 5,
            decay_stable: 0.999,
            decay_adapting: 0.995,
            highconv_rolling_cap: 100,
            max_single_position: 0.03,
            conviction_warmup: 100,
            conviction_window: 500,
            vm: &infra.vm,
            thought_encoder: &infra.thought_encoder,
            mgr_atoms: &infra.mgr_atoms,
            mgr_scalar: &infra.mgr_scalar,
            exit_scalar: &infra.exit_scalar,
            exit_atoms: &infra.exit_atoms,
            risk_scalar: &infra.risk_scalar,
            risk_atoms: &infra.risk_atoms,
            risk_mgr_atoms: &infra.risk_mgr_atoms,
            observer_atoms: &infra.observer_atoms,
            generalist_atom: &infra.generalist_atom,
            min_opinion_magnitude: noise_floor(TEST_DIMS),
            codebook_labels: &infra.codebook_labels,
            codebook_vecs: &infra.codebook_vecs,
            loop_count: 1000,
            progress_every: 10000,  // suppress progress output
            t_start: std::time::Instant::now(),
        };

        let mut treasury = Treasury::new(3, 0.5);
        treasury.deposit(&Asset::new("USDC"), 10000.0);
        let mut portfolio = crate::portfolio::Portfolio::new(10000.0, 100);
        let mut peak = 10000.0;
        let mut db_batch = 0usize;

        let recalib_before = desk.observers[GENERALIST_IDX].journal.recalib_count();

        // Use volatile prices to generate many threshold crossings.
        // Alternate high and low prices so entries cross threshold quickly.
        for i in 0..300 {
            let price = if i % 2 == 0 { 50000.0 + (i as f64) * 50.0 }
                        else { 50000.0 - (i as f64) * 50.0 };
            let raw = make_priced_candle(i, price.max(10000.0));
            let mut shared = SharedState {
                treasury: &mut treasury,
                portfolio: &mut portfolio,
                risk_mult: 0.5,
                peak_equity: &mut peak,
                db_batch: &mut db_batch,
            };
            desk.on_candle(i, &raw, &mut shared, &ctx);
        }

        let recalib_after = desk.observers[GENERALIST_IDX].journal.recalib_count();
        assert!(recalib_after > recalib_before,
            "journal should have recalibrated (before={}, after={})", recalib_before, recalib_after);

        // Check that RecalibLog was emitted
        let recalib_logs: Vec<_> = desk.pending_logs.iter()
            .filter(|l| matches!(l, LogEntry::RecalibLog { .. }))
            .collect();
        assert!(!recalib_logs.is_empty(),
            "RecalibLog entries should have been emitted during recalibration");
    }

    #[test]
    fn desk_position_exit_on_stop_loss() {
        let infra = TestInfra::new();
        let ctx = infra.ctx();
        let mut desk = make_desk();
        desk.adaptive_decay = 0.999;

        // Warm up desk with some candles at a stable price
        let entry_price = 50000.0;
        let mut treasury = Treasury::new(3, 0.5);
        treasury.deposit(&Asset::new("USDC"), 10000.0);
        treasury.deposit(&Asset::new("WBTC"), 0.1);
        let mut portfolio = crate::portfolio::Portfolio::new(10000.0, 0);
        portfolio.phase = Phase::Tentative;
        let mut peak = 10000.0;
        let mut db_batch = 0usize;

        // Run a few candles to build indicator state
        for i in 0..20 {
            let raw = make_priced_candle(i, entry_price);
            let mut shared = SharedState {
                treasury: &mut treasury,
                portfolio: &mut portfolio,
                risk_mult: 0.8,
                peak_equity: &mut peak,
                db_batch: &mut db_batch,
            };
            desk.on_candle(i, &raw, &mut shared, &ctx);
        }

        // Manually create a position and push it into desk.positions.
        // Buy position: source=USDC, target=WBTC, rate = USDC per WBTC = price
        let base = Asset::new("USDC");
        let quote = Asset::new("WBTC");
        let atr = 0.01; // 1% normalized ATR
        let pos = ManagedPosition::new(PositionEntry {
            id: desk.next_position_id,
            candle_idx: 15,
            source_asset: base.clone(),
            target_asset: quote.clone(),
            source_amount: 500.0,
            target_received: 500.0 / entry_price,
            entry_rate: entry_price,
            entry_atr: atr,
            entry_fee: 1.0,
            k_stop: ctx.k_stop,
            k_tp: ctx.k_tp,
        });
        // Stop is at entry_price * (1 - k_stop * atr) = 50000 * (1 - 2*0.01) = 49000
        desk.next_position_id += 1;
        // Claim the target in treasury so release works
        treasury.deposit(&quote, pos.target_held);
        treasury.claim(&quote, pos.target_held);
        desk.positions.push(pos);

        assert_eq!(desk.positions.len(), 1, "should have one position before crash");

        // Now feed a candle with a price crash that triggers the stop loss
        // Stop is at 49000, so feed 48000
        let crash_price = 48000.0;
        let raw = make_priced_candle(20, crash_price);
        let mut shared = SharedState {
            treasury: &mut treasury,
            portfolio: &mut portfolio,
            risk_mult: 0.8,
            peak_equity: &mut peak,
            db_batch: &mut db_batch,
        };
        desk.on_candle(20, &raw, &mut shared, &ctx);

        // Position should have been closed and removed
        assert_eq!(desk.positions.len(), 0,
            "position should be closed after stop loss trigger");
        assert!(desk.position_swaps > 0, "swap count should reflect the exit");
        // Should have a PositionExit log
        assert!(desk.pending_logs.iter().any(|l| matches!(l, LogEntry::PositionExit { .. })),
            "PositionExit log should have been emitted");
    }

    #[test]
    fn desk_position_exit_on_take_profit() {
        let infra = TestInfra::new();
        let ctx = infra.ctx();
        let mut desk = make_desk();
        desk.adaptive_decay = 0.999;

        let entry_price = 50000.0;
        let mut treasury = Treasury::new(3, 0.5);
        treasury.deposit(&Asset::new("USDC"), 10000.0);
        let mut portfolio = crate::portfolio::Portfolio::new(10000.0, 0);
        portfolio.phase = Phase::Tentative;
        let mut peak = 10000.0;
        let mut db_batch = 0usize;

        // Warm up
        for i in 0..20 {
            let raw = make_priced_candle(i, entry_price);
            let mut shared = SharedState {
                treasury: &mut treasury,
                portfolio: &mut portfolio,
                risk_mult: 0.8,
                peak_equity: &mut peak,
                db_batch: &mut db_batch,
            };
            desk.on_candle(i, &raw, &mut shared, &ctx);
        }

        // Create a buy position. TP at entry_price * (1 + k_tp * atr) = 50000*(1+3*0.01) = 51500
        let base = Asset::new("USDC");
        let quote = Asset::new("WBTC");
        let atr = 0.01;
        let pos = ManagedPosition::new(PositionEntry {
            id: desk.next_position_id,
            candle_idx: 15,
            source_asset: base.clone(),
            target_asset: quote.clone(),
            source_amount: 500.0,
            target_received: 500.0 / entry_price,
            entry_rate: entry_price,
            entry_atr: atr,
            entry_fee: 1.0,
            k_stop: ctx.k_stop,
            k_tp: ctx.k_tp,
        });
        desk.next_position_id += 1;
        treasury.deposit(&quote, pos.target_held);
        treasury.claim(&quote, pos.target_held);
        desk.positions.push(pos);

        // Feed a candle above TP (51500) → should trigger take profit → Runner phase
        let tp_price = 52000.0;
        let raw = make_priced_candle(20, tp_price);
        let mut shared = SharedState {
            treasury: &mut treasury,
            portfolio: &mut portfolio,
            risk_mult: 0.8,
            peak_equity: &mut peak,
            db_batch: &mut db_batch,
        };
        desk.on_candle(20, &raw, &mut shared, &ctx);

        // Position should transition to Runner (partial profit), not closed
        // OR if reclaim_target >= target_held, it closes entirely.
        // Either way, a PositionExit log should exist.
        assert!(desk.pending_logs.iter().any(|l| matches!(l, LogEntry::PositionExit { .. })),
            "PositionExit log should have been emitted on take profit");
        assert!(desk.position_swaps > 0);
        assert!(desk.position_wins > 0, "take profit should count as a win");
    }

    #[test]
    fn desk_500_candle_smoke_test() {
        let infra = TestInfra::new();
        let ctx = infra.ctx();
        let mut desk = make_desk();
        desk.adaptive_decay = 0.999;

        let mut treasury = Treasury::new(3, 0.5);
        treasury.deposit(&Asset::new("USDC"), 10000.0);
        let mut portfolio = crate::portfolio::Portfolio::new(10000.0, 100);
        let mut peak = 10000.0;
        let mut db_batch = 0usize;

        // Ascending then descending prices: trend then reversal
        for i in 0..500 {
            let price = if i < 250 {
                50000.0 + (i as f64) * 20.0  // ascending
            } else {
                50000.0 + (500.0 - i as f64) * 20.0  // descending back
            };
            let raw = make_priced_candle(i, price);
            let mut shared = SharedState {
                treasury: &mut treasury,
                portfolio: &mut portfolio,
                risk_mult: 0.8,
                peak_equity: &mut peak,
                db_batch: &mut db_batch,
            };
            desk.on_candle(i, &raw, &mut shared, &ctx);
        }

        // Basic sanity: no panic, all candles processed
        assert_eq!(desk.encode_count, 500);
        assert!(desk.candle_window.len() <= desk.max_window_size,
            "window should not exceed max_window_size");
        // Pending entries: 500 pushed, some resolved (max_pending_age=360, oldest at i=0, last i=499)
        // entries 0..139 have age >= 360 at some point → resolved
        assert!(desk.pending.len() < 500,
            "some entries should have resolved at horizon");
        // Log entries should have been produced
        assert!(!desk.pending_logs.is_empty(), "logs should have been produced");
        // Verify entries were resolved and categorized
        assert!(desk.labeled_count + desk.noise_count > 0,
            "some entries should have been labeled or marked as noise after 500 candles with resolution at horizon*10=360");
    }

    #[test]
    fn desk_learning_loop_threshold_crossing() {
        // Verify that the learning loop detects threshold crossings and records them.
        let infra = TestInfra::new();
        let ctx = infra.ctx();
        let mut desk = make_desk();
        desk.adaptive_decay = 0.999;

        let mut treasury = Treasury::new(3, 0.5);
        treasury.deposit(&Asset::new("USDC"), 10000.0);
        let mut portfolio = crate::portfolio::Portfolio::new(10000.0, 100);
        let mut peak = 10000.0;
        let mut db_batch = 0usize;

        // Start at 50000, then jump to trigger threshold crossing.
        // atr_multiplier=1.0, so threshold = 1.0 * entry.entry_atr.
        // After indicator warmup, ATR should stabilize. A large price jump
        // should cross the threshold for early entries.
        for i in 0..50 {
            let raw = make_priced_candle(i, 50000.0);
            let mut shared = SharedState {
                treasury: &mut treasury,
                portfolio: &mut portfolio,
                risk_mult: 0.5,
                peak_equity: &mut peak,
                db_batch: &mut db_batch,
            };
            desk.on_candle(i, &raw, &mut shared, &ctx);
        }

        // Count entries without crossings
        let uncrossed_before = desk.pending.iter()
            .filter(|p| p.crossing.is_none()).count();

        // Big price jump: 50000 → 55000 (10% move) — should cross any reasonable threshold
        for i in 50..60 {
            let raw = make_priced_candle(i, 55000.0);
            let mut shared = SharedState {
                treasury: &mut treasury,
                portfolio: &mut portfolio,
                risk_mult: 0.5,
                peak_equity: &mut peak,
                db_batch: &mut db_batch,
            };
            desk.on_candle(i, &raw, &mut shared, &ctx);
        }

        // Some earlier pending entries should now have crossings
        let crossed_count = desk.pending.iter()
            .filter(|p| p.crossing.is_some()).count();
        assert!(crossed_count > 0,
            "price jump should have triggered threshold crossings on pending entries");
        // Entries at the new price shouldn't cross yet (no movement from 55000)
        let uncrossed_after = desk.pending.iter()
            .filter(|p| p.crossing.is_none()).count();
        assert!(uncrossed_after > 0,
            "entries at the new stable price should not have crossed yet");
        assert!(uncrossed_after < uncrossed_before + 10,
            "some of the old entries should have gained crossings");
    }

    #[test]
    fn desk_manager_learning_on_resolution() {
        // Verify that manager_resolved accumulates when entries resolve with non-Noise outcomes.
        // For manager learning to fire, resolved entries need:
        // 1. A threshold crossing (non-Noise)
        // 2. Observer predictions with a majority direction (buys != sells)
        // We seed observer journals so they produce directional predictions.
        let infra = TestInfra::new();
        let ctx = infra.ctx();
        let mut desk = make_desk();
        desk.adaptive_decay = 0.999;

        // Seed all observer journals with enough observations to build discriminants.
        // Recalib_interval=200 for observers, so 201 observations triggers recalib.
        let buy_seed = infra.vm.get_vector("obs_buy_seed");
        let sell_seed = infra.vm.get_vector("obs_sell_seed");
        for obs in desk.observers.iter_mut() {
            let buy_label = obs.primary_label;
            let sell_label = obs.journal.labels()[1];
            for _ in 0..120 {
                obs.journal.observe(&buy_seed, buy_label, 1.0);
            }
            for _ in 0..81 {
                obs.journal.observe(&sell_seed, sell_label, 1.0);
            }
        }
        // Also seed manager journal
        let mgr_buy_seed = infra.vm.get_vector("mgr_buy_seed");
        let mgr_sell_seed = infra.vm.get_vector("mgr_sell_seed");
        for _ in 0..120 {
            desk.manager_journal.observe(&mgr_buy_seed, desk.manager_buy, 1.0);
        }
        for _ in 0..81 {
            desk.manager_journal.observe(&mgr_sell_seed, desk.manager_sell, 1.0);
        }

        let mut treasury = Treasury::new(3, 0.5);
        treasury.deposit(&Asset::new("USDC"), 10000.0);
        let mut portfolio = crate::portfolio::Portfolio::new(10000.0, 100);
        let mut peak = 10000.0;
        let mut db_batch = 0usize;

        // Phase 1: flat for 20 candles (entries at stable price)
        for i in 0..20 {
            let raw = make_priced_candle(i, 50000.0);
            let mut shared = SharedState {
                treasury: &mut treasury,
                portfolio: &mut portfolio,
                risk_mult: 0.5,
                peak_equity: &mut peak,
                db_batch: &mut db_batch,
            };
            desk.on_candle(i, &raw, &mut shared, &ctx);
        }

        // Phase 2: big jump to trigger crossings on early entries
        for i in 20..30 {
            let raw = make_priced_candle(i, 55000.0);
            let mut shared = SharedState {
                treasury: &mut treasury,
                portfolio: &mut portfolio,
                risk_mult: 0.5,
                peak_equity: &mut peak,
                db_batch: &mut db_batch,
            };
            desk.on_candle(i, &raw, &mut shared, &ctx);
        }

        let resolved_before = desk.manager_resolved.len();

        // Phase 3: run to resolution (candle 370+ resolves entries from candle 0..10+)
        for i in 30..400 {
            let raw = make_priced_candle(i, 55000.0 + (i as f64) * 5.0);
            let mut shared = SharedState {
                treasury: &mut treasury,
                portfolio: &mut portfolio,
                risk_mult: 0.5,
                peak_equity: &mut peak,
                db_batch: &mut db_batch,
            };
            desk.on_candle(i, &raw, &mut shared, &ctx);
        }

        assert!(desk.manager_resolved.len() > resolved_before,
            "manager_resolved should grow as entries with crossings resolve (before={}, after={})",
            resolved_before, desk.manager_resolved.len());
        assert!(desk.labeled_count > 0,
            "some entries should have been labeled (non-Noise)");
    }
}
