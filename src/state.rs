//! EnterpriseState — the mutable state of the enterprise heartbeat.
//!
//! Everything the main loop mutates, packaged into one struct.
//! Created once at startup, threaded through the heartbeat.
//! enterprise.rs orchestrates; this module holds what changes.

use holon::{VectorManager, Vector};

use crate::event::Event;
use crate::indicators::RawCandle;
use crate::market::exit::ExitAtoms;
use crate::market::manager::ManagerAtoms;
use crate::portfolio::Portfolio;
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
    /// `per_swap_fee` = swap_fee + slippage, pre-computed by caller.
    /// One param instead of two swappable bare f64s.
    pub fn compute(
        trade_pct: f64,
        is_buy: bool,
        per_swap_fee: f64,
        is_live: bool,
        treasury_equity: f64,
        position_frac: f64,
    ) -> Self {
        let gross_ret = if is_buy { trade_pct } else { -trade_pct };
        let per_swap = per_swap_fee;
        let after_entry = 1.0 - per_swap;
        let gross_value = after_entry * (1.0 + gross_ret);
        let after_exit = gross_value * (1.0 - per_swap);
        let net_ret = after_exit - 1.0;
        let entry_cost_frac = per_swap;
        let exit_cost_frac = gross_value * per_swap;
        let pos_usd = if is_live { treasury_equity * position_frac } else { 0.0 };
        let trade_pnl = pos_usd * net_ret;
        Self { gross_ret, net_ret, entry_cost_frac, exit_cost_frac, pos_usd, trade_pnl }
    }
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
    pub thought_encoder: &'a crate::thought::ThoughtEncoder,
    pub mgr_atoms: &'a ManagerAtoms,
    pub mgr_scalar: &'a holon::ScalarEncoder,
    pub exit_scalar: &'a holon::ScalarEncoder,
    pub exit_atoms: &'a ExitAtoms,
    pub risk_scalar: &'a holon::ScalarEncoder,
    pub risk_atoms: &'a risk::RiskAtoms,
    pub risk_mgr_atoms: &'a risk::manager::RiskManagerAtoms,

    // ── Observer/manager atoms ──────────────────────────────────────────
    pub observer_atoms: &'a [Vector],
    pub generalist_atom: &'a Vector,
    pub min_opinion_magnitude: f64,

    // ── Codebook for discriminant decode ────────────────────────────────
    pub codebook_labels: &'a [String],
    pub codebook_vecs: &'a [Vector],

    // ── Progress display ────────────────────────────────────────────────
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
    pub risk_generalist: holon::memory::OnlineSubspace,
    pub risk_manager: risk::manager::RiskManager,
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
            max_window_size: 2016,
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
            risk_generalist: holon::memory::OnlineSubspace::new(dims, 8),
            risk_manager: risk::manager::RiskManager::new(dims, recalib_interval),
            cached_risk_mult: 0.5,
            peak_treasury_equity: initial_equity,
            candle_count: 0,
            db_batch: 0,
            cursor: start_idx,
        }
    }

    /// The enterprise's public interface. One event, one fold step.
    /// The enterprise doesn't know where events come from.
    /// Backtest, websocket, test harness — same Event, same fold.
    pub fn on_event(
        &mut self,
        event: Event,
        ctx: &CandleContext,
    ) {
        match event {
            Event::Deposit { asset, amount } => {
                self.treasury.deposit(&asset, amount);
            }
            Event::Withdraw { asset, amount } => {
                self.treasury.withdraw(&asset, amount);
            }
            Event::Candle(raw) => {
                self.on_candle_raw(raw, ctx);
            }
        }
    }

    /// Process one raw candle. The fold's step function.
    ///
    /// Each desk steps its own indicator bank from the raw OHLCV.
    /// No pre-computed indicators. No pre-encoded thoughts.
    fn on_candle_raw(
        &mut self,
        raw: RawCandle,
        ctx: &CandleContext,
    ) {
        let i = self.cursor;
        self.cursor += 1;

        // Risk evaluation (enterprise-level)
        // rune:scry(evolved) — enterprise.wat evaluates risk every candle; Rust caches at recalib
        // intervals for efficiency. Functionally equivalent given the gate conditions.
        self.candle_count += 1;
        if self.candle_count % ctx.recalib_interval == 0 || self.candle_count < RISK_WARMUP {
            let (branch_mult, ratios) = risk::evaluate_risk_branches(
                &mut self.risk_branches, &mut self.risk_generalist,
                &self.portfolio, ctx.risk_atoms, ctx.risk_scalar,
            );

            // Risk manager: encode branch ratios, predict, learn
            let risk_thought = risk::manager::encode_risk_manager_thought(
                &ratios, ctx.risk_mgr_atoms, ctx.risk_scalar,
            );
            let risk_pred = self.risk_manager.predict(&risk_thought);
            let mgr_mult = self.risk_manager.risk_mult_from_prediction(&risk_pred);

            // Label: was the portfolio healthy at this moment?
            let was_healthy = self.portfolio.is_healthy() && self.portfolio.trades_taken >= 20;
            self.risk_manager.observe(&risk_thought, was_healthy, 1.0);
            self.risk_manager.decay(ctx.decay);

            // Combine: branch residuals AND manager prediction
            self.cached_risk_mult = branch_mult.min(mgr_mult);
        }

        // Desk fold step — each desk computes its own indicators from raw OHLCV
        for desk in &mut self.desks {
            let mut shared = crate::market::desk::SharedState {
                treasury: &mut self.treasury,
                portfolio: &mut self.portfolio,
                risk_mult: self.cached_risk_mult,
                peak_equity: &mut self.peak_treasury_equity,
                db_batch: &mut self.db_batch,
            };
            desk.on_candle(i, &raw, &mut shared, ctx);
        }
    }
}
