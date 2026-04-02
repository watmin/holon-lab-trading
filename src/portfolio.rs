use std::collections::VecDeque;
use std::fmt;

use crate::journal::Direction;

// ─── Phase-based sizing constants ──────────────────────────────────────────────
// Legacy graduated sizing: position fraction scales with phase and rolling accuracy.
// These will be superseded when sizing is fully curve-driven (Kelly).

/// Minimum position fraction (tentative phase or low edge).
const FRAC_TENTATIVE: f64 = 0.005;
/// Position fraction when edge is modest (5–10% above baseline).
const FRAC_MODEST: f64 = 0.01;
/// Maximum position fraction from phase-based sizing (before conviction scaling).
const FRAC_MAX_BASE: f64 = 0.02;
/// Hard cap on any single position fraction (conviction-scaled).
const FRAC_CAP: f64 = 0.05;
/// Rolling accuracy edge above 50% needed to reach modest sizing.
const EDGE_MODEST: f64 = 0.05;
/// Rolling accuracy edge above 50% needed for proportional sizing.
const EDGE_PROPORTIONAL: f64 = 0.10;

// ─── History & phase constants ────────────────────────────────────────────────

/// Rolling history window cap (rolling outcomes, equity_at_trade, trade_returns).
const HISTORY_WINDOW: usize = 500;
/// Minimum trades in rolling window to promote tentative → confident.
const PHASE_UP_MIN_TRADES: usize = 500;
/// Minimum rolling accuracy to promote tentative → confident.
const PHASE_UP_MIN_ACC: f64 = 0.52;
/// Minimum trades in rolling window to demote confident → tentative.
const PHASE_DOWN_MIN_TRADES: usize = 200;
/// Maximum rolling accuracy before demoting confident → tentative.
const PHASE_DOWN_MAX_ACC: f64 = 0.50;
/// Maximum drawdown fraction for `is_healthy` gate.
const HEALTHY_MAX_DRAWDOWN: f64 = 0.02;
/// Minimum win rate (last 50 trades) for `is_healthy` gate.
const HEALTHY_MIN_WIN_RATE: f64 = 0.55;
/// Peak equity decay factor per trade (complement used for current equity weight).
const PEAK_DECAY: f64 = 0.999;

// ─── Portfolio (phase + equity) ─────────────────────────────────────────────────

#[derive(Clone, Copy, PartialEq)]
pub enum Phase { Observe, Tentative, Confident }

impl fmt::Display for Phase {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Phase::Observe   => write!(f, "OBSERVE"),
            Phase::Tentative => write!(f, "TENTATIVE"),
            Phase::Confident => write!(f, "CONFIDENT"),
        }
    }
}

pub struct Portfolio {
    pub equity:          f64,
    pub initial_equity:  f64,
    pub peak_equity:     f64,
    pub phase:           Phase,
    pub observe_left:    usize,
    pub trades_taken:    usize,
    pub trades_won:      usize,
    pub rolling:         VecDeque<bool>,   // recent trade outcomes
    pub rolling_cap:     usize,

    // Risk vocabulary infrastructure
    pub equity_at_trade:    VecDeque<f64>,   // equity after each trade (HISTORY_WINDOW)
    pub trade_returns:      VecDeque<f64>,   // directional return per trade (HISTORY_WINDOW)
    pub dd_bottom_equity:   f64,             // deepest point of current drawdown
    pub trades_since_bottom: usize,          // trades since drawdown bottom
    pub completed_drawdowns: VecDeque<f64>,  // max depth of each completed dd (20)
}

impl Portfolio {
    pub fn new(initial_equity: f64, observe_period: usize) -> Self {
        Self {
            equity: initial_equity,
            initial_equity,
            peak_equity: initial_equity,
            phase: Phase::Observe,
            observe_left: observe_period,
            trades_taken: 0,
            trades_won: 0,
            rolling: VecDeque::new(),
            rolling_cap: HISTORY_WINDOW,
            equity_at_trade: VecDeque::new(),
            trade_returns: VecDeque::new(),
            dd_bottom_equity: initial_equity,
            trades_since_bottom: 0,
            completed_drawdowns: VecDeque::new(),
        }
    }

    pub fn rolling_acc(&self) -> f64 {
        if self.rolling.is_empty() { return 0.5; }
        self.rolling.iter().filter(|&&x| x).count() as f64 / self.rolling.len() as f64
    }

    pub fn win_rate(&self) -> f64 {
        if self.trades_taken == 0 { return 0.0; }
        self.trades_won as f64 / self.trades_taken as f64 * 100.0
    }

    /// Return a position fraction if conditions allow a trade.
    ///
    /// `flip_threshold`: the dynamic conviction quantile threshold. When
    /// `conviction >= flip_threshold` the prediction has been flipped (reversal
    /// signal) and we scale the position proportionally — higher conviction means
    /// a stronger reversal, so we bet more. Below the threshold, use base sizing.
    pub fn position_frac(&self, conviction: f64, min_conviction: f64, flip_threshold: f64) -> Option<f64> {
        if self.phase == Phase::Observe  { return None; }
        if conviction < min_conviction   { return None; }
        let base = match self.phase {
            Phase::Tentative => FRAC_TENTATIVE,
            Phase::Confident => {
                let edge = (self.rolling_acc() - 0.5).max(0.0);
                if edge < EDGE_MODEST           { FRAC_TENTATIVE }
                else if edge < EDGE_PROPORTIONAL { FRAC_MODEST }
                else                             { (edge * 0.10).min(FRAC_MAX_BASE) }
            }
            Phase::Observe => return None,
        };
        // Only trade in the flip zone — below the threshold there is no reliable
        // signal (near-random accuracy). Once the threshold is established, skip
        // low-conviction candles entirely rather than bleeding on noise.
        if flip_threshold > 0.0 && conviction < flip_threshold {
            return None;
        }
        // Scale position by how far conviction exceeds the threshold.
        // conviction / flip_threshold = 1.0 at boundary, grows above.
        let frac = if flip_threshold > 0.0 {
            (base * (conviction / flip_threshold)).min(FRAC_CAP)
        } else {
            base
        };
        Some(frac)
    }

