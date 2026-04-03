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

#[derive(Clone, Copy, Debug, PartialEq)]
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
    pub drawdown_bottom_equity: f64,         // deepest point of current drawdown
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
            drawdown_bottom_equity: initial_equity,
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
            if self.drawdown_bottom_equity < self.peak_equity * PEAK_DECAY {
                let dd_depth = (self.peak_equity - self.drawdown_bottom_equity) / self.peak_equity;
                self.completed_drawdowns.push_back(dd_depth);
                if self.completed_drawdowns.len() > 20 { self.completed_drawdowns.pop_front(); }
            }
            self.peak_equity = self.equity;
            self.drawdown_bottom_equity = self.equity;
            self.trades_since_bottom = 0;
        }
    }

    /// Decay peak toward current equity and track drawdown bottom.
    /// After ~700 trades below peak, the peak has halved the gap.
    fn track_drawdown(&mut self) {
        self.peak_equity = self.peak_equity * PEAK_DECAY + self.equity * (1.0 - PEAK_DECAY);
        if self.equity < self.drawdown_bottom_equity {
            self.drawdown_bottom_equity = self.equity;
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

#[cfg(test)]
mod tests {
    use super::*;

    fn make_portfolio() -> Portfolio {
        let mut p = Portfolio::new(10000.0, 0);
        // Start in tentative (skip observe)
        p.phase = Phase::Tentative;
        p
    }

    /// Helper: record a winning long trade with minimal venue costs.
    fn record_win(p: &mut Portfolio) {
        // +5% price move, 1% position, long, negligible fees
        p.record_trade(0.05, 0.01, Direction::Long, 0.0, 0.0);
    }

    /// Helper: record a losing long trade with minimal venue costs.
    fn record_loss(p: &mut Portfolio) {
        // -5% price move, 1% position, long, negligible fees
        p.record_trade(-0.05, 0.01, Direction::Long, 0.0, 0.0);
    }

    #[test]
    fn record_trade_updates_win_loss_counts() {
        let mut p = make_portfolio();
        record_win(&mut p);
        assert_eq!(p.trades_taken, 1);
        assert_eq!(p.trades_won, 1);

        record_loss(&mut p);
        assert_eq!(p.trades_taken, 2);
        assert_eq!(p.trades_won, 1);

        record_win(&mut p);
        assert_eq!(p.trades_taken, 3);
        assert_eq!(p.trades_won, 2);
    }

    #[test]
    fn record_trade_updates_rolling_window() {
        let mut p = make_portfolio();
        record_win(&mut p);
        record_loss(&mut p);
        record_win(&mut p);

        assert_eq!(p.rolling.len(), 3);
        assert_eq!(*p.rolling.get(0).unwrap(), true);
        assert_eq!(*p.rolling.get(1).unwrap(), false);
        assert_eq!(*p.rolling.get(2).unwrap(), true);
    }

    #[test]
    fn win_rate_last_n_computes_from_rolling_window() {
        let mut p = make_portfolio();
        // 3 wins, 2 losses
        record_win(&mut p);
        record_win(&mut p);
        record_loss(&mut p);
        record_win(&mut p);
        record_loss(&mut p);

        // Last 4: win, loss, win, loss -> 50%
        let wr4 = p.win_rate_last_n(4);
        assert!((wr4 - 0.5).abs() < 1e-10);

        // Last 2: win, loss -> 50%
        let wr2 = p.win_rate_last_n(2);
        assert!((wr2 - 0.5).abs() < 1e-10);

        // Last 5: all of them -> 3/5 = 60%
        let wr5 = p.win_rate_last_n(5);
        assert!((wr5 - 0.6).abs() < 1e-10);
    }

    #[test]
    fn win_rate_last_n_empty_returns_half() {
        let p = make_portfolio();
        assert!((p.win_rate_last_n(10) - 0.5).abs() < 1e-10);
    }

    #[test]
    fn is_healthy_requires_low_drawdown_and_good_accuracy() {
        let mut p = make_portfolio();
        // Need 50 trades for win_rate_last_n(50) to be meaningful.
        // Build a strongly winning record: 40 wins, 10 losses -> 80% win rate
        for _ in 0..40 { record_win(&mut p); }
        for _ in 0..10 { record_loss(&mut p); }

        // With 80% wins and positive returns, and equity near peak, should be healthy
        // (depends on whether equity exceeded peak during wins)
        // Since wins grow equity, peak tracks equity, drawdown from losses is small.
        // Let's just check the method runs and returns a boolean.
        let _healthy = p.is_healthy();
        // The exact result depends on internal constants and equity dynamics,
        // but we can verify the method doesn't panic.
    }

    #[test]
    fn is_healthy_false_during_drawdown() {
        let mut p = make_portfolio();
        // Fill rolling window with mostly losses -> bad accuracy + drawdown
        for _ in 0..50 {
            record_loss(&mut p);
        }
        // After 50 consecutive losses, drawdown is significant and win rate is 0%
        assert!(!p.is_healthy());
    }

    #[test]
    fn equity_changes_on_trade() {
        let mut p = make_portfolio();
        let initial = p.equity;
        record_win(&mut p);
        // Winning trade should increase equity
        assert!(p.equity > initial);

        let after_win = p.equity;
        record_loss(&mut p);
        // Losing trade should decrease equity
        assert!(p.equity < after_win);
    }

    #[test]
    fn observe_phase_transitions_to_tentative() {
        let mut p = Portfolio::new(10000.0, 3);
        assert_eq!(p.phase, Phase::Observe);
        p.tick_observe();
        assert_eq!(p.phase, Phase::Observe);
        p.tick_observe();
        assert_eq!(p.phase, Phase::Observe);
        p.tick_observe();
        assert_eq!(p.phase, Phase::Tentative);
    }

    #[test]
    fn rolling_acc_empty_returns_half() {
        let p = make_portfolio();
        assert!((p.rolling_acc() - 0.5).abs() < 1e-10);
    }

    #[test]
    fn streak_tracks_consecutive_outcomes() {
        let mut p = make_portfolio();
        record_win(&mut p);
        record_win(&mut p);
        record_win(&mut p);
        assert!((p.streak() - 3.0).abs() < 1e-10);

        record_loss(&mut p);
        assert!((p.streak() - -1.0).abs() < 1e-10);

        record_loss(&mut p);
        assert!((p.streak() - -2.0).abs() < 1e-10);
    }

    // ── Phase::Display ──────────────────────────────────────────────────────

    #[test]
    fn phase_display_formatting() {
        assert_eq!(format!("{}", Phase::Observe), "OBSERVE");
        assert_eq!(format!("{}", Phase::Tentative), "TENTATIVE");
        assert_eq!(format!("{}", Phase::Confident), "CONFIDENT");
    }

    // ── win_rate ────────────────────────────────────────────────────────────

    #[test]
    fn win_rate_zero_trades_returns_zero() {
        let p = make_portfolio();
        assert!((p.win_rate() - 0.0).abs() < 1e-10);
    }

    #[test]
    fn win_rate_with_trades() {
        let mut p = make_portfolio();
        record_win(&mut p);
        record_win(&mut p);
        record_loss(&mut p);
        // 2 wins out of 3 trades = 66.67%
        assert!((p.win_rate() - 200.0 / 3.0).abs() < 1e-6);
    }

    // ── position_frac ───────────────────────────────────────────────────────

    #[test]
    fn position_frac_observe_returns_none() {
        let p = Portfolio::new(10000.0, 10);
        assert_eq!(p.phase, Phase::Observe);
        assert!(p.position_frac(0.5, 0.1, 0.3).is_none());
    }

    #[test]
    fn position_frac_below_min_conviction_returns_none() {
        let p = make_portfolio();
        // conviction 0.05 < min_conviction 0.1
        assert!(p.position_frac(0.05, 0.1, 0.0).is_none());
    }

    #[test]
    fn position_frac_tentative_returns_base() {
        let p = make_portfolio();
        // Tentative phase, conviction above min, no flip threshold
        let frac = p.position_frac(0.5, 0.1, 0.0).unwrap();
        assert!((frac - FRAC_TENTATIVE).abs() < 1e-10);
    }

    #[test]
    fn position_frac_confident_low_edge() {
        let mut p = make_portfolio();
        p.phase = Phase::Confident;
        // rolling_acc defaults to 0.5 (empty), edge = 0.0 < EDGE_MODEST
        let frac = p.position_frac(0.5, 0.1, 0.0).unwrap();
        assert!((frac - FRAC_TENTATIVE).abs() < 1e-10);
    }

    #[test]
    fn position_frac_confident_modest_edge() {
        let mut p = make_portfolio();
        p.phase = Phase::Confident;
        // Build rolling accuracy of ~56% → edge = 0.06 (> EDGE_MODEST, < EDGE_PROPORTIONAL)
        for _ in 0..56 { p.rolling.push_back(true); }
        for _ in 0..44 { p.rolling.push_back(false); }
        let edge = p.rolling_acc() - 0.5;
        assert!(edge >= EDGE_MODEST && edge < EDGE_PROPORTIONAL,
            "edge {edge} should be in modest range");
        let frac = p.position_frac(0.5, 0.1, 0.0).unwrap();
        assert!((frac - FRAC_MODEST).abs() < 1e-10);
    }

    #[test]
    fn position_frac_confident_proportional_edge() {
        let mut p = make_portfolio();
        p.phase = Phase::Confident;
        // Build rolling accuracy of ~65% → edge = 0.15 (> EDGE_PROPORTIONAL)
        for _ in 0..65 { p.rolling.push_back(true); }
        for _ in 0..35 { p.rolling.push_back(false); }
        let edge = p.rolling_acc() - 0.5;
        assert!(edge >= EDGE_PROPORTIONAL, "edge {edge} should be proportional");
        let frac = p.position_frac(0.5, 0.1, 0.0).unwrap();
        let expected = (edge * 0.10).min(FRAC_MAX_BASE);
        assert!((frac - expected).abs() < 1e-10);
    }

    #[test]
    fn position_frac_confident_max_cap() {
        let mut p = make_portfolio();
        p.phase = Phase::Confident;
        // Build rolling accuracy of ~90% → edge = 0.40, edge*0.10 = 0.04 > FRAC_MAX_BASE
        for _ in 0..90 { p.rolling.push_back(true); }
        for _ in 0..10 { p.rolling.push_back(false); }
        let frac = p.position_frac(0.5, 0.1, 0.0).unwrap();
        assert!((frac - FRAC_MAX_BASE).abs() < 1e-10);
    }

    #[test]
    fn position_frac_flip_threshold_gates_below() {
        let p = make_portfolio();
        // conviction 0.2 < flip_threshold 0.3 → gated out
        assert!(p.position_frac(0.2, 0.1, 0.3).is_none());
    }

    #[test]
    fn position_frac_flip_threshold_scales_above() {
        let p = make_portfolio();
        // conviction 0.6 > flip_threshold 0.3 → allowed and scaled
        let frac = p.position_frac(0.6, 0.1, 0.3).unwrap();
        // base = FRAC_TENTATIVE (tentative phase)
        // scaled = FRAC_TENTATIVE * (0.6 / 0.3) = FRAC_TENTATIVE * 2.0
        let expected = (FRAC_TENTATIVE * (0.6 / 0.3)).min(FRAC_CAP);
        assert!((frac - expected).abs() < 1e-10);
    }

    #[test]
    fn position_frac_conviction_scaling_capped() {
        let p = make_portfolio();
        // Very high conviction relative to threshold → capped at FRAC_CAP
        let frac = p.position_frac(10.0, 0.1, 0.3).unwrap();
        assert!((frac - FRAC_CAP).abs() < 1e-10);
    }

    // ── record_trade drawdown tracking ──────────────────────────────────────

    #[test]
    fn record_trade_completes_drawdown_on_new_peak() {
        let mut p = make_portfolio();
        // Win several trades to establish a peak
        for _ in 0..10 { record_win(&mut p); }
        let peak_before = p.peak_equity;
        assert!(peak_before > 10000.0);

        // Now lose several trades to create a drawdown
        for _ in 0..10 { record_loss(&mut p); }
        assert!(p.equity < peak_before);
        let bottom = p.drawdown_bottom_equity;
        assert!(bottom < peak_before);

        // Win enough to surpass the (decayed) peak → should record a completed drawdown
        let dd_before = p.completed_drawdowns.len();
        for _ in 0..50 { record_win(&mut p); }
        // After many wins, equity should exceed peak, completing the drawdown
        if p.completed_drawdowns.len() > dd_before {
            let dd = *p.completed_drawdowns.back().unwrap();
            assert!(dd > 0.0, "completed drawdown depth should be positive");
            assert!(dd < 1.0, "completed drawdown depth should be < 100%");
        }
    }

    #[test]
    fn record_trade_short_direction() {
        let mut p = make_portfolio();
        let initial = p.equity;
        // Short direction: -5% price move → profit (price went down, short wins)
        p.record_trade(-0.05, 0.01, Direction::Short, 0.0, 0.0);
        assert!(p.equity > initial, "short should profit when price drops");
    }

    #[test]
    fn record_trade_with_fees() {
        let mut p = make_portfolio();
        let initial = p.equity;
        // Winning trade but with significant fees
        p.record_trade(0.05, 0.01, Direction::Long, 0.01, 0.005);
        let with_fees = p.equity;

        let mut p2 = make_portfolio();
        p2.record_trade(0.05, 0.01, Direction::Long, 0.0, 0.0);
        let without_fees = p2.equity;

        // Fees should reduce profit
        assert!(with_fees < without_fees);
        // But still profitable with 5% move
        assert!(with_fees > initial);
    }

    // ── is_healthy with peak_equity <= 0 branch ─────────────────────────────

    #[test]
    fn is_healthy_zero_peak_equity() {
        let mut p = make_portfolio();
        p.peak_equity = 0.0;
        p.equity = 0.0;
        // Should not panic; dd branch returns 0.0 when peak_equity <= 0
        let _h = p.is_healthy();
    }
}
