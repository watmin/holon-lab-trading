//! EnterpriseState — the mutable state of the enterprise heartbeat.
//!
//! Everything the main loop mutates, packaged into one struct.
//! Created once at startup, threaded through the heartbeat.
//! enterprise.rs orchestrates; this module holds what changes.

use std::collections::VecDeque;

use holon::memory::{Journal, OnlineSubspace};
use holon::{Primitives, ScalarEncoder, ScalarMode, VectorManager, Vector};

use crate::candle::Candle;
use crate::ledger::LogEntry;
use crate::event::EnrichedEvent;
use crate::journal::{Label, Direction, Prediction, register_direction, register_exit};
use crate::window_sampler::WindowSampler;
use crate::market::observer::Observer;
use crate::market::manager::{ManagerAtoms, ManagerContext, encode_manager_thought, find_proven_band};
use crate::portfolio::{Phase, Portfolio};
use crate::position::{CrossingSnapshot, ExitObservation, ExitReason, ManagedPosition, Pending, PositionEntry, PositionExit, PositionPhase, TrailFactor};
use crate::risk::{self, RiskBranch};
use crate::sizing::{curve_win_rate, half_kelly_position, kelly_frac, signal_weight};
use crate::treasury::{Asset, Treasury};

/// The generalist observer always lives at this index in the observers array.
/// Named constant replaces magic `5` scattered across state.rs and enterprise.rs.
pub const GENERALIST_IDX: usize = 5;

/// Maximum base position fraction before risk scaling.
/// Derived from typical proven-band edge (~3% of portfolio at full conviction).
const MAX_BASE_POSITION: f64 = 0.03;

/// Seed prime for observer window samplers — spreads them across the hash space.
const OBSERVER_SEED_PRIME: u64 = 7919;
/// Minimum position size as fraction of equity. The enterprise never fully stops betting.
const MIN_BET: f64 = 0.01;
/// Risk multiplier threshold — below this, no new positions.
const RISK_GATE_THRESHOLD: f64 = 0.3;
/// Minimum candles encoded before risk branch evaluation begins.
const RISK_WARMUP: usize = 100;
/// Minimum accuracy for panel engram snapshot during recalibration.
const PANEL_ENGRAM_MIN_ACC: f64 = 0.55;
/// Minimum resolved panel predictions before engram gating applies.
const PANEL_ENGRAM_MIN_TOTAL: u32 = 10;

// ─── Mode enums ───────────────────────────────────────────────────────────

/// Conviction threshold strategy: fixed quantile or auto-discovered edge.
#[derive(Debug, Clone, Copy, PartialEq, Eq, clap::ValueEnum)]
pub enum ConvictionMode {
    /// Use conviction_quantile percentile as the flip threshold.
    Quantile,
    /// Find the conviction level where cumulative win rate first drops below min_edge.
    Auto,
}

impl std::fmt::Display for ConvictionMode {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ConvictionMode::Quantile => write!(f, "quantile"),
            ConvictionMode::Auto => write!(f, "auto"),
        }
    }
}

/// Position sizing strategy.
#[derive(Debug, Clone, Copy, PartialEq, Eq, clap::ValueEnum)]
pub enum SizingMode {
    /// Phase-based with 5% cap.
    Legacy,
    /// Half-Kelly from calibration curve.
    Kelly,
}

impl std::fmt::Display for SizingMode {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            SizingMode::Legacy => write!(f, "legacy"),
            SizingMode::Kelly => write!(f, "kelly"),
        }
    }
}

/// Asset holding model.
#[derive(Debug, Clone, Copy, PartialEq, Eq, clap::ValueEnum)]
pub enum AssetMode {
    /// USDC→WBTC→USDC per trade (two swaps per round trip).
    RoundTrip,
    /// Treasury holds WBTC between BUY signals (one swap per signal).
    Hold,
}

impl std::fmt::Display for AssetMode {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            AssetMode::RoundTrip => write!(f, "round-trip"),
            AssetMode::Hold => write!(f, "hold"),
        }
    }
}

// ─── TradePnl ─────────────────────────────────────────────────────────────