    /// `outcome_pct`: signed price return from entry to first threshold crossing
    ///   (positive = price went up, negative = price went down).
    /// `direction`: the prediction we made (Buy or Sell).
    ///
    /// Long (Buy): profit when price goes up (outcome_pct > 0).
    /// Short (Sell): profit when price goes down (outcome_pct < 0), i.e. -outcome_pct > 0.
    pub fn record_trade(&mut self, outcome_pct: f64, frac: f64, direction: Direction,
                     swap_fee: f64, slippage: f64) {
        let directional_return = match direction {
            Direction::Long  =>  outcome_pct,
            Direction::Short => -outcome_pct,
        };
        // Two-sided fee model: fees apply at each swap independently.
        let per_swap_cost = swap_fee + slippage;
        let after_entry = 1.0 - per_swap_cost;
        let gross_value = after_entry * (1.0 + directional_return);
        let after_exit = gross_value * (1.0 - per_swap_cost);
        let net_return = after_exit - 1.0;
        let pnl = self.equity * frac * net_return;
        let won = net_return > 0.0;

        self.apply_pnl(pnl);
        self.track_drawdown();
        self.record_history(net_return, won);
        self.check_phase();
    }

    /// Apply P&L to equity. Record completed drawdown if equity surpasses peak.
    fn apply_pnl(&mut self, pnl: f64) {
        self.equity += pnl;
        if self.equity > self.peak_equity {
            if self.dd_bottom_equity < self.peak_equity * PEAK_DECAY {
                let dd_depth = (self.peak_equity - self.dd_bottom_equity) / self.peak_equity;
                self.completed_drawdowns.push_back(dd_depth);
                if self.completed_drawdowns.len() > 20 { self.completed_drawdowns.pop_front(); }
            }
            self.peak_equity = self.equity;
            self.dd_bottom_equity = self.equity;
            self.trades_since_bottom = 0;
        }
    }

    /// Decay peak toward current equity and track drawdown bottom.
    /// After ~700 trades below peak, the peak has halved the gap.
    fn track_drawdown(&mut self) {
        self.peak_equity = self.peak_equity * PEAK_DECAY + self.equity * (1.0 - PEAK_DECAY);
        if self.equity < self.dd_bottom_equity {
            self.dd_bottom_equity = self.equity;
            self.trades_since_bottom = 0;
        } else {
            self.trades_since_bottom += 1;
        }
    }

    /// Push trade outcome into rolling history windows.
    fn record_history(&mut self, net_return: f64, won: bool) {
        self.equity_at_trade.push_back(self.equity);
        if self.equity_at_trade.len() > HISTORY_WINDOW { self.equity_at_trade.pop_front(); }
        self.trade_returns.push_back(net_return);
        if self.trade_returns.len() > HISTORY_WINDOW { self.trade_returns.pop_front(); }
        self.trades_taken += 1;
        if won { self.trades_won += 1; }
        self.rolling.push_back(won);
        if self.rolling.len() > self.rolling_cap { self.rolling.pop_front(); }
    }

    /// Signed streak length: +N for consecutive wins, -N for consecutive losses.
    pub fn streak(&self) -> f64 {
        if let Some(&last) = self.rolling.back() {
            let mut val = 0.0_f64;
            for &o in self.rolling.iter().rev() {
                if o == last { val += if last { 1.0 } else { -1.0 }; }
                else { break; }
            }
            val
        } else {
            0.0
        }
    }

    /// Is the portfolio in a "healthy" state? (gates subspace updates)
    pub fn is_healthy(&self) -> bool {
        let dd = if self.peak_equity > 0.0 {
            (self.peak_equity - self.equity) / self.peak_equity
        } else { 0.0 };
        let wr50 = self.win_rate_last_n(50);
        let recent_returns: Vec<f64> = self.trade_returns.iter().rev().take(50).copied().collect();
        let ret_mean = if recent_returns.is_empty() { 0.0 }
            else { recent_returns.iter().sum::<f64>() / recent_returns.len() as f64 };

        dd < HEALTHY_MAX_DRAWDOWN && wr50 > HEALTHY_MIN_WIN_RATE && ret_mean > 0.0
    }

    pub fn win_rate_last_n(&self, n: usize) -> f64 {
        let (total, wins) = self.rolling.iter().rev().take(n)
            .fold((0usize, 0usize), |(t, w), &won| (t + 1, w + won as usize));
        if total == 0 { 0.5 } else { wins as f64 / total as f64 }
    }

    pub fn tick_observe(&mut self) {
        if self.phase == Phase::Observe && self.observe_left > 0 {
            self.observe_left -= 1;
            if self.observe_left == 0 { self.phase = Phase::Tentative; }
        }
    }

    pub fn check_phase(&mut self) {
        let n = self.rolling.len();
        let acc = self.rolling_acc();
        match self.phase {
            Phase::Tentative => { if n >= PHASE_UP_MIN_TRADES && acc > PHASE_UP_MIN_ACC { self.phase = Phase::Confident; } }
            Phase::Confident => { if n >= PHASE_DOWN_MIN_TRADES && acc < PHASE_DOWN_MAX_ACC { self.phase = Phase::Tentative; } }
            Phase::Observe   => {}
        }
    }
}
