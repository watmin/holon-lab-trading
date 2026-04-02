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

use crate::journal::Label;
use crate::market::observer::Observer;
use crate::position::{ExitObservation, ManagedPosition, Pending};
use crate::ledger::LogEntry;
use crate::window_sampler::WindowSampler;
use crate::treasury::Asset;

use super::OBSERVER_LENSES;

/// Configuration for creating a desk.
pub struct DeskConfig {
    pub name: String,
    pub source_asset: Asset,
    pub target_asset: Asset,
    pub dims: usize,
    pub recalib_interval: usize,
    pub window: usize,
    pub decay: f64,
}

/// Observer seed spacing prime — same seed logic as the old EnterpriseState::new.
const OBSERVER_SEED_PRIME: u64 = 7919;

/// A desk — one pair's full enterprise tree.
///
/// Contains observers, manager, exit expert, positions, pending, conviction,
/// panel engram, adaptive decay, accounting. Everything per-pair.
///
/// Risk lives on the enterprise (shared across desks).
/// Treasury lives on the enterprise (shared across desks).
/// Portfolio lives on the enterprise (shared across desks).
pub struct Desk {

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

        // The generalist uses a fixed window.
        observers[crate::state::GENERALIST_IDX].window_sampler = WindowSampler::new(
            dims as u64 + 5 * OBSERVER_SEED_PRIME,
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

        Self {
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
}
