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
use crate::treasury::{AccumulationLedger, Asset, Treasury};

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
    // rune:forge(bare-type) — single call site, parameter order clear from context.
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
    pub k_trail_runner: f64,  // wider trail for house money (runner phase)
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
    pub accumulation: AccumulationLedger,

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
            accumulation: AccumulationLedger::new(),
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

            // Gate: risk manager's prediction matters once the journal has recalibrated
            if self.risk_manager.journal.recalib_count() > 0 {
                self.risk_manager.curve_valid = true;
            }

            // Combine: branch residuals AND manager prediction
            self.cached_risk_mult = branch_mult.min(mgr_mult);
        }

        // Desk fold step — each desk computes its own indicators from raw OHLCV
        for desk in &mut self.desks {
            let mut shared = crate::market::desk::SharedState {
                treasury: &mut self.treasury,
                portfolio: &mut self.portfolio,
                accumulation: &mut self.accumulation,
                risk_mult: self.cached_risk_mult,
                peak_equity: &mut self.peak_treasury_equity,
                db_batch: &mut self.db_batch,
            };
            desk.on_candle(i, &raw, &mut shared, ctx);
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
    use crate::treasury::Asset;
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

    fn make_ctx<'a>(
        vm: &'a VectorManager,
        thought_encoder: &'a ThoughtEncoder,
        mgr_atoms: &'a ManagerAtoms,
        mgr_scalar: &'a ScalarEncoder,
        exit_scalar: &'a ScalarEncoder,
        exit_atoms: &'a ExitAtoms,
        risk_scalar: &'a ScalarEncoder,
        risk_atoms: &'a crate::risk::RiskAtoms,
        risk_mgr_atoms: &'a crate::risk::manager::RiskManagerAtoms,
        observer_atoms: &'a [Vector],
        generalist_atom: &'a Vector,
        codebook_labels: &'a [String],
        codebook_vecs: &'a [Vector],
    ) -> CandleContext<'a> {
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
            min_opinion_magnitude: noise_floor(TEST_DIMS),
            codebook_labels,
            codebook_vecs,
            loop_count: 1000,
            progress_every: 500,
            t_start: std::time::Instant::now(),
        }
    }

    /// Build all the encoding infrastructure needed for CandleContext at small dims.
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
            make_ctx(
                &self.vm,
                &self.thought_encoder,
                &self.mgr_atoms,
                &self.mgr_scalar,
                &self.exit_scalar,
                &self.exit_atoms,
                &self.risk_scalar,
                &self.risk_atoms,
                &self.risk_mgr_atoms,
                &self.observer_atoms,
                &self.generalist_atom,
                &self.codebook_labels,
                &self.codebook_vecs,
            )
        }
    }

    fn make_enterprise() -> EnterpriseState {
        let base_asset = Asset::new("USDC");
        EnterpriseState::new(
            TEST_DIMS,
            200,      // recalib_interval
            10000.0,  // initial_equity
            100,      // observe_period
            0.999,    // decay
            &base_asset,
            3,        // max_positions
            0.5,      // max_utilization
            0,        // start_idx
            100,      // generalist_window
        )
    }

    #[test]
    fn enterprise_state_new_creates() {
        let state = make_enterprise();
        assert_eq!(state.desks.len(), 1, "should have exactly one desk");
        let usdc = Asset::new("USDC");
        assert_eq!(
            state.treasury.balance(&usdc), 10000.0,
            "treasury should have initial equity"
        );
        assert_eq!(state.cursor, 0);
        assert_eq!(state.candle_count, 0);
    }

    #[test]
    fn enterprise_state_on_event_candle() {
        let infra = TestInfra::new();
        let ctx = infra.ctx();
        let mut state = make_enterprise();

        let raw = make_raw_candle(0);
        state.on_event(Event::Candle(raw), &ctx);

        assert_eq!(state.cursor, 1, "cursor should advance by one after a candle");
    }

    #[test]
    fn enterprise_state_processes_100_candles() {
        let infra = TestInfra::new();
        let ctx = infra.ctx();
        let mut state = make_enterprise();

        for i in 0..100 {
            let raw = make_raw_candle(i);
            state.on_event(Event::Candle(raw), &ctx);
        }

        assert_eq!(state.cursor, 100, "cursor should be 100 after 100 candles");
        assert_eq!(state.candle_count, 100);
    }

    #[test]
    fn enterprise_state_deposit_event() {
        let infra = TestInfra::new();
        let ctx = infra.ctx();
        let mut state = make_enterprise();

        let usdc = Asset::new("USDC");
        let before = state.treasury.balance(&usdc);
        state.on_event(Event::Deposit { asset: usdc.clone(), amount: 5000.0 }, &ctx);
        let after = state.treasury.balance(&usdc);

        assert_eq!(after - before, 5000.0, "deposit should increase balance by deposited amount");
    }

    #[test]
    fn enterprise_state_withdraw_event() {
        let infra = TestInfra::new();
        let ctx = infra.ctx();
        let mut state = make_enterprise();

        let usdc = Asset::new("USDC");
        let before = state.treasury.balance(&usdc);
        state.on_event(Event::Withdraw { asset: usdc.clone(), amount: 3000.0 }, &ctx);
        let after = state.treasury.balance(&usdc);

        assert_eq!(before - after, 3000.0, "withdraw should decrease balance by withdrawn amount");
    }

    // ── TradePnl tests ──────────────────────────────────────────────────────

    #[test]
    fn trade_pnl_buy_with_profit() {
        // Buy trade: price went up 5%, 0.35% per swap fee, live trade
        let pnl = TradePnl::compute(
            0.05,    // trade_pct: 5% price increase
            true,    // is_buy
            0.0035,  // per_swap_fee (0.35%)
            true,    // is_live
            10000.0, // treasury_equity
            0.10,    // position_frac (10% of equity)
        );

        // gross_ret should be positive (buy + price up)
        assert!((pnl.gross_ret - 0.05).abs() < 1e-10, "gross_ret should be 0.05");

        // net_ret should be positive but less than gross due to fees
        assert!(pnl.net_ret > 0.0, "net_ret should be positive for profitable buy");
        assert!(pnl.net_ret < pnl.gross_ret, "net_ret should be less than gross_ret due to fees");

        // Entry cost is per_swap
        assert!((pnl.entry_cost_frac - 0.0035).abs() < 1e-10);

        // pos_usd = 10000 * 0.10 = 1000
        assert!((pnl.pos_usd - 1000.0).abs() < 1e-10, "pos_usd should be equity * frac");

        // trade_pnl = pos_usd * net_ret, should be positive
        assert!(pnl.trade_pnl > 0.0, "trade_pnl should be positive for profitable buy");
    }

    #[test]
    fn trade_pnl_sell_with_loss() {
        // Sell trade: price went up 3% (bad for seller), 0.35% per swap fee, live
        let pnl = TradePnl::compute(
            0.03,    // trade_pct: 3% price increase (bad for sell)
            false,   // is_buy = false (sell)
            0.0035,  // per_swap_fee
            true,    // is_live
            10000.0, // treasury_equity
            0.05,    // position_frac
        );

        // gross_ret should be negative (sell + price went up)
        assert!((pnl.gross_ret - (-0.03)).abs() < 1e-10, "gross_ret should be -0.03 for sell when price rose");

        // net_ret should be negative (wrong direction + fees)
        assert!(pnl.net_ret < 0.0, "net_ret should be negative for losing sell");

        // pos_usd = 10000 * 0.05 = 500
        assert!((pnl.pos_usd - 500.0).abs() < 1e-10);

        // trade_pnl should be negative
        assert!(pnl.trade_pnl < 0.0, "trade_pnl should be negative for losing sell");
    }

    #[test]
    fn trade_pnl_paper_trade_zero_position() {
        // Paper trade: is_live = false, so pos_usd should be 0
        let pnl = TradePnl::compute(
            0.05,    // trade_pct
            true,    // is_buy
            0.0035,  // per_swap_fee
            false,   // is_live = false (paper)
            10000.0, // treasury_equity
            0.10,    // position_frac
        );

        assert_eq!(pnl.pos_usd, 0.0, "paper trade should have zero position USD");
        assert_eq!(pnl.trade_pnl, 0.0, "paper trade should have zero P&L");

        // gross_ret and net_ret are still computed (for logging)
        assert!(pnl.gross_ret > 0.0);
        assert!(pnl.net_ret > 0.0);
    }

    #[test]
    fn trade_pnl_fee_arithmetic() {
        // Verify the fee math step by step with zero movement
        let pnl = TradePnl::compute(
            0.0,     // trade_pct: no price change
            true,    // is_buy
            0.01,    // per_swap_fee: 1% per swap for easy math
            true,    // is_live
            10000.0, // treasury_equity
            1.0,     // position_frac: 100% for easy math
        );

        // gross_ret = 0 (no price movement)
        assert!((pnl.gross_ret - 0.0).abs() < 1e-10);

        // after_entry = 1 - 0.01 = 0.99
        // gross_value = 0.99 * (1 + 0) = 0.99
        // after_exit = 0.99 * (1 - 0.01) = 0.99 * 0.99 = 0.9801
        // net_ret = 0.9801 - 1.0 = -0.0199
        assert!((pnl.net_ret - (-0.0199)).abs() < 1e-10,
            "round trip with 1% per swap should cost ~1.99%, got {}", pnl.net_ret);

        // exit_cost_frac = gross_value * per_swap = 0.99 * 0.01 = 0.0099
        assert!((pnl.exit_cost_frac - 0.0099).abs() < 1e-10);
    }

    // ── Display impls ────────────────────────────────────────────────────────

    #[test]
    fn conviction_mode_display() {
        assert_eq!(format!("{}", ConvictionMode::Quantile), "quantile");
        assert_eq!(format!("{}", ConvictionMode::Auto), "auto");
    }

    #[test]
    fn sizing_mode_display() {
        assert_eq!(format!("{}", SizingMode::Legacy), "legacy");
        assert_eq!(format!("{}", SizingMode::Kelly), "kelly");
    }

    #[test]
    fn asset_mode_display() {
        assert_eq!(format!("{}", AssetMode::RoundTrip), "round-trip");
        assert_eq!(format!("{}", AssetMode::Hold), "hold");
    }
}