/// Pure accounting result for a resolved trade. No side effects.
/// Computed once, consumed by treasury settlement and ledger logging.
pub struct TradePnl {
    pub gross_ret: f64,
    pub net_ret: f64,
    pub entry_cost_frac: f64,
    pub exit_cost_frac: f64,
    pub pos_usd: f64,
    pub trade_pnl: f64,
}

impl TradePnl {
    /// Compute P&L for a resolved entry. Pure arithmetic.
    pub fn compute(
        trade_pct: f64,
        is_buy: bool,
        swap_fee: f64,
        slippage: f64,
        is_live: bool,
        deployed_usd: f64,
        treasury_equity: f64,
        frac: f64,
    ) -> Self {
        let gross_ret = if is_buy { trade_pct } else { -trade_pct };
        let per_swap = swap_fee + slippage;
        let after_entry = 1.0 - per_swap;
        let gross_value = after_entry * (1.0 + gross_ret);
        let after_exit = gross_value * (1.0 - per_swap);
        let net_ret = after_exit - 1.0;
        let entry_cost_frac = per_swap;
        let exit_cost_frac = gross_value * per_swap;
        let pos_usd = if is_live {
            if deployed_usd > 0.0 { deployed_usd } else { treasury_equity * frac }
        } else { 0.0 };
        let trade_pnl = pos_usd * net_ret;
        Self { gross_ret, net_ret, entry_cost_frac, exit_cost_frac, pos_usd, trade_pnl }
    }
}

// ─── ExitAtoms ─────────────────────────────────────────────────────────────

// rune:scry(aspirational) — exit.wat specifies the exit expert modulates k_trail per position
// per candle based on its Hold/Exit prediction (Exit → tighten trail, Hold → loosen trail).
// Code only buffers ExitObservation and learns labels but never reads the exit expert's
// prediction to adjust trailing stops. The exit expert learns but does not yet act.

/// Immutable atom vectors for the exit expert encoding.
pub struct ExitAtoms {
    pub pnl: Vector,
    pub hold: Vector,
    pub mfe: Vector,
    pub mae: Vector,
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

impl ExitAtoms {
    pub fn new(vm: &VectorManager) -> Self {
        Self {
            pnl: vm.get_vector("position-pnl"),
            hold: vm.get_vector("position-hold"),
            mfe: vm.get_vector("position-mfe"),
            mae: vm.get_vector("position-mae"),
            atr_entry: vm.get_vector("position-atr-entry"),
            atr_now: vm.get_vector("position-atr-now"),
            stop_dist: vm.get_vector("position-stop-dist"),
            phase: vm.get_vector("position-phase"),
            direction: vm.get_vector("position-direction"),
            runner: vm.get_vector("runner"),
            active: vm.get_vector("active"),
            buy: vm.get_vector("buy"),
            sell: vm.get_vector("sell"),
        }
    }
}

/// Encode a single exit-expert thought from position state + current market.
///
/// Nine facts: pnl, hold duration, MFE, MAE, ATR at entry, ATR now, stop distance,
/// position phase, and direction — bundled into one vector.
pub fn encode_exit_thought(
    pos: &ManagedPosition,
    pnl_frac: f64,
    current_rate: f64,
    exit_atoms: &ExitAtoms,
    exit_scalar: &ScalarEncoder,
    candle_atr: f64,
    is_buy: bool,
) -> Vector {
    // MFE in rate space: how far did the rate go in our favor?
    let mfe_frac = (pos.extreme_rate - pos.entry_rate) / pos.entry_rate;
    // Stop distance in rate space
    let stop_dist = (pos.trailing_stop - current_rate).abs() / current_rate;

    Primitives::bundle(&[
        &Primitives::bind(&exit_atoms.pnl, &exit_scalar.encode(pnl_frac.clamp(-1.0, 1.0) * 0.5 + 0.5, ScalarMode::Linear { scale: 1.0 })),
        &Primitives::bind(&exit_atoms.hold, &exit_scalar.encode_log(pos.candles_held as f64)),
        &Primitives::bind(&exit_atoms.mfe, &exit_scalar.encode(mfe_frac.clamp(0.0, 1.0), ScalarMode::Linear { scale: 1.0 })),
        &Primitives::bind(&exit_atoms.mae, &exit_scalar.encode(pos.max_adverse.clamp(-1.0, 0.0).abs(), ScalarMode::Linear { scale: 1.0 })),
        &Primitives::bind(&exit_atoms.atr_entry, &exit_scalar.encode_log(pos.entry_atr.max(1e-10))),
        &Primitives::bind(&exit_atoms.atr_now, &exit_scalar.encode_log(candle_atr.max(1e-10))),
        &Primitives::bind(&exit_atoms.stop_dist, &exit_scalar.encode(stop_dist.clamp(0.0, 1.0), ScalarMode::Linear { scale: 1.0 })),
        &Primitives::bind(&exit_atoms.phase, if pos.phase == PositionPhase::Runner { &exit_atoms.runner } else { &exit_atoms.active }),
        &Primitives::bind(&exit_atoms.direction, if is_buy { &exit_atoms.buy } else { &exit_atoms.sell }),
    ])
}

// ─── CandleContext ─────────────────────────────────────────────────────────

/// Immutable references needed by on_candle but owned by main().
/// Bundles config, atoms, encoders, and the ledger — everything
/// the sequential body reads but never writes.
// 40+ fields; functions read 2-5 each. Immutable context — passing it whole is honest, not hidden coupling.
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
    pub conviction_mode: ConvictionMode,
    pub min_edge: f64,
    pub sizing: SizingMode,
    pub max_drawdown: f64,
    pub swap_fee: f64,
    pub slippage: f64,
    pub asset_mode: AssetMode,
    pub base_asset: &'a Asset,
    pub quote_asset: &'a Asset,
    pub initial_equity: f64,
    pub diagnostics: bool,

