//! EnterpriseState — the mutable state of the enterprise heartbeat.
//!
//! Everything the main loop mutates, packaged into one struct.
//! Created once at startup, threaded through the heartbeat.
//! enterprise.rs orchestrates; this module holds what changes.

use std::collections::VecDeque;

use rusqlite::{params, Connection};
use holon::memory::{Journal, OnlineSubspace};
use holon::{Primitives, ScalarMode, VectorManager, Vector};

use crate::candle::Candle;
use crate::journal::{Label, Direction, Prediction, register_direction, register_exit};
use crate::market::observer::Observer;
use crate::market::{parse_candle_hour, parse_candle_day};
use crate::market::manager::{ManagerAtoms, ManagerContext, encode_manager_thought};
use crate::portfolio::{Phase, Portfolio};
use crate::position::{ExitObservation, ExitReason, ManagedPosition, Pending, PositionExit, PositionPhase};
use crate::risk::RiskBranch;
use crate::sizing::{kelly_frac, signal_weight};
use crate::treasury::Treasury;

// ─── ExitAtoms ─────────────────────────────────────────────────────────────

/// Immutable atom vectors for the exit expert encoding.
pub struct ExitAtoms {
    pub pnl: Vector,
    pub hold: Vector,
    pub mfe: Vector,
    pub atr_entry: Vector,
    pub atr_now: Vector,
    pub stop_dist: Vector,
    pub phase: Vector,
    pub direction: Vector,
    // Filler atoms — pre-warmed, not created in the hot path
    pub runner: Vector,
    pub active: Vector,
    pub buy: Vector,
    pub sell: Vector,
}

// ─── CandleContext ─────────────────────────────────────────────────────────

/// Immutable references needed by on_candle but owned by main().
/// Bundles config, atoms, encoders, and the ledger — everything
/// the sequential body reads but never writes.
pub struct CandleContext<'a> {
    // ── CLI args ────────────────────────────────────────────────────────
    pub dims: usize,
    pub window: usize,
    pub horizon: usize,
    pub move_threshold: f64,
    pub atr_multiplier: f64,
    pub decay: f64,
    pub observe_period: usize,
    pub recalib_interval: usize,
    pub min_conviction: f64,
    pub conviction_quantile: f64,
    pub conviction_mode: &'a str,
    pub min_edge: f64,
    pub sizing: &'a str,
    pub max_drawdown: f64,
    pub swap_fee: f64,
    pub slippage: f64,
    pub asset_mode: &'a str,
    pub base_asset: &'a str,
    pub quote_asset: &'a str,
    pub initial_equity: f64,
    pub diagnostics: bool,

    // ── Exit parameters ─────────────────────────────────────────────────
    pub k_stop: f64,
    pub k_trail: f64,
    pub k_tp: f64,
    pub exit_horizon: usize,
    pub exit_observe_interval: usize,
    pub rolling_cap: usize,

    // ── Config constants ────────────────────────────────────────────────
    pub decay_stable: f64,
    pub decay_adapting: f64,
    pub highconv_rolling_cap: usize,
    pub max_single_position: f64,
    pub conviction_warmup: usize,
    pub conviction_window: usize,

    // ── Immutable encoding infrastructure ───────────────────────────────
    pub vm: &'a VectorManager,
    pub mgr_atoms: &'a ManagerAtoms,
    pub mgr_scalar: &'a holon::ScalarEncoder,
    pub exit_scalar: &'a holon::ScalarEncoder,
    pub exit_atoms: &'a ExitAtoms,
    pub risk_scalar: &'a holon::ScalarEncoder,

    // ── Observer/manager atoms ──────────────────────────────────────────
    pub observer_atoms: &'a [Vector],
    pub observer_names: &'a [&'a str],
    pub generalist_atom: &'a Vector,
    pub min_opinion_magnitude: f64,

    // ── Codebook for discriminant decode ────────────────────────────────
    pub codebook_labels: &'a [String],
    pub codebook_vecs: &'a [Vector],

    // ── Ledger (DB connection) ──────────────────────────────────────────
    pub ledger: &'a Connection,

    // ── Progress display ────────────────────────────────────────────────
    pub bnh_entry: f64,
    pub loop_count: usize,
    pub progress_every: usize,
    pub t_start: std::time::Instant,
}

// ─── EnterpriseState ────────────────────────────────────────────────────────

pub struct EnterpriseState {
    // ── Learning: journals + labels ──────────────────────────────────────
    pub tht_journal: Journal,
    pub tht_buy: Label,
    pub tht_sell: Label,

    pub mgr_journal: Journal,
    pub mgr_buy: Label,
    pub mgr_sell: Label,
    pub prev_mgr_thought: Option<Vector>,

    // dead-thoughts:allow(scaffolding) — exit journal learns but doesn't predict yet; wired when exit expert modulates trails
    pub exit_journal: Journal,
    pub exit_hold: Label,
    pub exit_exit: Label,
    pub exit_pending: Vec<ExitObservation>,

    // ── Observers ────────────────────────────────────────────────────────
    pub observers: Vec<Observer>,

    // ── Risk ─────────────────────────────────────────────────────────────
    pub risk_branches: Vec<RiskBranch>,
    pub cached_risk_mult: f64,
    pub cached_curve_a: f64,
    pub cached_curve_b: f64,
    pub curve_valid: bool,
    pub mgr_curve_valid: bool,
    pub mgr_resolved: VecDeque<(f64, bool)>,
    pub mgr_proven_band: (f64, f64),

    // ── Panel engram ─────────────────────────────────────────────────────
    pub panel_engram: OnlineSubspace,
    pub panel_recalib_wins: u32,
    pub panel_recalib_total: u32,

    // ── Treasury + portfolio ─────────────────────────────────────────────
    pub treasury: Treasury,
    pub portfolio: Portfolio,
    pub peak_treasury_equity: f64,

    // ── Positions ────────────────────────────────────────────────────────
    pub pending: VecDeque<Pending>,
    pub positions: Vec<ManagedPosition>,
    pub next_position_id: usize,
    pub last_exit_price: f64,
    pub last_exit_atr: f64,

    // ── Hold-mode state ──────────────────────────────────────────────────
    pub hold_swaps: usize,
    pub hold_wins: usize,

    // ── Adaptive decay ───────────────────────────────────────────────────
    pub adaptive_decay: f64,
    pub in_adaptation: bool,
    pub highconv_wins: VecDeque<bool>,

    // ── Tracking counters ────────────────────────────────────────────────
    pub encode_count: usize,
    pub labeled_count: usize,
    pub noise_count: usize,
    pub move_sum: f64,
    pub move_count: usize,
    pub log_step: i64,
    pub db_batch: usize,

    // ── Rolling accuracy ─────────────────────────────────────────────────
    pub tht_rolling: VecDeque<bool>,

    // ── Conviction + flip threshold ──────────────────────────────────────
    pub conviction_history: VecDeque<f64>,
    pub conviction_threshold: f64,
    pub resolved_preds: VecDeque<(f64, bool)>,

    // ── Loop cursor ──────────────────────────────────────────────────────
    pub cursor: usize,
}

