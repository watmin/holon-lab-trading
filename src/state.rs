//! EnterpriseState — the mutable state of the enterprise heartbeat.
//!
//! Everything the main loop mutates, packaged into one struct.
//! Created once at startup, threaded through the heartbeat.
//! enterprise.rs orchestrates; this module holds what changes.

use std::collections::VecDeque;

use holon::memory::{Journal, OnlineSubspace};
use holon::Vector;

use crate::journal::{Label, register_direction, register_exit};
use crate::market::observer::Observer;
use crate::portfolio::Portfolio;
use crate::position::{ExitObservation, ManagedPosition, Pending};
use crate::risk::RiskBranch;
use crate::treasury::Treasury;

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
}