    // ── Exit parameters ─────────────────────────────────────────────────
    pub k_stop: f64,
    pub k_trail: f64,
    pub k_tp: f64,
    pub exit_horizon: usize,
    pub exit_observe_interval: usize,

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
    pub observer_names: &'a [crate::market::Lens],
    pub generalist_atom: &'a Vector,
    pub min_opinion_magnitude: f64,

    // ── Codebook for discriminant decode ────────────────────────────────
    pub codebook_labels: &'a [String],
    pub codebook_vecs: &'a [Vector],

    // ── Progress display ────────────────────────────────────────────────
    pub bnh_entry: f64,
    pub loop_count: usize,
    pub progress_every: usize,
    pub t_start: std::time::Instant,
}

// ─── EnterpriseState ────────────────────────────────────────────────────────

pub struct EnterpriseState {
    // ── Learning: journals + labels ──────────────────────────────────────
    // The generalist journal is observers[GENERALIST_IDX] ("generalist" profile).
    // Access via self.generalist().journal / self.generalist().primary_label.

    pub mgr_journal: Journal,
    pub mgr_buy: Label,
    pub mgr_sell: Label,
    pub prev_mgr_thought: Option<Vector>,

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
    pub kelly_curve_valid: bool,
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
    // Rolling accuracy lives on the generalist observer (observers[GENERALIST_IDX].resolved).

    // ── Conviction + flip threshold ──────────────────────────────────────
    pub conviction_history: VecDeque<f64>,
    pub conviction_threshold: f64,
    pub resolved_preds: VecDeque<(f64, bool)>,