impl EnterpriseState {
    /// Build initial state from configuration parameters.
    ///
    /// `dims`: vector dimensionality.
    /// `recalib_interval`: journal update count between discriminant recalibrations.
    /// `initial_equity`: starting paper equity in USD.
    /// `observe_period`: candles to observe before any trades.
    /// `decay`: accumulator decay rate per candle.
    /// `base_asset`: the unit of account (e.g. "USDC").
    /// `max_positions`: maximum concurrent positions.
    /// `max_utilization`: maximum fraction of total equity deployed.
    /// `start_idx`: first candle index for the walk-forward loop.
    pub fn new(
        dims: usize,
        recalib_interval: usize,
        initial_equity: f64,
        observe_period: usize,
        decay: f64,
        base_asset: &str,
        max_positions: usize,
        max_utilization: f64,
        start_idx: usize,
    ) -> Self {
        // ── Thought journal ─────────────────────────────────────────────
        let mut tht_journal = Journal::new("thought", dims, recalib_interval);
        let (tht_buy, tht_sell) = register_direction(&mut tht_journal);

        // ── Manager journal ─────────────────────────────────────────────
        let mut mgr_journal = Journal::new("manager", dims, recalib_interval);
        let (mgr_buy, mgr_sell) = register_direction(&mut mgr_journal);

        // ── Exit expert journal ─────────────────────────────────────────
        let mut exit_journal = Journal::new("exit-expert", dims, recalib_interval);
        let (exit_hold, exit_exit) = register_exit(&mut exit_journal);

        // ── Observer panel ──────────────────────────────────────────────
        let observer_names = ["momentum", "structure", "volume", "narrative", "regime"];
        let observers: Vec<Observer> = observer_names
            .iter()
            .enumerate()
            .map(|(ei, &profile)| {
                Observer::new(
                    profile,
                    dims,
                    recalib_interval,
                    dims as u64 + ei as u64 * 7919,
                    &["Buy", "Sell"],
                )
            })
            .collect();

        // ── Risk branches ───────────────────────────────────────────────
        let risk_branches = vec![
            RiskBranch::new("drawdown", dims),
            RiskBranch::new("accuracy", dims),
            RiskBranch::new("volatility", dims),
            RiskBranch::new("correlation", dims),
            RiskBranch::new("panel", dims),
        ];

        // ── Panel engram ────────────────────────────────────────────────
        let panel_dim = observer_names.len() + 1; // experts + generalist
        let panel_engram = OnlineSubspace::with_params(panel_dim, 4, 2.0, 0.01, 3.5, 100);

        // ── Treasury + portfolio ────────────────────────────────────────
        let treasury = Treasury::new(base_asset, initial_equity, max_positions, max_utilization);
        let portfolio = Portfolio::new(initial_equity, observe_period);

        // ── Adaptive decay ──────────────────────────────────────────────
        let adaptive_decay = decay;

        Self {
            // Learning
            tht_journal,
            tht_buy,
            tht_sell,
            mgr_journal,
            mgr_buy,
            mgr_sell,
            prev_mgr_thought: None,
            exit_journal,
            exit_hold,
            exit_exit,
            exit_pending: Vec::new(),

            // Observers
            observers,

            // Risk
            risk_branches,
            cached_risk_mult: 0.5,
            cached_curve_a: 0.0,
            cached_curve_b: 0.0,
            curve_valid: false,
            mgr_curve_valid: false,
            mgr_resolved: VecDeque::new(),
            mgr_proven_band: (0.0, 0.0),

            // Panel engram
            panel_engram,
            panel_recalib_wins: 0,
            panel_recalib_total: 0,

            // Treasury + portfolio
            treasury,
            portfolio,
            peak_treasury_equity: initial_equity,

            // Positions
            pending: VecDeque::new(),
            positions: Vec::new(),
            next_position_id: 0,
            last_exit_price: 0.0,
            last_exit_atr: 0.0,

            // Hold-mode
            hold_swaps: 0,
            hold_wins: 0,

            // Adaptive decay
            adaptive_decay,
            in_adaptation: false,
            highconv_wins: VecDeque::new(),

            // Tracking
            encode_count: 0,
            labeled_count: 0,
            noise_count: 0,
            move_sum: 0.0,
            move_count: 0,
            log_step: 0,
            db_batch: 0,

            // Rolling accuracy
            tht_rolling: VecDeque::new(),

            // Conviction
            conviction_history: VecDeque::new(),
            conviction_threshold: 0.0,
            resolved_preds: VecDeque::new(),

            // Loop cursor
            cursor: start_idx,
        }
    }

