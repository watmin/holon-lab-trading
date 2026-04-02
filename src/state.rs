//! EnterpriseState — the mutable state of the enterprise heartbeat.
//!
//! Everything the main loop mutates, packaged into one struct.
//! Created once at startup, threaded through the heartbeat.
//! enterprise.rs orchestrates; this module holds what changes.

use holon::{Primitives, ScalarEncoder, ScalarMode, VectorManager, Vector};

use crate::candle::Candle;
use crate::event::EnrichedEvent;
use crate::market::manager::ManagerAtoms;
use crate::portfolio::Portfolio;
use crate::position::{ManagedPosition, PositionPhase};
use crate::risk::{self, RiskBranch};
use crate::treasury::{Asset, Treasury};

/// The generalist observer always lives at this index in the observers array.
/// Named constant replaces magic `5` scattered across state.rs and enterprise.rs.
pub const GENERALIST_IDX: usize = 5;

/// Minimum candles encoded before risk branch evaluation begins.
pub const RISK_WARMUP: usize = 100;
/// Minimum accuracy for panel engram snapshot during recalibration.
pub const PANEL_ENGRAM_MIN_ACC: f64 = 0.55;
/// Minimum resolved panel predictions before engram gating applies.
pub const PANEL_ENGRAM_MIN_TOTAL: u32 = 10;

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
    pub horizon: usize,
    pub move_threshold: f64,
    pub atr_multiplier: f64,
    pub decay: f64,
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
    // ── Desks: one per trading pair ─────────────────────────────────────
    // Vec<Desk> — one element today. The enterprise iterates desks.
    pub desks: Vec<crate::market::desk::Desk>,

    // ── Shared resources (not per-desk) ─────────────────────────────────
    pub treasury: Treasury,
    pub portfolio: Portfolio,

    // ── Risk department (portfolio health across ALL desks) ──────────────
    pub risk_branches: Vec<RiskBranch>,
    pub cached_risk_mult: f64,

    // ── Portfolio-level tracking ─────────────────────────────────────────
    pub peak_treasury_equity: f64,

    // ── Shared tracking ─────────────────────────────────────────────────
    pub candle_count: usize,   // total candles processed (enterprise-level, for risk recalib gating)
    pub db_batch: usize,

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
        use crate::market::desk::{Desk, DeskConfig};

        // ── Desk: one pair for now ──────────────────────────────────────
        let mut desk = Desk::new(DeskConfig {
            name: "btc-usdc".to_string(),
            source_asset: base_asset.clone(),
            target_asset: Asset::new("WBTC"), // TODO: from CLI
            dims,
            recalib_interval,
            window: generalist_window,
            decay,
        });
        desk.adaptive_decay = decay;

        // ── Risk branches (enterprise-level) ────────────────────────────
        let risk_branches = vec![
            RiskBranch::new("drawdown", dims),
            RiskBranch::new("accuracy", dims),
            RiskBranch::new("volatility", dims),
            RiskBranch::new("correlation", dims),
            RiskBranch::new("panel", dims),
        ];

        // ── Treasury + portfolio (shared) ───────────────────────────────
        let mut treasury = Treasury::new(max_positions, max_utilization);
        treasury.deposit(base_asset, initial_equity);
        let portfolio = Portfolio::new(initial_equity, observe_period);

        Self {
            desks: vec![desk],
            treasury,
            portfolio,
            risk_branches,
            cached_risk_mult: 0.5,
            peak_treasury_equity: initial_equity,
            candle_count: 0,
            db_batch: 0,
            cursor: start_idx,
        }
    }

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
    fn on_candle_inner(
        &mut self,
        candle: &Candle,
        tht_facts: Vec<String>,
        observer_vecs: Vec<Vector>,
        ctx: &CandleContext,
    ) {
        let i = self.cursor;
        self.cursor += 1;

        // Risk evaluation (enterprise-level)
        // rune:scry(evolved) — enterprise.wat evaluates risk every candle; Rust caches at recalib
        // intervals for efficiency. Functionally equivalent given the gate conditions.
        self.candle_count += 1;
        if self.candle_count % ctx.recalib_interval == 0 || self.candle_count < RISK_WARMUP {
            self.cached_risk_mult = risk::evaluate_risk_branches(
                &mut self.risk_branches, &self.portfolio, ctx.vm, ctx.risk_scalar,
            );
        }

        // Desk fold step
        for desk in &mut self.desks {
            desk.on_candle(
                i, candle, tht_facts.clone(), observer_vecs.clone(),
                &mut self.treasury, &mut self.portfolio,
                self.cached_risk_mult, &mut self.peak_treasury_equity,
                &mut self.db_batch, ctx,
            );
        }
    }
}