    // ── Pending log entries (flushed by caller) ───────────────────────────
    pub pending_logs: Vec<LogEntry>,

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
        base_asset: &Asset,
        max_positions: usize,
        max_utilization: f64,
        start_idx: usize,
        generalist_window: usize,
    ) -> Self {
        // ── Manager journal ─────────────────────────────────────────────
        let mut mgr_journal = Journal::new("manager", dims, recalib_interval);
        let (mgr_buy, mgr_sell) = register_direction(&mut mgr_journal);

        // ── Exit expert journal ─────────────────────────────────────────
        let mut exit_journal = Journal::new("exit-expert", dims, recalib_interval);
        let (exit_hold, exit_exit) = register_exit(&mut exit_journal);

        // ── Observer panel (5 specialists + 1 generalist) ───────────────
        let observer_names = crate::market::OBSERVER_LENSES;
        let mut observers: Vec<Observer> = observer_names
            .iter()
            .enumerate()
            .map(|(ei, &lens)| {
                Observer::new(
                    lens,
                    dims,
                    recalib_interval,
                    dims as u64 + ei as u64 * OBSERVER_SEED_PRIME,
                    &["Buy", "Sell"],
                )
            })
            .collect();
        // The generalist ("generalist") uses a fixed window: min = max = generalist_window.
        observers[GENERALIST_IDX].window_sampler = WindowSampler::new(
            dims as u64 + 5 * OBSERVER_SEED_PRIME, generalist_window, generalist_window,
        );

        // ── Risk branches ───────────────────────────────────────────────
        let risk_branches = vec![
            RiskBranch::new("drawdown", dims),
            RiskBranch::new("accuracy", dims),
            RiskBranch::new("volatility", dims),
            RiskBranch::new("correlation", dims),
            RiskBranch::new("panel", dims),
        ];

        // ── Panel engram ────────────────────────────────────────────────
        let panel_dim = observer_names.len(); // all observers including generalist
        let panel_engram = OnlineSubspace::with_params(panel_dim, 4, 2.0, 0.01, 3.5, 100);

        // ── Treasury + portfolio ────────────────────────────────────────
        let mut treasury = Treasury::new(max_positions, max_utilization);
        treasury.deposit(base_asset, initial_equity);
        let portfolio = Portfolio::new(initial_equity, observe_period);

        // ── Adaptive decay ──────────────────────────────────────────────
        let adaptive_decay = decay;

        Self {
            // Learning
            mgr_journal,
            mgr_buy,
            mgr_sell,
            prev_mgr_thought: None,
            exit_journal,
            exit_hold,
            exit_exit,
            exit_pending: Vec::new(),

            // Observers (6: 5 specialists + generalist at index 5)
            observers,

            // Risk
            risk_branches,
            cached_risk_mult: 0.5,
            cached_curve_a: 0.0,
            cached_curve_b: 0.0,
            kelly_curve_valid: false,
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

            // Conviction
            conviction_history: VecDeque::new(),
            conviction_threshold: 0.0,
            resolved_preds: VecDeque::new(),

            // Pending logs
            pending_logs: Vec::new(),

            // Loop cursor
            cursor: start_idx,
        }
    }

    /// The generalist's Buy label.
    fn tht_buy(&self) -> Label { self.observers[GENERALIST_IDX].primary_label }

    /// The generalist's Sell label (second registered label).
    fn tht_sell(&self) -> Label { self.observers[GENERALIST_IDX].journal.labels()[1] }

    /// The enterprise's public interface. One enriched event, one fold step.
    /// The enterprise doesn't know where events come from.
    /// Backtest, websocket, test harness — same EnrichedEvent, same fold.
    pub fn on_event(
        &mut self,
        event: EnrichedEvent,
        ctx: &CandleContext,
    ) {
        match event {
            EnrichedEvent::Deposit { asset, amount } => {
                self.treasury.deposit(&asset, amount);
                return;
            }
            EnrichedEvent::Withdraw { asset, amount } => {
                self.treasury.withdraw(&asset, amount);
                return;
            }
            EnrichedEvent::Candle { candle, fact_labels: tht_facts, observer_vecs } => {
                self.on_candle_inner(&candle, tht_facts, observer_vecs, ctx);
            }
        }
    }

    /// Process one candle's pre-computed results. The fold's step function.
    ///
    /// Called from on_event for EnrichedEvent::Candle.
    /// The backtest runner pre-encodes in parallel (rayon), then wraps
    /// results in EnrichedEvent::Candle. The cursor is managed here.
    // 870-line fold — the sequential heartbeat. Coherent blocks extracted; what remains is causal chain.
    fn on_candle_inner(
        &mut self,
        candle: &Candle,
        tht_facts: Vec<String>,
        observer_vecs: Vec<Vector>,
        ctx: &CandleContext,
    ) {
        let i = self.cursor;
        self.cursor += 1;
        self.encode_count += 1;

        // ── Observer predictions: each observer speaks ────────────────
        // No flip. The discriminant learns what predicts — including reversals.
        // The flip was a hack for a single journal. The enterprise lets each
        // expert's discriminant encode the full pattern naturally.
        // All 6 observers (5 specialists + generalist at index 5) predict.
        let observer_preds: Vec<Prediction> = observer_vecs.iter().enumerate()
            .map(|(ei, vec)| self.observers[ei].journal.predict(vec))
            .collect();

        // The generalist's prediction (observer[5]) — used for manager encoding
        // and backward-compatible logging.
        let tht_pred = observer_preds[5].clone();
        let tht_vec = observer_vecs[5].clone();

        // ── Manager: encodes observer opinions via manager.rs ─────────
        // Single canonical encoding path. See manager.rs and wat/manager.wat.
        // The first 5 observers are specialists; observer[5] is the generalist.
        // ManagerContext takes the 5 specialists for observer_* fields,
        // and the generalist separately.
        let mut obs_curve_valid = [false; 5];
        let mut obs_resolved_lens = [0usize; 5];
        let mut obs_resolved_accs = [0.0f64; 5];
        for (oi, obs) in self.observers[..5].iter().enumerate() {
            obs_curve_valid[oi] = obs.curve_valid;
            obs_resolved_lens[oi] = obs.resolved.len();
            obs_resolved_accs[oi] = obs.cached_acc;
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
        // All 6 observers contribute (generalist is already at index 5).
        let mut panel_state = [0.0f64; 6];
        for (pi, ep) in observer_preds.iter().enumerate() { panel_state[pi] = ep.raw_cos; }
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

        // Pass 1: observe exit expert + tick positions, collect exit signals.
        let mut exit_signals: Vec<(usize, PositionExit)> = Vec::new();
        for (pi, pos) in self.positions.iter_mut().enumerate() {
            if pos.phase == PositionPhase::Closed { continue; }

            // Exit expert: encode at Nyquist rate of position lifecycle
            // Rate = source/target. For USDC→WBTC positions, rate = quote_price.
            // For WBTC→USDC positions, rate = 1/quote_price.
            let current_rate = if pos.source_asset == *ctx.base_asset { quote_price } else { 1.0 / quote_price };
            let is_buy = pos.source_asset == *ctx.base_asset;
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
                exit_signals.push((pi, exit));
            }
        }

        // Pass 2: settle each exit — treasury, accounting, logging.
        // Symmetric: release target, swap target→source, update accounting.
        for &(pos_idx, ref exit) in &exit_signals {
            let pos = &mut self.positions[pos_idx];
            let current_rate = if pos.source_asset == *ctx.base_asset { quote_price } else { 1.0 / quote_price };

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
                self.treasury.release(&pos.target_asset, sell_target);
                // Swap price = from_per_to. Swapping target→source: price = target_per_source = 1/rate.
                let exit_price = 1.0 / current_rate;
                let (sold, received) = self.treasury.swap(
                    &pos.target_asset, &pos.source_asset,
                    sell_target, exit_price, fee_rate,
                );
                pos.target_held -= sold;
                pos.source_reclaimed += received;
                pos.total_fees += sold * exit_price * fee_rate;
            }
            pos.phase = next_phase;
            self.hold_swaps += 1;

            let ret = pos.return_pct(current_rate);
            if next_phase == PositionPhase::Runner || ret > 0.0 {
                self.hold_wins += 1;
            }
            if next_phase == PositionPhase::Closed {
                self.last_exit_price = quote_price;
                self.last_exit_atr = candle.atr_r;
            }
            let is_buy = pos.source_asset == *ctx.base_asset;
            let direction = if is_buy { Direction::Long } else { Direction::Short };
            let exit_type = match (exit, pos.phase) {
                (PositionExit::TakeProfit, PositionPhase::Runner) => "RunnerTP",
                (PositionExit::TakeProfit, _) => "PartialProfit",
                (PositionExit::StopLoss, _) => "StopLoss",
            };
            self.pending_logs.push(LogEntry::PositionExit {
                step: self.log_step,
                candle_idx: i as i64,
                timestamp: candle.ts.clone(),
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
        // rune:scry(aspirational) — risk.wat specifies conviction-based risk rejection: the risk
        // manager predicts Healthy/Unhealthy and modulates sizing by risk conviction. Code uses a
        // simple threshold (cached_risk_mult > 0.3) — no risk discriminant, no risk conviction.
        let risk_allows = self.cached_risk_mult > RISK_GATE_THRESHOLD;
        let should_open = ctx.asset_mode == AssetMode::Hold
            && self.portfolio.phase != Phase::Observe
            && self.mgr_curve_valid && in_proven_band && market_moved && risk_allows
            && (meta_dir == Some(self.mgr_buy) || meta_dir == Some(self.mgr_sell));

        if should_open {
            let expected_move = candle.atr_r * 6.0;
            if expected_move > 2.0 * fee_rate {
                let band_edge: f64 = MAX_BASE_POSITION;
                let frac = ((band_edge / 2.0) * self.cached_risk_mult).min(ctx.max_single_position);
                let dir_label = meta_dir.unwrap();
                let is_buy = dir_label == self.mgr_buy;

                // Source/target: Buy sells USDC for WBTC, Sell sells WBTC for USDC.
                // Rate = source_per_target. For Buy: USDC/WBTC = price. For Sell: WBTC/USDC = 1/price.
                let (source_asset, target_asset, source_avail, rate) = if is_buy {
                    (ctx.base_asset.clone(), ctx.quote_asset.clone(),
                     self.treasury.balance(ctx.base_asset), quote_price)
                } else {
                    (ctx.quote_asset.clone(), ctx.base_asset.clone(),
                     self.treasury.balance(ctx.quote_asset), 1.0 / quote_price)
                };
                let deploy_amount = source_avail * frac;
                // Value in USDC for minimum position check
                let usd_value = if is_buy { deploy_amount } else { deploy_amount * quote_price };

                if usd_value > 10.0 {
                    let (spent, received) = self.treasury.swap(
                        &source_asset, &target_asset, deploy_amount, rate, fee_rate);

                    // Symmetric claim: lock the received target in deployed.
                    self.treasury.claim(&target_asset, received);

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
                    self.hold_swaps += 1;
                    let direction = if is_buy { Direction::Long } else { Direction::Short };
                    self.pending_logs.push(LogEntry::PositionOpen {
                        step: self.log_step,
                        candle_idx: i as i64,
                        timestamp: candle.ts.clone(),
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
        if self.encode_count % ctx.recalib_interval == 0 || self.encode_count < RISK_WARMUP {
            self.cached_risk_mult = risk::evaluate_risk_branches(
                &mut self.risk_branches, &self.portfolio, ctx.vm, ctx.risk_scalar,
            );
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
                            let drawdown_pct = if self.peak_treasury_equity > 0.0 {
                                (self.peak_treasury_equity - treasury_equity) / self.peak_treasury_equity
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
                        self.portfolio.position_frac(meta_conviction, ctx.min_conviction, self.conviction_threshold)
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
            fact_labels:   if ctx.diagnostics { tht_facts } else { Vec::new() },
            crossing:      None,
            entry_price:       candle.close,
            entry_ts:          candle.ts.clone(),
            entry_atr:         candle.atr_r,
            max_favorable:     0.0,
            max_adverse:       0.0,
            exit_reason:       None,
            exit_pct:          0.0,
            deployed_usd: 0.0,
        });

        // Decay once per candle.
        // The generalist (observers[GENERALIST_IDX]) uses adaptive decay; specialists use fixed decay.
        self.mgr_journal.decay(self.adaptive_decay);
        for (oi, observer) in self.observers.iter_mut().enumerate() {
            let d = if oi == 5 { self.adaptive_decay } else { ctx.decay };
            observer.journal.decay(d);
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
                    // Observer resolution: learn, track, gate, validate, log.
                    // Each observer (including generalist at index 5) resolves
                    // its prediction against the outcome.
                    for (ei, observer_vec) in entry.observer_vecs.iter().enumerate() {
                        if let Some(log) = self.observers[ei].resolve(
                            observer_vec, &entry.observer_preds[ei], o, signal_wt,
                            ctx.conviction_quantile, ctx.conviction_window,
                        ) {
                            if ctx.diagnostics { self.pending_logs.push(LogEntry::ObserverLog {
                                step: self.log_step,
                                observer: log.name.as_str().to_string(),
                                conviction: log.conviction,
                                direction: self.observers[ei].journal.label_name(log.direction).unwrap_or("?").to_string(),
                                correct: log.correct as i32,
                            }); }
                        }
                    }
                    entry.crossing = Some(CrossingSnapshot {
                        label:   o,
                        pct,
                        candles: i - entry.candle_idx,
                        ts:      candle.ts.clone(),
                        price:   candle.close,
                    });
                }
            }
        }

        // Log any recalibrations that fired during this candle's learning.
        if self.observers[GENERALIST_IDX].journal.recalib_count() != tht_recalib_before {
            // Pre-compute curve params for Kelly — once per recalib, not per trade.
            // Uses the generalist's resolved_preds for the curve fit.
            if let Some((_, a, b)) = kelly_frac(0.15, &self.resolved_preds,
                if ctx.atr_multiplier > 0.0 { ctx.atr_multiplier * candle.atr_r } else { ctx.move_threshold }) {
                self.cached_curve_a = a;
                self.cached_curve_b = b;
                self.kelly_curve_valid = true;
            }
            // Manager proven band: find the conviction band where accuracy > 51%.
            if let Some((lo, hi, _acc)) = find_proven_band(&self.mgr_resolved, ctx.dims) {
                self.mgr_curve_valid = true;
                self.mgr_proven_band = (lo, hi);
            } else {
                self.mgr_curve_valid = false;
                self.mgr_proven_band = (0.0, 0.0);
            }

            // Feed panel engram: if recent panel accuracy was good, store current state.
            if self.panel_recalib_total >= PANEL_ENGRAM_MIN_TOTAL {
                let acc = self.panel_recalib_wins as f64 / self.panel_recalib_total as f64;
                if acc > PANEL_ENGRAM_MIN_ACC {
                    self.panel_engram.update(&panel_state);
                }
            }
            self.panel_recalib_wins = 0;
            self.panel_recalib_total = 0;

            self.pending_logs.push(LogEntry::RecalibLog {
                step: self.encode_count as i64,
                journal: "thought".to_string(),
                cos_raw: self.observers[GENERALIST_IDX].journal.last_cos_raw(),
                disc_strength: self.observers[GENERALIST_IDX].journal.last_disc_strength(),
                buy_count: self.observers[GENERALIST_IDX].journal.label_count(tht_buy) as i64,
                sell_count: self.observers[GENERALIST_IDX].journal.label_count(tht_sell) as i64,
            });

            // Decode thought discriminant against the fact codebook.
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
                    entry.exit_pct, dir == self.mgr_buy,
                    ctx.swap_fee, ctx.slippage,
                    is_live, entry.deployed_usd, treasury_equity, frac,
                );

                // Portfolio tracks win/loss for phase transitions — every resolved prediction,
                // not just ones with capital. Treasury is NOT touched here — capital moves
                // through ManagedPosition lifecycle only.
                {
                    let trade_dir = if dir == self.mgr_buy { Direction::Long } else { Direction::Short };
                    self.portfolio.record_trade(entry.exit_pct, frac, trade_dir,
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
                        direction: self.mgr_journal.label_name(dir).unwrap_or("?").to_string(),
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

                // Panel tracking (all predictions, not just live)
                self.panel_recalib_total += 1;
                if final_out == Some(dir) { self.panel_recalib_wins += 1; }

                // ── Risk/diagnostics: only for live trades ───────────
                if is_live {
                    self.update_risk_from_trade(&entry, dir, final_out, treasury_equity, ctx);
                }
            } // if let Some(dir)

            self.log_candle(&entry, final_out, treasury_equity, ctx);
            self.db_batch   += 1;
            if self.db_batch >= 5_000 {
                self.pending_logs.push(LogEntry::BatchCommit);
                self.db_batch = 0;
            }

            self.portfolio.tick_observe();
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
            let bnh = (candle.close - ctx.bnh_entry) / ctx.bnh_entry * 100.0;
            let atr_now = candle.atr_r;
            let exit_info = format!(" | ATR={:.2}% sl={:.2}% tp={:.2}% tr={:.2}% open={}",
                atr_now * 100.0,
                ctx.k_stop * atr_now * 100.0,
                ctx.k_tp * atr_now * 100.0,
                ctx.k_trail * atr_now * 100.0,
                self.treasury.n_open);
            eprintln!(
                "  {}/{} ({:.0}/s ETA {:.0}s) | {} | {} | tht={:.1}% | trades={} win={:.1}% | ${:.0} ({:+.1}%) vs B&H {:+.1}% | flip@{:.3} {}{}",
                self.encode_count, ctx.loop_count, rate, eta,
                &candle.ts[..10],
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
            if ctx.asset_mode == AssetMode::Hold {
                let proven: Vec<&str> = self.observers.iter()
                    .filter(|e| e.curve_valid).map(|e| e.lens.as_str()).collect();
                // generalist is in the observer list, no separate check needed
                let proven_str = if proven.is_empty() { "none".to_string() }
                    else { proven.join(",") };
                let band_str = if self.mgr_curve_valid {
                    format!(" band=[{:.3},{:.3}]", self.mgr_proven_band.0, self.mgr_proven_band.1)
                } else { " band=none".to_string() };
                eprintln!("    treasury: ${:.0} ({:+.1}%) | USDC={:.2} WBTC={:.6} | pos={} swaps={} wins={} | proven=[{}]{}",
                    treasury_equity, ret,
                    self.treasury.balance(ctx.base_asset) + self.treasury.deployed(ctx.base_asset),
                    self.treasury.balance(ctx.quote_asset) + self.treasury.deployed(ctx.quote_asset),
                    self.positions.len(), self.hold_swaps, self.hold_wins, proven_str, band_str);
            }
        }
    }

    // ─── Resolution helpers (extracted from on_candle resolution loop) ─────

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
        let mgr_label = if price_change > 0.0 { self.mgr_buy } else { self.mgr_sell };

        // Learn from the SAME thought the manager predicted with.
        // Stored at prediction time, delta-enriched. One encoding path.
        if let Some(ref mgr_vec) = entry.mgr_thought {
            self.mgr_journal.observe(mgr_vec, mgr_label, 1.0);
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
        self.mgr_resolved.push_back((entry.meta_conviction, mgr_correct));
        if self.mgr_resolved.len() > 5000 { self.mgr_resolved.pop_front(); }
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
        ctx: &CandleContext,
    ) {
        self.pending_logs.push(LogEntry::CandleLog {
            step: self.log_step,
            candle_idx: entry.candle_idx as i64,
            timestamp: entry.entry_ts.clone(),
            tht_cos: entry.tht_pred.raw_cos,
            tht_conviction: entry.tht_pred.conviction,
            tht_pred: entry.tht_pred.direction.and_then(|d| self.observers[GENERALIST_IDX].journal.label_name(d).map(|s| s.to_string())),
            meta_pred: entry.meta_dir.and_then(|d| self.mgr_journal.label_name(d).map(|s| s.to_string())),
            meta_conviction: entry.meta_conviction,
            actual: final_out.and_then(|l| self.observers[GENERALIST_IDX].journal.label_name(l).map(|s| s.to_string())).unwrap_or_else(|| "Noise".to_string()),
            traded: entry.position_frac.is_some() as i32,
            position_frac: entry.position_frac,
            equity: treasury_equity,
            outcome_pct: entry.crossing.as_ref().map(|c| c.pct).unwrap_or(0.0),
            usdc_bal: self.treasury.balance(ctx.base_asset),
            wbtc_bal: self.treasury.balance(ctx.quote_asset),
            usdc_deployed: self.treasury.deployed(ctx.base_asset),
            wbtc_deployed: self.treasury.deployed(ctx.quote_asset),
        });
        self.log_step += 1;
    }

    /// Risk diagnostics + adaptive decay for a resolved live trade.
    fn update_risk_from_trade(
        &mut self,
        entry: &Pending,
        dir: Label,
        final_out: Option<Label>,
        treasury_equity: f64,
        ctx: &CandleContext,
    ) {
        let drawdown_pct = if self.peak_treasury_equity > 0.0 {
            (self.peak_treasury_equity - treasury_equity) / self.peak_treasury_equity * 100.0
        } else { 0.0 };
        let streak_val = self.portfolio.streak();
        let streak_len = streak_val.abs() as i32;
        let streak_dir = if streak_val >= 0.0 { "winning" } else { "losing" };
        let recent_acc = self.portfolio.rolling_acc();
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

        // Log which facts were present for this trade.
        if ctx.diagnostics {
            for label in &entry.fact_labels {
                self.pending_logs.push(LogEntry::TradeFact {
                    step: self.log_step,
                    fact_label: label.clone(),
                });
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