    /// Process one candle's pre-computed results. The fold's step function.
    ///
    /// Called once per candle in the sequential phase, after parallel encoding.
    /// All mutable state lives on `self`. All immutable config comes via `ctx`.
    /// `candles` is the full history (for lookback by pending entries).
    pub fn on_candle(
        &mut self,
        i: usize,
        candles: &[Candle],
        tht_vec: Vector,
        tht_facts: Vec<String>,
        observer_vecs: Vec<Vector>,
        ctx: &CandleContext,
    ) {
        self.encode_count += 1;

        // ── Expert predictions: each observer speaks ─────────────────
        // No flip. The discriminant learns what predicts — including reversals.
        // The flip was a hack for a single journal. The enterprise lets each
        // expert's discriminant encode the full pattern naturally.
        let observer_preds: Vec<Prediction> = observer_vecs.iter().enumerate()
            .map(|(ei, vec)| self.observers[ei].journal.predict(vec))
            .collect();

        // The generalist still encodes for backward compatibility
        // (flip threshold, resolved_preds tracking, DB logging).
        // But direction and conviction now come from the expert panel.
        let tht_pred = self.tht_journal.predict(&tht_vec);

        // ── Manager: encodes expert opinions via manager.rs ──────────
        // Single canonical encoding path. See manager.rs and wat/manager.wat.
        let obs_curve_valid: Vec<bool> = self.observers.iter().map(|o| o.curve_valid).collect();
        let obs_resolved_lens: Vec<usize> = self.observers.iter().map(|o| o.resolved.len()).collect();
        let obs_resolved_accs: Vec<f64> = self.observers.iter().map(|o| {
            let len = o.resolved.len();
            if len == 0 { 0.0 } else {
                o.resolved.iter().filter(|(_, c)| *c).count() as f64 / len as f64
            }
        }).collect();
        let mgr_ctx = ManagerContext {
            observer_preds: &observer_preds,
            observer_atoms: ctx.observer_atoms,
            observer_curve_valid: &obs_curve_valid,
            observer_resolved_lens: &obs_resolved_lens,
            observer_resolved_accs: &obs_resolved_accs,
            observer_vecs: &observer_vecs,
            generalist_pred: &tht_pred,
            generalist_atom: ctx.generalist_atom,
            generalist_curve_valid: self.curve_valid,
            candle_atr: candles[i].atr_r,
            candle_hour: parse_candle_hour(&candles[i].ts),
            candle_day: parse_candle_day(&candles[i].ts),
            disc_strength: self.tht_journal.last_disc_strength(),
        };
        let mgr_facts = encode_manager_thought(&mgr_ctx, ctx.mgr_atoms, ctx.mgr_scalar, ctx.min_opinion_magnitude);

        // Difference: what changed since last candle?
        // The manager sees motion, not just position.
        let mgr_refs: Vec<&Vector> = mgr_facts.iter().collect();
        let (mgr_pred, stored_mgr_thought) = if mgr_refs.is_empty() {
            (Prediction::default(), None)
        } else {
            let mgr_thought = Primitives::bundle(&mgr_refs);
            let final_thought = if let Some(ref prev) = self.prev_mgr_thought {
                let delta = Primitives::difference(prev, &mgr_thought);
                let delta_bound = Primitives::bind(&ctx.mgr_atoms.delta, &delta);
                Primitives::bundle(&[&mgr_thought, &delta_bound])
            } else {
                mgr_thought.clone()
            };
            self.prev_mgr_thought = Some(mgr_thought);
            let pred = self.mgr_journal.predict(&final_thought);
            (pred, Some(final_thought))
        };

        // Panel state for engram (Template 2 — reaction layer)
        let mut panel_state: Vec<f64> = observer_preds.iter()
            .map(|ep| ep.raw_cos).collect();
        panel_state.push(tht_pred.raw_cos); // generalist's voice
        // dead-thoughts:allow(scaffolding) — panel_familiar computed for display only; wired when panel engram drives decisions
        let panel_familiar = if self.panel_engram.n() >= 10 {
            let residual = self.panel_engram.residual(&panel_state);
            let threshold = self.panel_engram.threshold();
            residual < threshold
        } else {
            false
        };

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
        // decomplect:allow(inline-computation) — flip threshold curve fitting, extracts to sizing module
        if self.conviction_history.len() >= ctx.conviction_warmup
            && self.encode_count % ctx.recalib_interval == 0
        {
            match ctx.conviction_mode {
                "quantile" if ctx.conviction_quantile > 0.0 => {
                    let mut sorted: Vec<f64> = self.conviction_history.iter().copied().collect();
                    sorted.sort_by(|a, b| a.partial_cmp(b).unwrap());
                    let idx = ((sorted.len() as f64 * ctx.conviction_quantile) as usize)
                        .min(sorted.len() - 1);
                    self.conviction_threshold = sorted[idx];
                }
                "auto" if self.resolved_preds.len() >= ctx.conviction_warmup * 5 => {
                    // Need 5× warmup (~5000 resolved) for stable exponential fit.
                    // Fit the exponential conviction-accuracy curve:
                    //   accuracy = 0.50 + a × exp(b × conviction)
                    // Then solve for threshold: conv = ln((min_edge - 0.50) / a) / b
                    //
                    // Bin resolved predictions, compute per-bin accuracy,
                    // log-linear regression on bins where accuracy > 0.50.
                    let n_bins = 20usize;
                    let mut sorted: Vec<(f64, bool)> = self.resolved_preds.iter().copied().collect();
                    sorted.sort_by(|a, b| a.0.partial_cmp(&b.0).unwrap());
                    let bin_size = sorted.len() / n_bins;
                    if bin_size >= 20 {
                        // Compute (mean_conviction, accuracy) per bin.
                        let mut bins: Vec<(f64, f64)> = Vec::new();
                        for bi in 0..n_bins {
                            let start = bi * bin_size;
                            let end = if bi == n_bins - 1 { sorted.len() } else { (bi + 1) * bin_size };
                            let slice = &sorted[start..end];
                            let mean_c: f64 = slice.iter().map(|(c, _)| c).sum::<f64>() / slice.len() as f64;
                            let acc: f64 = slice.iter().filter(|(_, w)| *w).count() as f64 / slice.len() as f64;
                            bins.push((mean_c, acc));
                        }

                        // Log-linear regression on bins where acc > 0.505.
                        // y = ln(acc - 0.50), x = conviction → y = ln(a) + b*x
                        let points: Vec<(f64, f64)> = bins.iter()
                            .filter(|(_, acc)| *acc > 0.505)
                            .map(|(c, acc)| (*c, (acc - 0.50).ln()))
                            .filter(|(_, y)| y.is_finite())
                            .collect();

                        if points.len() >= 3 {
                            let n = points.len() as f64;
                            let sx: f64 = points.iter().map(|(x, _)| x).sum();
                            let sy: f64 = points.iter().map(|(_, y)| y).sum();
                            let sxx: f64 = points.iter().map(|(x, _)| x * x).sum();
                            let sxy: f64 = points.iter().map(|(x, y)| x * y).sum();
                            let denom = n * sxx - sx * sx;
                            if denom.abs() > 1e-10 {
                                let b = (n * sxy - sx * sy) / denom;
                                let ln_a = (sy - b * sx) / n;
                                let a = ln_a.exp();

                                // Solve: min_edge = 0.50 + a * exp(b * conv)
                                // conv = ln((min_edge - 0.50) / a) / b
                                if b > 0.0 && ctx.min_edge > 0.50 {
                                    let target = (ctx.min_edge - 0.50) / a;
                                    if target > 0.0 {
                                        let new_thresh = target.ln() / b;
                                        if new_thresh > 0.0 && new_thresh < 1.0 {
                                            self.conviction_threshold = new_thresh;
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                // Fallback: during auto warmup, use quantile if available.
                "auto" if ctx.conviction_quantile > 0.0
                    && self.conviction_history.len() >= ctx.conviction_warmup => {
                    let mut sorted: Vec<f64> = self.conviction_history.iter().copied().collect();
                    sorted.sort_by(|a, b| a.partial_cmp(b).unwrap());
                    let idx = ((sorted.len() as f64 * ctx.conviction_quantile) as usize)
                        .min(sorted.len() - 1);
                    self.conviction_threshold = sorted[idx];
                }
                _ => {}
            }
        }

        // No flip. The enterprise doesn't invert its own decisions.

        // ── Position management: tick all open positions ─────────
        let quote_price = candles[i].close;
        let fee_rate = ctx.swap_fee + ctx.slippage;
        // Treasury equity: the source of truth. Token-agnostic.
        let prices = self.treasury.price_map(&[(ctx.quote_asset, quote_price)]);
        let treasury_equity = self.treasury.total_value(&prices);
        if treasury_equity > self.peak_treasury_equity {
            self.peak_treasury_equity = treasury_equity;
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

        for pos in self.positions.iter_mut() {
            if pos.phase == PositionPhase::Closed { continue; }

            // Exit expert: encode at Nyquist rate of position lifecycle
            if pos.candles_held > 0 && pos.candles_held % ctx.exit_observe_interval == 0 {
                let pnl_frac = pos.return_pct(quote_price);
                let mfe_frac = (pos.high_water - pos.entry_price) / pos.entry_price;
                let stop_dist = (quote_price - pos.trailing_stop).abs() / quote_price;
                let exit_thought = Primitives::bundle(&[
                    &Primitives::bind(&ctx.exit_atoms.pnl, &ctx.exit_scalar.encode(pnl_frac.clamp(-1.0, 1.0) * 0.5 + 0.5, ScalarMode::Linear { scale: 1.0 })),
                    &Primitives::bind(&ctx.exit_atoms.hold, &ctx.exit_scalar.encode_log(pos.candles_held as f64)),
                    &Primitives::bind(&ctx.exit_atoms.mfe, &ctx.exit_scalar.encode(mfe_frac.clamp(0.0, 1.0), ScalarMode::Linear { scale: 1.0 })),
                    &Primitives::bind(&ctx.exit_atoms.atr_entry, &ctx.exit_scalar.encode_log(pos.entry_atr.max(1e-10))),
                    &Primitives::bind(&ctx.exit_atoms.atr_now, &ctx.exit_scalar.encode_log(candles[i].atr_r.max(1e-10))),
                    &Primitives::bind(&ctx.exit_atoms.stop_dist, &ctx.exit_scalar.encode(stop_dist.clamp(0.0, 1.0), ScalarMode::Linear { scale: 1.0 })),
                    &Primitives::bind(&ctx.exit_atoms.phase, if pos.phase == PositionPhase::Runner { &ctx.exit_atoms.runner } else { &ctx.exit_atoms.active }),
                    &Primitives::bind(&ctx.exit_atoms.direction, if pos.direction == Direction::Long { &ctx.exit_atoms.buy } else { &ctx.exit_atoms.sell }),
                ]);

                // Buffer observation for resolution
                self.exit_pending.push(ExitObservation {
                    thought: exit_thought.clone(),
                    pos_id: pos.id,
                    snapshot_pnl: pnl_frac,
                    snapshot_candle: i,
                });

            }

            if let Some(exit) = pos.tick(quote_price, ctx.k_trail) {
                match exit {
                    PositionExit::TakeProfit if pos.phase == PositionPhase::Active => {
                        // Partial exit: reclaim capital + fees + minimum profit
                        let reclaim_base = pos.base_deployed + pos.total_fees + pos.base_deployed * 0.01;
                        let reclaim_quote = reclaim_base / quote_price / (1.0 - fee_rate);
                        if reclaim_quote < pos.quote_held {
                            // Partial: release from deployed, then sell
                            self.treasury.release(ctx.quote_asset, reclaim_quote);
                            let (sold, received) = self.treasury.swap(ctx.quote_asset, ctx.base_asset,
                                reclaim_quote, 1.0 / quote_price, fee_rate);
                            pos.quote_held -= sold;
                            pos.base_reclaimed += received;
                            pos.total_fees += sold * quote_price * fee_rate;
                            pos.phase = PositionPhase::Runner;
                            self.hold_swaps += 1;
                            self.hold_wins += 1;
                        } else {
                            // Full exit — release all, then sell
                            self.treasury.release(ctx.quote_asset, pos.quote_held);
                            let (sold, received) = self.treasury.swap(ctx.quote_asset, ctx.base_asset,
                                pos.quote_held, 1.0 / quote_price, fee_rate);
                            pos.base_reclaimed += received;
                            pos.total_fees += sold * quote_price * fee_rate;
                            pos.quote_held = 0.0;
                            pos.phase = PositionPhase::Closed;
                            self.hold_swaps += 1;
                            if pos.return_pct(quote_price) > 0.0 { self.hold_wins += 1; }
                            self.last_exit_price = quote_price;
                            self.last_exit_atr = candles[i].atr_r;
                        }
                    }
                    PositionExit::StopLoss | PositionExit::TakeProfit => {
                        // Full exit — release from deployed, then sell
                        if pos.quote_held > 0.0 {
                            self.treasury.release(ctx.quote_asset, pos.quote_held);
                            let (sold, received) = self.treasury.swap(ctx.quote_asset, ctx.base_asset,
                                pos.quote_held, 1.0 / quote_price, fee_rate);
                            pos.base_reclaimed += received;
                            pos.total_fees += sold * quote_price * fee_rate;
                        }
                        pos.quote_held = 0.0;
                        pos.phase = PositionPhase::Closed;
                        self.hold_swaps += 1;
                        if pos.return_pct(quote_price) > 0.0 { self.hold_wins += 1; }
                        self.last_exit_price = quote_price;
                        self.last_exit_atr = candles[i].atr_r;
                    }
                }
                // Log to ledger
                let ret = pos.return_pct(quote_price);
                let exit_dir = match pos.direction { Direction::Long => "Buy", Direction::Short => "Sell" };
                let exit_type = match (exit, pos.phase) {
                    (PositionExit::TakeProfit, PositionPhase::Runner) => "RunnerTP",
                    (PositionExit::TakeProfit, _) => "PartialProfit",
                    (PositionExit::StopLoss, _) => "StopLoss",
                };
                ctx.ledger.execute(
                    "INSERT INTO trade_ledger (step,candle_idx,timestamp,direction,entry_price,exit_price,gross_return_pct,position_usd,swap_fee_pct,horizon_candles,won,exit_reason)
                     VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12)",
                    rusqlite::params![
                        self.log_step, i as i64, &candles[i].ts,
                        exit_dir, pos.entry_price, quote_price,
                        ret * 100.0, pos.base_deployed,
                        fee_rate * 100.0, pos.candles_held as i64,
                        (ret > 0.0) as i32,
                        exit_type,
                    ],
                ).ok();
            }
        }
        // Remove closed positions
        self.positions.retain(|p| p.phase != PositionPhase::Closed);

        // ── Open new position: manager BUY in proven band ────────
        let in_proven_band = meta_conviction >= self.mgr_proven_band.0
            && meta_conviction < self.mgr_proven_band.1;
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
        let risk_allows = self.cached_risk_mult > 0.3;
        let should_open = ctx.asset_mode == "hold"
            && self.portfolio.phase != Phase::Observe
            && self.mgr_curve_valid && in_proven_band && market_moved && risk_allows
            && (meta_dir == Some(self.mgr_buy) || meta_dir == Some(self.mgr_sell));

        if should_open {
            let expected_move = candles[i].atr_r * 6.0;
            if expected_move > 2.0 * fee_rate {
                let band_edge: f64 = 0.03;
                let frac = ((band_edge / 2.0) * self.cached_risk_mult).min(ctx.max_single_position);
                let dir_label = meta_dir.unwrap();
                let direction = if dir_label == self.mgr_buy { Direction::Long } else { Direction::Short };

                let (from_asset, to_asset, deploy_amount, price_for_swap) = match direction {
                    Direction::Long => {
                        let avail = self.treasury.balance(ctx.base_asset);
                        (ctx.base_asset, ctx.quote_asset, avail * frac, quote_price)
                    }
                    Direction::Short => {
                        let avail = self.treasury.balance(ctx.quote_asset);
                        let amount = avail * frac;
                        (ctx.quote_asset, ctx.base_asset, amount, 1.0 / quote_price)
                    }
                };

                let base_value = if direction == Direction::Long { deploy_amount }
                                 else { deploy_amount * quote_price };

                if base_value > 10.0 {
                    let (spent, received) = self.treasury.swap(
                        from_asset, to_asset, deploy_amount, price_for_swap, fee_rate);

                    // BUY: claim WBTC. SELL: USDC already in balance.
                    if direction == Direction::Long {
                        self.treasury.claim(ctx.quote_asset, received);
                    }

                    let entry_fee = base_value * fee_rate;
                    let (deployed_usd, quote_held) = match direction {
                        Direction::Long => (spent, received),
                        Direction::Short => (spent * quote_price, 0.0),
                    };
                    let pos = ManagedPosition::new(
                        self.next_position_id, i, quote_price, candles[i].atr_r,
                        direction, deployed_usd, quote_held, entry_fee,
                        ctx.k_stop, ctx.k_tp,
                    );
                    self.next_position_id += 1;
                    self.hold_swaps += 1;
                    let dir_str = if direction == Direction::Long { "Buy" } else { "Sell" };
                    ctx.ledger.execute(
                        "INSERT INTO trade_ledger (step,candle_idx,timestamp,direction,entry_price,position_usd,swap_fee_pct,exit_reason)
                         VALUES (?1,?2,?3,?4,?5,?6,?7,'Open')",
                        rusqlite::params![self.log_step, i as i64, &candles[i].ts, dir_str, quote_price, base_value, fee_rate * 100.0],
                    ).ok();
                    self.positions.push(pos);
                }
            }
        }

        // Position sizing: Kelly from the curve × drawdown cap.
        // The curve handles selectivity. The drawdown cap handles survival.
        // Nothing else. No graduated gate, no stability gate, no phase gate.
        // Risk branch: compute only at recalib intervals (not every candle).
        // Between recalibs, reuse the last risk_mult.
        if self.encode_count % ctx.recalib_interval == 0 || self.encode_count < 100 {
            let branch_features = self.portfolio.risk_branch_wat(ctx.vm, ctx.risk_scalar);
            let mut worst_ratio = 1.0_f64;
            let healthy = self.portfolio.is_healthy() && self.portfolio.trades_taken >= 20;
            for (bi, branch) in self.risk_branches.iter_mut().enumerate() {
                let features = &branch_features[bi];
                if branch.subspace.n() >= 10 {
                    let residual = branch.subspace.residual(features);
                    let threshold = branch.subspace.threshold();
                    let ratio = if residual < threshold { 1.0 }
                        else { (threshold / residual).max(0.1) };
                    worst_ratio = worst_ratio.min(ratio);
                }
                if healthy { branch.subspace.update(features); }
            }
            self.cached_risk_mult = if self.risk_branches[0].subspace.n() >= 10 {
                worst_ratio
            } else { 0.5 };
        }
        let risk_mult = self.cached_risk_mult;

        // The treasury doesn't move until the portfolio has proven edge.
        // Two requirements:
        // 1. Past the observe period (enough data to form a discriminant)
        // 2. Curve is valid (the conviction-accuracy relationship exists)
        // Before both are met, predictions are hypothetical — recorded in the
        // ledger but the treasury withholds capital.
        let portfolio_proven = self.portfolio.phase != Phase::Observe && self.mgr_curve_valid;
        let position_frac = if meta_dir.is_some()
            && portfolio_proven
            && (self.conviction_threshold <= 0.0 || meta_conviction >= self.conviction_threshold)
        {
            let mt = if ctx.atr_multiplier > 0.0 {
                ctx.atr_multiplier * candles[i].atr_r
            } else { ctx.move_threshold };

            match ctx.sizing {
                "kelly" => {
                    // Fast path: evaluate cached curve params. No sorting.
                    let kelly_result = if self.curve_valid && self.cached_curve_b > 0.0 {
                        let win_rate = (0.50 + self.cached_curve_a * (self.cached_curve_b * meta_conviction).exp()).min(0.95);
                        let edge = 2.0 * win_rate - 1.0;
                        if edge > 0.0 {
                            let half_kelly_risk = edge / 2.0;
                            Some(half_kelly_risk / mt)
                        } else { None }
                    } else { None };
                    match kelly_result {
                        Some(frac) => {
                            let frac = frac.min(1.0);
                            let dd = if self.peak_treasury_equity > 0.0 {
                                (self.peak_treasury_equity - treasury_equity) / self.peak_treasury_equity
                            } else { 0.0 };
                            let dd_room = (ctx.max_drawdown - dd).max(0.0);
                            let cap = (dd_room / (4.0 * mt)).min(1.0);
                            let sized = frac.min(cap) * risk_mult;
                            // NEVER zero. Always learn. Minimum 1% position.
                            // The wat machine never quits — it gets quiet.
                            let min_bet = 0.01;
                            Some(sized.max(min_bet))
                        }
                        None => None
                    }
                }
                _ => {
                    // Legacy sizing with flip zone gate
                    if self.conviction_threshold > 0.0 && meta_conviction < self.conviction_threshold {
                        None
                    } else {
                        self.portfolio.position_frac(meta_conviction, ctx.min_conviction, self.conviction_threshold)
                    }
                }
            }
        } else { None };

        // decomplect:allow(braided-concerns) — open_position reserves capital on Pending path, ManagedPosition claims/swaps separately. Two accounting paths for one trade. Unify when position lifecycle is refactored.
        // Treasury allocation: reserve capital for this position.
        let deployed_usd = if let Some(frac) = position_frac {
            self.treasury.open_position(self.treasury.allocatable() * frac)
        } else {
            0.0
        };

        self.pending.push_back(Pending {
            candle_idx:    i,
            year:          candles[i].year,
            tht_vec,
            tht_pred:      tht_pred.clone(),
            meta_dir,
            high_conviction:   self.conviction_threshold > 0.0 && meta_conviction >= self.conviction_threshold,
            meta_conviction,
            position_frac,
            observer_vecs,
            observer_preds,
            mgr_thought:   stored_mgr_thought,
            fact_labels:   if ctx.diagnostics { tht_facts } else { Vec::new() },
            first_outcome: None,
            outcome_pct:   0.0,
            entry_price:       candles[i].close,
            max_favorable:     0.0,
            max_adverse:       0.0,
            crossing_candle:   None,
            path_candles:      0,
            trailing_stop:     -(ctx.k_stop * candles[i].atr_r), // stop at K× ATR from this candle
            exit_reason:       None,
            exit_pct:          0.0,
            deployed_usd,
        });

        // Decay once per candle.
        self.tht_journal.decay(self.adaptive_decay);
        self.mgr_journal.decay(self.adaptive_decay);
        for observer in &mut self.observers {
            observer.journal.decay(ctx.decay);
        }

        // ── Event-driven learning ─────────────────────────────────────
        // Snapshot recalib counts before scanning so we can detect if
        // any recalibration fired during this candle's learning.
        let tht_recalib_before = self.tht_journal.recalib_count();

        let current_price = candles[i].close;
        for entry in self.pending.iter_mut() {
            let entry_price = candles[entry.candle_idx].close;
            let pct         = (current_price - entry_price) / entry_price;
            let abs_pct     = pct.abs();

            entry.path_candles = i - entry.candle_idx;

            // Track directional excursion relative to predicted direction.
            let directional_pct = if entry.meta_dir == Some(self.tht_buy) {
                pct
            } else if entry.meta_dir == Some(self.tht_sell) {
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

            // ── Trade management: trailing stop + take profit ────────
            // Each trade has its own parameters from ATR at entry time.
            // No averaging. No calcification. The market at entry tells
            // each trade how much room it needs.
            //
            // Managed exits: the market closes the trade, not the clock.
            if entry.exit_reason.is_none()
                && entry.position_frac.is_some()
                && self.portfolio.phase != Phase::Observe
            {
                // This trade's ATR at entry — how volatile was the market when we entered?
                let entry_atr = candles[entry.candle_idx].atr_r;

                // Raise the floor: trail follows favorable movement.
                let trail = ctx.k_trail * entry_atr;
                let new_stop = entry.max_favorable - trail;
                if new_stop > entry.trailing_stop {
                    entry.trailing_stop = new_stop;
                }

                // Check exits (priority: take profit > stop loss)
                let tp = ctx.k_tp * entry_atr;
                if directional_pct >= tp {
                    entry.exit_reason = Some(ExitReason::TakeProfit);
                    entry.exit_pct = pct;
                } else if directional_pct <= entry.trailing_stop {
                    entry.exit_reason = Some(ExitReason::TrailingStop);
                    entry.exit_pct = pct;
                }
            }

            // Learn only on the first threshold crossing per pending entry.
            if entry.first_outcome.is_none() {
                let thresh = if ctx.atr_multiplier > 0.0 {
                    let entry_atr = candles[entry.candle_idx].atr_r;
                    ctx.atr_multiplier * entry_atr
                } else {
                    ctx.move_threshold
                };
                let outcome = if pct > thresh       { Some(self.tht_buy)  }
                              else if pct < -thresh { Some(self.tht_sell) }
                              else                  { None };

                if let Some(o) = outcome {
                    entry.crossing_candle = Some(i);
                    let sw = signal_weight(abs_pct, &mut self.move_sum, &mut self.move_count);
                    self.tht_journal.observe(&entry.tht_vec, o, sw);
                    // Manager does NOT learn here. Manager learns Buy/Sell (direction)
                    // at first-crossing in the resolution block below.
                    // wat/manager.wat: "Does NOT know about costs."
                    // Observer resolution: learn, track, gate, validate, log.
                    // Each observer resolves its prediction against the outcome.
                    for (ei, expert_vec) in entry.observer_vecs.iter().enumerate() {
                        if let Some(log) = self.observers[ei].resolve(
                            expert_vec, &entry.observer_preds[ei], o, sw,
                            ctx.conviction_quantile, ctx.conviction_window,
                        ) {
                            if ctx.diagnostics { ctx.ledger.execute(
                                "INSERT INTO observer_log (step,observer,conviction,direction,correct)
                                 VALUES (?1,?2,?3,?4,?5)",
                                params![self.log_step, log.name, log.conviction,
                                        self.observers[ei].journal.label_name(log.direction).unwrap_or("?"), log.correct as i32],
                            ).ok(); }
                        }
                    }
                    entry.first_outcome = Some(o);
                    entry.outcome_pct   = pct;
                }
            }
        }

        // Log any recalibrations that fired during this candle's learning.
        if self.tht_journal.recalib_count() != tht_recalib_before {
            // Pre-compute curve params for Kelly — once per recalib, not per trade.
            // Uses the generalist's resolved_preds for the curve fit.
            if let Some((_, a, b)) = kelly_frac(0.15, &self.resolved_preds, 50,
                if ctx.atr_multiplier > 0.0 { ctx.atr_multiplier * candles[i].atr_r } else { ctx.move_threshold }) {
                self.cached_curve_a = a;
                self.cached_curve_b = b;
                self.curve_valid = true;
            }
            // Manager's own proof: band-based, not exponential.
            // decomplect:allow(inline-computation) — manager band proof, extracts to market/manager.rs
            // Find the conviction band where accuracy > 51% with 500+ samples.
            // The sweet spot is at 5-10σ (geometric property of dims).
            // The manager acts only in its proven band.
            if self.mgr_resolved.len() >= 500 {
                let sigma = 1.0 / (ctx.dims as f64).sqrt();
                // Scan bands: [k*sigma, (k+2)*sigma] for k in 3..20
                let mut best_acc = 0.5_f64;
                let mut best_band = (0.0_f64, 0.0_f64);
                for k in (3..18).step_by(1) {
                    let lo = k as f64 * sigma;
                    let hi = (k + 4) as f64 * sigma; // 4σ wide bands
                    let in_band: Vec<&(f64, bool)> = self.mgr_resolved.iter()
                        .filter(|(c, _)| *c >= lo && *c < hi).collect();
                    let n = in_band.len();
                    if n >= 200 {
                        let acc = in_band.iter().filter(|(_, c)| *c).count() as f64 / n as f64;
                        if acc > best_acc {
                            best_acc = acc;
                            best_band = (lo, hi);
                        }
                    }
                }
                if best_acc > 0.51 {
                    self.mgr_curve_valid = true;
                    self.mgr_proven_band = best_band;
                } else {
                    self.mgr_curve_valid = false;
                    self.mgr_proven_band = (0.0, 0.0);
                }
            }

            // Feed panel engram: if recent panel accuracy was good, store current state.
            if self.panel_recalib_total >= 10 {
                let acc = self.panel_recalib_wins as f64 / self.panel_recalib_total as f64;
                if acc > 0.55 {
                    self.panel_engram.update(&panel_state);
                }
            }
            self.panel_recalib_wins = 0;
            self.panel_recalib_total = 0;

            ctx.ledger.execute(
                "INSERT INTO recalib_log (step,journal,cos_raw,disc_strength,buy_count,sell_count)
                 VALUES (?1,?2,?3,?4,?5,?6)",
                params![
                    self.encode_count as i64, "thought",
                    self.tht_journal.last_cos_raw(), self.tht_journal.last_disc_strength(),
                    self.tht_journal.label_count(self.tht_buy) as i64, self.tht_journal.label_count(self.tht_sell) as i64,
                ],
            ).ok();

            // Decode thought discriminant against the fact codebook.
            if let Some(disc) = self.tht_journal.discriminant(self.tht_buy) {
                let disc_vec = Vector::from_f64(disc);
                let mut decoded: Vec<(String, f64)> = ctx.codebook_vecs.iter().zip(ctx.codebook_labels.iter())
                    .map(|(v, l)| (l.clone(), holon::Similarity::cosine(&disc_vec, v)))
                    .collect();
                decoded.sort_by(|a, b| b.1.abs().partial_cmp(&a.1.abs()).unwrap());
                for (rank, (label, cos)) in decoded.iter().take(20).enumerate() {
                    ctx.ledger.execute(
                        "INSERT INTO disc_decode (step,journal,rank,fact_label,cosine)
                         VALUES (?1,?2,?3,?4,?5)",
                        params![
                            self.encode_count as i64, "thought",
                            (rank + 1) as i64, label, cos,
                        ],
                    ).ok();
                }
            }

        }

        // ── Resolve entries: managed exit OR horizon expiry ──────────
        // Horizon is the safety valve, not the exit strategy.
        // The market closes the trade (stop/TP). The horizon only controls
        // learning labels. Safety max (10× horizon) prevents unbounded queue growth.
        let max_pending_age = ctx.horizon * 10;
        let mut resolved_indices: Vec<usize> = Vec::new();
        for (qi, entry) in self.pending.iter().enumerate() {
            let age = i - entry.candle_idx;
            let safety_expired = age >= max_pending_age;
            let market_exited = entry.exit_reason.is_some();
            if safety_expired || market_exited {
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
            // Set exit reason for horizon expiry if not already managed-exited.
            if entry.exit_reason.is_none() {
                entry.exit_reason = Some(ExitReason::HorizonExpiry);
                // Exit at current price for horizon expiry
                let entry_price = candles[entry.candle_idx].close;
                entry.exit_pct = (current_price - entry_price) / entry_price;
            }
            let final_out: Option<Label> = entry.first_outcome;
            let entry_candle = &candles[entry.candle_idx];

            if final_out.is_none() {
                self.noise_count += 1;
            } else {
                self.labeled_count += 1;
            }

            // Rolling accuracy per journal (non-Noise only).
            if let Some(outcome) = final_out {
                if let Some(td) = entry.tht_pred.direction {
                    let ok = td == outcome;
                    self.tht_rolling.push_back(ok);
                    if self.tht_rolling.len() > ctx.rolling_cap { self.tht_rolling.pop_front(); }
                }

                // ── Manager learns from ALL non-Noise outcomes ──────────
                // The manager doesn't need meta_dir to learn. It needs to
                // see the expert configuration + whether following the experts
                // would have been profitable. Breaks the deadlock: the manager
                // learns even when it has no opinion of its own yet.
                {
                    // Hypothetical: if we followed the majority expert direction,
                    // would it have been profitable after costs?
                    let expert_majority = {
                        let buys = entry.observer_preds.iter()
                            .filter(|ep| ep.direction == Some(self.tht_buy)).count();
                        let sells = entry.observer_preds.iter()
                            .filter(|ep| ep.direction == Some(self.tht_sell)).count();
                        if buys > sells { Some(self.tht_buy) }
                        else if sells > buys { Some(self.tht_sell) }
                        else { None }
                    };
                    if expert_majority.is_some() {
                        // Manager learns raw price direction from intensity patterns.
                        // Not "was the expert majority right?" but "did the price go up or down?"
                        // The manager maps intensity patterns → direction.
                        // Both sides are learned: the same intensity pattern that preceded UP
                        // teaches the Buy accumulator; the same pattern that preceded DOWN
                        // teaches the Sell accumulator. The discriminant separates.
                        let price_change = (current_price - candles[entry.candle_idx].close)
                            / candles[entry.candle_idx].close;
                        let mgr_label = if price_change > 0.0 { self.mgr_buy } else { self.mgr_sell };

                        // Learn from the SAME thought the manager predicted with.
                        // Stored at prediction time, delta-enriched. One encoding path.
                        if let Some(ref mgr_vec) = entry.mgr_thought {
                            self.mgr_journal.observe(mgr_vec, mgr_label, 1.0);
                        }

                        // Track for proof gate: did the manager predict the right direction?
                        // The manager predicts Buy (price up) or Sell (price down) from
                        // intensity patterns. If its prediction matches the actual direction,
                        // that's a correct call — proof the intensity pattern is useful.
                        let mgr_correct = if let Some(mgr_dir) = entry.meta_dir {
                            mgr_dir == mgr_label // manager predicted the actual direction
                        } else {
                            false // no prediction = not correct
                        };
                        self.mgr_resolved.push_back((entry.meta_conviction, mgr_correct));
                        if self.mgr_resolved.len() > 5000 { self.mgr_resolved.pop_front(); }
                        self.resolved_preds.push_back((entry.meta_conviction, mgr_correct));
                        if self.resolved_preds.len() > ctx.conviction_window {
                            self.resolved_preds.pop_front();
                        }
                    }
                }
            }

            // Every prediction goes to the ledger — hypothetical or real.
            // Traders predict on paper. The treasury decides whether to act.
            // The paper trail is how traders prove themselves.
            if let Some(dir) = entry.meta_dir {
                let frac = entry.position_frac.unwrap_or(0.0);
                let is_live = frac > 0.0; // treasury committed capital

                let trade_pct = entry.exit_pct;
                {
                    // ── Accounting: compute P&L (real or hypothetical) ────
                    let gross_ret = if dir == self.mgr_buy { trade_pct }
                        else { -trade_pct };
                    let per_swap = ctx.swap_fee + ctx.slippage;
                    let after_entry = 1.0 - per_swap;
                    let gross_value = after_entry * (1.0 + gross_ret);
                    let after_exit = gross_value * (1.0 - per_swap);
                    let net_ret = after_exit - 1.0;
                    let entry_cost_frac = per_swap;
                    let exit_cost_frac = gross_value * per_swap;

                    // Position value: real if live, hypothetical if paper
                    let pos_usd = if is_live {
                        if entry.deployed_usd > 0.0 { entry.deployed_usd }
                        else { treasury_equity * frac }
                    } else { 0.0 };
                    let trade_pnl = pos_usd * net_ret;

                    // Manager learns direction only, at first-crossing time (above).
                    // wat/manager.wat: "Does NOT know about costs."
                    // Profitability is the treasury's domain, not the manager's.

                    // ── Treasury: only moves money for live trades ───────
                    if is_live {
                        let trade_fees = pos_usd * (ctx.swap_fee * 2.0);
                        let trade_slip = pos_usd * (ctx.slippage * 2.0);
                        let trade_dir = if dir == self.mgr_buy { Direction::Long } else { Direction::Short };
                        self.portfolio.record_trade(trade_pct, frac, trade_dir, entry.year,
                                            ctx.swap_fee, ctx.slippage);
                        self.treasury.close_position(entry.deployed_usd,
                            pos_usd * gross_ret, trade_fees, trade_slip);
                    }

                    // ── Ledger: ALWAYS records. Paper trail for all. ─────
                    let exit_candle = entry.crossing_candle;
                    let exit_ts = exit_candle.map(|ci| candles[ci].ts.clone());
                    let exit_price = exit_candle.map(|ci| candles[ci].close)
                        .unwrap_or(candles[i].close);
                    let crossing_elapsed = entry.crossing_candle
                        .map(|ci| (ci - entry.candle_idx) as i64);
                    ctx.ledger.execute(
                        "INSERT INTO trade_ledger
                         (step,candle_idx,timestamp,exit_candle_idx,exit_timestamp,
                          direction,conviction,high_conviction,
                          entry_price,exit_price,position_frac,position_usd,
                          gross_return_pct,swap_fee_pct,slippage_pct,net_return_pct,
                          pnl_usd,equity_after,
                          max_favorable_pct,max_adverse_pct,
                          crossing_candles,horizon_candles,outcome,won,exit_reason)
                         VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20,?21,?22,?23,?24,?25)",
                        params![
                            self.log_step, entry.candle_idx as i64, &entry_candle.ts,
                            exit_candle.map(|ci| ci as i64), exit_ts,
                            self.mgr_journal.label_name(dir).unwrap_or("?"), entry.meta_conviction,
                            entry.high_conviction as i32,
                            entry.entry_price, exit_price,
                            frac, pos_usd,
                            gross_ret * 100.0,
                            entry_cost_frac * 100.0,
                            exit_cost_frac * 100.0,
                            net_ret * 100.0, trade_pnl, treasury_equity,
                            entry.max_favorable * 100.0, entry.max_adverse * 100.0,
                            crossing_elapsed, entry.path_candles as i64,
                            final_out.map(|l| self.tht_journal.label_name(l).unwrap_or("?").to_string()).unwrap_or_else(|| "Noise".to_string()), (net_ret > 0.0) as i32,
                            match entry.exit_reason {
                                Some(ExitReason::TrailingStop) => "TrailingStop",
                                Some(ExitReason::TakeProfit) => "TakeProfit",
                                Some(ExitReason::HorizonExpiry) => "HorizonExpiry",
                                None => "HorizonExpiry",
                            },
                        ],
                    ).ok();

                    // Panel tracking (all predictions, not just live)
                    self.panel_recalib_total += 1;
                    if final_out == Some(dir) { self.panel_recalib_wins += 1; }

                    // resolved_preds is populated at first-crossing time (direction
                    // accuracy only). No second push here — the calibration curve
                    // must not mix direction and profitability signals.

                    // ── Risk/diagnostics: only for live trades ───────────
                    if is_live {
                            let dd = if self.peak_treasury_equity > 0.0 {
                                (self.peak_treasury_equity - treasury_equity) / self.peak_treasury_equity * 100.0
                            } else { 0.0 };
                            let (streak_len, streak_dir) = {
                                let mut len = 0i32;
                                if let Some(&last) = self.portfolio.rolling.back() {
                                    for &o in self.portfolio.rolling.iter().rev() {
                                        if o == last { len += 1; } else { break; }
                                    }
                                }
                                let dir = if self.portfolio.rolling.back() == Some(&true) { "winning" } else { "losing" };
                                (len, dir)
                            };
                            let recent_acc = if self.portfolio.rolling.len() >= 5 {
                                self.portfolio.rolling.iter().filter(|&&x| x).count() as f64
                                    / self.portfolio.rolling.len() as f64
                            } else { 0.5 };
                            let eq_pct = (treasury_equity - ctx.initial_equity) / ctx.initial_equity * 100.0;
                            let won = (final_out == Some(dir)) as i32;
                            if ctx.diagnostics { ctx.ledger.execute(
                                "INSERT INTO risk_log (step,drawdown_pct,streak_len,streak_dir,recent_acc,equity_pct,won)
                                 VALUES (?1,?2,?3,?4,?5,?6,?7)",
                                params![self.log_step, dd, streak_len, streak_dir, recent_acc, eq_pct, won],
                            ).ok(); }
                        // Track flip-zone trade outcomes.
                        if entry.high_conviction {
                            // Adaptive decay state machine.
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
                        // Log which facts were present for this trade.
                        for label in &entry.fact_labels {
                            if ctx.diagnostics { ctx.ledger.execute(
                                "INSERT INTO trade_facts (step, fact_label) VALUES (?1, ?2)",
                                params![self.log_step, label],
                            ).ok(); }
                        }
                        // Store thought vectors for engram analysis.
                        if entry.high_conviction {
                            let won = (final_out == Some(dir)) as i32;
                            let tht_bytes: Vec<u8> = entry.tht_vec.data().iter()
                                .map(|&v| v as u8).collect();
                            if ctx.diagnostics { ctx.ledger.execute(
                                "INSERT INTO trade_vectors (step, won, tht_data)
                                 VALUES (?1, ?2, ?3)",
                                params![
                                    self.log_step, won,
                                    tht_bytes,
                                ],
                            ).ok(); }
                        }
                    } // is_live
                }
            } // if let Some(dir)

            // Log to ledger.
            ctx.ledger.execute(
                "INSERT INTO candle_log
                 (step,candle_idx,timestamp,
                  tht_cos,tht_conviction,tht_pred,
                  meta_pred,meta_conviction,
                  actual,traded,position_frac,equity,outcome_pct)
                 VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13)",
                params![
                    self.log_step, entry.candle_idx as i64, &entry_candle.ts,
                    entry.tht_pred.raw_cos, entry.tht_pred.conviction,
                    entry.tht_pred.direction.and_then(|d| self.tht_journal.label_name(d).map(|s| s.to_string())),
                    entry.meta_dir.and_then(|d| self.mgr_journal.label_name(d).map(|s| s.to_string())),
                    entry.meta_conviction,
                    final_out.and_then(|l| self.tht_journal.label_name(l).map(|s| s.to_string())).unwrap_or_else(|| "Noise".to_string()),
                    entry.position_frac.is_some() as i32,
                    entry.position_frac,
                    treasury_equity,
                    entry.outcome_pct,
                ],
            ).ok();
            self.log_step   += 1;
            self.db_batch   += 1;
            if self.db_batch >= 5_000 {
                ctx.ledger.execute_batch("COMMIT; BEGIN").ok();
                self.db_batch = 0;
            }

            self.portfolio.tick_observe();
        }

        // ── Progress line ─────────────────────────────────────────────
        if self.encode_count % ctx.progress_every == 0 {
            let elapsed = ctx.t_start.elapsed().as_secs_f64();
            let rate    = self.encode_count as f64 / elapsed;
            let eta     = (ctx.loop_count - self.encode_count) as f64 / rate;
            let tht_acc = if self.tht_rolling.is_empty() { 0.0 }
                else { self.tht_rolling.iter().filter(|&&x| x).count() as f64 / self.tht_rolling.len() as f64 * 100.0 };
            let ret = (treasury_equity - ctx.initial_equity) / ctx.initial_equity * 100.0;
            let bnh = (candles[i].close - ctx.bnh_entry) / ctx.bnh_entry * 100.0;
            let atr_now = candles[i].atr_r;
            let exit_info = format!(" | ATR={:.2}% sl={:.2}% tp={:.2}% tr={:.2}% open={}",
                atr_now * 100.0,
                ctx.k_stop * atr_now * 100.0,
                ctx.k_tp * atr_now * 100.0,
                ctx.k_trail * atr_now * 100.0,
                self.treasury.n_open);
            eprintln!(
                "  {}/{} ({:.0}/s ETA {:.0}s) | {} | {} | tht={:.1}% | trades={} win={:.1}% | ${:.0} ({:+.1}%) vs B&H {:+.1}% | flip@{:.3} {}{}",
                self.encode_count, ctx.loop_count, rate, eta,
                &candles[i].ts[..10],
                self.portfolio.phase,
                tht_acc,
                self.portfolio.trades_taken, self.portfolio.win_rate(),
                treasury_equity, ret, bnh,
                self.conviction_threshold,
                if !self.mgr_curve_valid { "CALIBRATING" }
                else if panel_familiar { "ENGRAM" }
                else if self.in_adaptation { "ADAPT" }
                else { "STABLE" },
                exit_info,
            );
            if ctx.asset_mode == "hold" {
                let mut proven: Vec<&str> = self.observers.iter()
                    .filter(|e| e.curve_valid).map(|e| e.name).collect();
                if self.curve_valid { proven.push("generalist"); }
                let proven_str = if proven.is_empty() { "none".to_string() }
                    else { proven.join(",") };
                let band_str = if self.mgr_curve_valid {
                    format!(" band=[{:.3},{:.3}]", self.mgr_proven_band.0, self.mgr_proven_band.1)
                } else { " band=none".to_string() };
                eprintln!("    treasury: ${:.0} ({:+.1}%) | pos={} swaps={} wins={} | proven=[{}]{}",
                    treasury_equity, ret, self.positions.len(), self.hold_swaps, self.hold_wins, proven_str, band_str);
            }
        }
    }
}
