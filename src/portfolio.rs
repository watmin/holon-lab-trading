use std::collections::{HashMap, VecDeque};
use std::fmt;

use holon::{Primitives, VectorManager, Vector};
use crate::journal::Direction;

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
    pub trades_skipped:  usize,
    pub rolling:         VecDeque<bool>,   // recent trade outcomes
    pub rolling_cap:     usize,
    pub by_year:         HashMap<i32, YearStats>,

    // Risk vocabulary infrastructure
    pub equity_at_trade:    VecDeque<f64>,   // equity after each trade (500)
    pub trade_returns:      VecDeque<f64>,   // directional return per trade (500)
    pub dd_bottom_equity:   f64,             // deepest point of current drawdown
    pub trades_since_bottom: usize,          // trades since drawdown bottom
    pub completed_drawdowns: VecDeque<f64>,  // max depth of each completed dd (20)
}

#[derive(Default)]
pub struct YearStats { pub trades: usize, pub wins: usize, pub pnl: f64 }

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
            trades_skipped: 0,
            rolling: VecDeque::new(),
            rolling_cap: 500,
            by_year: HashMap::new(),
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
            Phase::Tentative => 0.005,
            Phase::Confident => {
                let conf = (self.rolling_acc() - 0.5).max(0.0);
                if conf < 0.05      { 0.005 }
                else if conf < 0.10 { 0.01  }
                else                { (conf * 0.10).min(0.02) }
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
        // Cap at 0.05 (5%) to bound risk.
        let frac = if flip_threshold > 0.0 {
            (base * (conviction / flip_threshold)).min(0.05)
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
    pub fn record_trade(&mut self, outcome_pct: f64, frac: f64, direction: Direction, year: i32,
                     swap_fee: f64, slippage: f64) {
        let directional_return = match direction {
            Direction::Long  =>  outcome_pct,
            Direction::Short => -outcome_pct,
        };
        // Two-sided fee model: fees apply at each swap independently.
        // Entry: deploy × (1 - entry_cost) = actual position
        // Exit:  position × (1 + return) × (1 - exit_cost) = received
        let per_swap_cost = swap_fee + slippage;
        let after_entry = 1.0 - per_swap_cost;       // fraction surviving entry
        let gross_value = after_entry * (1.0 + directional_return); // position after price move
        let after_exit = gross_value * (1.0 - per_swap_cost);       // fraction surviving exit
        let net_return = after_exit - 1.0;            // net return on deployed capital
        let position_value = self.equity * frac;
        let pnl = position_value * net_return;
        let won = net_return > 0.0;
        self.equity += pnl;
        // Drawdown tracking
        if self.equity > self.peak_equity {
            if self.dd_bottom_equity < self.peak_equity * 0.999 {
                let dd_depth = (self.peak_equity - self.dd_bottom_equity) / self.peak_equity;
                self.completed_drawdowns.push_back(dd_depth);
                if self.completed_drawdowns.len() > 20 { self.completed_drawdowns.pop_front(); }
            }
            self.peak_equity = self.equity;
            self.dd_bottom_equity = self.equity;
            self.trades_since_bottom = 0;
        }
        // Rolling peak: decay toward current equity. The peak "forgets"
        // old highs over time. After ~700 trades at a lower level, the peak
        // has halved the gap. The cap reopens as the peak converges down.
        self.peak_equity = self.peak_equity * 0.999 + self.equity * 0.001;
        if self.equity < self.dd_bottom_equity {
            self.dd_bottom_equity = self.equity;
            self.trades_since_bottom = 0;
        } else {
            self.trades_since_bottom += 1;
        }
        // Trade history
        self.equity_at_trade.push_back(self.equity);
        if self.equity_at_trade.len() > 500 { self.equity_at_trade.pop_front(); }
        self.trade_returns.push_back(net_return);
        if self.trade_returns.len() > 500 { self.trade_returns.pop_front(); }
        self.trades_taken += 1;
        if won { self.trades_won += 1; }
        self.rolling.push_back(won);
        if self.rolling.len() > self.rolling_cap { self.rolling.pop_front(); }
        let ys = self.by_year.entry(year).or_default();
        ys.trades += 1;
        if won { ys.wins += 1; }
        ys.pnl += pnl;
        self.check_phase();
    }

    /// Five risk WAT vectors — named atoms bound with scalar magnitudes.
    /// Each branch gets a bundled thought vector at full dimensionality.
    pub fn risk_branch_wat(&self, vm: &VectorManager, scalar: &holon::ScalarEncoder) -> [Vec<f64>; 5] {
        // Helper: encode a named risk thought with a continuous value.
        // bind(atom_name, encode_linear(value, scale)) → f64 vector
        let thought = |name: &str, value: f64, scale: f64| -> Vector {
            let sv = scalar.encode(value, holon::ScalarMode::Linear { scale });
            Primitives::bind(&vm.get_vector(name), &sv)
        };

        // Helper: bundle thoughts into one f64 vector for the subspace.
        let bundle_f64 = |thoughts: Vec<Vector>| -> Vec<f64> {
            let refs: Vec<&Vector> = thoughts.iter().collect();
            let bundled = Primitives::bundle(&refs);
            bundled.data().iter().map(|&v| v as f64).collect()
        };

        // ── Now build the original features as named thoughts ────────
        let dd = if self.peak_equity > 0.0 { (self.peak_equity - self.equity) / self.peak_equity } else { 0.0 };
        let dd_vel = if self.equity_at_trade.len() >= 5 {
            let eq5 = self.equity_at_trade[self.equity_at_trade.len() - 5];
            let dd5 = if self.peak_equity > 0.0 { (self.peak_equity - eq5) / self.peak_equity } else { 0.0 };
            dd - dd5
        } else { 0.0 };
        let recovery = if self.peak_equity > self.dd_bottom_equity && dd > 0.005 {
            ((self.equity - self.dd_bottom_equity) / (self.peak_equity - self.dd_bottom_equity)).max(0.0).min(1.0)
        } else { 1.0 };
        let hist_worst = self.completed_drawdowns.iter().copied().fold(0.0_f64, f64::max);
        let dd_branch = bundle_f64(vec![
            thought("drawdown",         dd,                                          1.0),
            thought("dd-velocity",      dd_vel,                                      0.2),
            thought("recovery-progress",recovery,                                    2.0),
            thought("dd-duration",      self.trades_since_bottom as f64 / 100.0,     2.0),
            thought("dd-historical",    if hist_worst > 0.001 { dd / hist_worst } else { 0.0 }, 2.0),
        ]);

        let wr10 = self.win_rate_last_n(10);
        let wr50 = self.win_rate_last_n(50);
        let wr200 = self.win_rate_last_n(200);
        let acc_branch = bundle_f64(vec![
            thought("acc-10",          wr10,           2.0),
            thought("acc-50",          wr50,           2.0),
            thought("acc-200",         wr200,          2.0),
            thought("acc-trajectory",  wr10 - wr50,    0.5),
            thought("acc-divergence",  wr10 - wr200,   0.5),
        ]);

        let returns: Vec<f64> = self.trade_returns.iter().rev().take(50).copied().collect();
        let vol_branch = if returns.len() >= 5 {
            let n = returns.len() as f64;
            let mean = returns.iter().sum::<f64>() / n;
            let var = returns.iter().map(|r| (r - mean).powi(2)).sum::<f64>() / n;
            let vol = var.sqrt();
            let sharpe = if vol > 1e-10 { mean / vol } else { 0.0 };
            let worst = returns.iter().copied().fold(0.0_f64, f64::min);
            let best = returns.iter().copied().fold(0.0_f64, f64::max);
            let skew = if vol > 1e-10 { returns.iter().map(|r| ((r - mean) / vol).powi(3)).sum::<f64>() / n } else { 0.0 };
            bundle_f64(vec![
                thought("pnl-vol",      vol,     0.1),
                thought("trade-sharpe", sharpe,  4.0),
                thought("worst-trade",  worst,   0.1),
                thought("return-skew",  skew,    4.0),
                thought("equity-curve", best,    0.1),
            ])
        } else { vec![0.0; vm.dimensions()] };

        let corr_branch = if self.rolling.len() >= 20 {
            let seq: Vec<f64> = self.rolling.iter().rev().take(50).map(|&w| if w { 1.0 } else { -1.0 }).collect();
            let sm = seq.iter().sum::<f64>() / seq.len() as f64;
            let sv = seq.iter().map(|v| (v - sm).powi(2)).sum::<f64>() / seq.len() as f64;
            let ac = if sv > 1e-10 { let mut c = 0.0; for i in 0..seq.len()-1 { c += (seq[i]-sm)*(seq[i+1]-sm); } c / ((seq.len()-1) as f64 * sv) } else { 0.0 };
            let ld = self.rolling.iter().rev().take(20).filter(|&&x| !x).count() as f64 / 20.0;
            let mut consec = 0.0_f64; for &o in self.rolling.iter().rev() { if !o { consec += 1.0; } else { break; } }
            bundle_f64(vec![
                thought("loss-pattern",  ac,            2.0),
                thought("loss-density",  ld,            2.0),
                thought("consec-loss",   consec / 10.0, 2.0),
                thought("trade-density", self.trades_taken as f64 / 1000.0, 2.0),
                thought("streak",        ac.signum(),   2.0), // direction of clustering
            ])
        } else { vec![0.0; vm.dimensions()] };

        let eq_pct = (self.equity - self.initial_equity) / self.initial_equity;
        let mut streak_val = 0.0_f64;
        if let Some(&last) = self.rolling.back() { for &o in self.rolling.iter().rev() { if o == last { streak_val += if last { 1.0 } else { -1.0 }; } else { break; } } }
        let wr_all = if self.trades_taken > 0 { self.trades_won as f64 / self.trades_taken as f64 } else { 0.5 };
        let panel_branch = bundle_f64(vec![
            thought("equity-curve",    eq_pct,                                  2.0),
            thought("streak",          streak_val / 10.0,                       2.0),
            thought("recent-accuracy", wr_all,                                  2.0),
            thought("trade-density",   self.trades_taken as f64 / 1000.0,       2.0),
            thought("trade-frequency", (self.trades_taken as f64).sqrt() / 30.0, 2.0),
        ]);

        [dd_branch, acc_branch, vol_branch, corr_branch, panel_branch]
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

        dd < 0.02 && wr50 > 0.55 && ret_mean > 0.0
    }

    pub fn win_rate_last_n(&self, n: usize) -> f64 {
        let recent: Vec<&bool> = self.rolling.iter().rev().take(n).collect();
        if recent.is_empty() { return 0.5; }
        recent.iter().filter(|&&x| *x).count() as f64 / recent.len() as f64
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
            Phase::Tentative => { if n >= 500 && acc > 0.52 { self.phase = Phase::Confident; } }
            Phase::Confident => { if n >= 200 && acc < 0.50 { self.phase = Phase::Tentative; } }
            Phase::Observe   => {}
        }
    }
}
