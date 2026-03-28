use std::collections::{HashMap, VecDeque};
use std::fmt;

use holon::{Primitives, VectorManager, Vector};
use crate::journal::{Outcome, Prediction};

// ─── Trader (phase + equity) ─────────────────────────────────────────────────

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

pub struct Trader {
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
    pub trade_timestamps:   VecDeque<usize>, // candle index at resolution (500)
    pub dd_bottom_equity:   f64,             // deepest point of current drawdown
    pub trades_since_bottom: usize,          // trades since drawdown bottom
    pub completed_drawdowns: VecDeque<f64>,  // max depth of each completed dd (20)
}

#[derive(Default)]
pub struct YearStats { pub trades: usize, pub wins: usize, pub pnl: f64 }

impl Trader {
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
            trade_timestamps: VecDeque::new(),
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
    pub fn record_trade(&mut self, outcome_pct: f64, frac: f64, direction: Outcome, year: i32,
                     swap_fee: f64, slippage: f64) {
        let directional_return = match direction {
            Outcome::Buy   =>  outcome_pct,
            Outcome::Sell  => -outcome_pct,
            Outcome::Noise => return,
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
        let was_at_peak = self.equity >= self.peak_equity * 0.999;
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

    /// Encode portfolio state as rich risk thoughts — 204 atoms, ~54 facts.
    /// Separate hyperspace from market thoughts. Never bundled together.
    pub fn risk_facts(&self, vm: &VectorManager, expert_preds: Option<&[Prediction]>, generalist_pred: Option<&Prediction>, recent_trade_count: usize, candle_count: usize) -> (Vec<Vector>, Vec<String>) {
        let mut facts = Vec::with_capacity(60);
        let mut labels = Vec::with_capacity(60);

        // Drawdown
        let dd = if self.peak_equity > 0.0 {
            (self.peak_equity - self.equity) / self.peak_equity
        } else { 0.0 };
        let dd_zone = if dd < 0.001 { "drawdown-at-peak" }
            else if dd < 0.01 { "drawdown-shallow" }
            else if dd < 0.03 { "drawdown-moderate" }
            else { "drawdown-deep" };
        let dd_vec = Primitives::bind(
            &vm.get_vector("at"),
            &Primitives::bind(&vm.get_vector("drawdown"), &vm.get_vector(dd_zone)),
        );
        facts.push(dd_vec);
        labels.push(format!("(at drawdown {})", dd_zone));

        // Streak
        if !self.rolling.is_empty() {
            let last = *self.rolling.back().unwrap();
            let mut streak_len = 0usize;
            for &outcome in self.rolling.iter().rev() {
                if outcome == last { streak_len += 1; } else { break; }
            }
            let streak_dir = if last { "streak-winning" } else { "streak-losing" };
            let streak_size = if streak_len >= 5 { "streak-long" } else { "streak-short" };
            let s_vec = Primitives::bind(
                &vm.get_vector("at"),
                &Primitives::bind(
                    &vm.get_vector("streak"),
                    &Primitives::bind(&vm.get_vector(streak_dir), &vm.get_vector(streak_size)),
                ),
            );
            facts.push(s_vec);
            labels.push(format!("(at streak {} {})", streak_dir, streak_size));
        }

        // Recent accuracy
        if self.rolling.len() >= 10 {
            let recent_acc = self.rolling.iter().filter(|&&x| x).count() as f64
                / self.rolling.len() as f64;
            let acc_zone = if recent_acc > 0.60 { "accuracy-hot" }
                else if recent_acc < 0.45 { "accuracy-cold" }
                else { "accuracy-normal" };
            let a_vec = Primitives::bind(
                &vm.get_vector("at"),
                &Primitives::bind(&vm.get_vector("recent-accuracy"), &vm.get_vector(acc_zone)),
            );
            facts.push(a_vec);
            labels.push(format!("(at recent-accuracy {})", acc_zone));
        }

        // Equity curve direction (compare equity to initial)
        let eq_pct = (self.equity - self.initial_equity) / self.initial_equity;
        let eq_zone = if eq_pct > 0.01 { "equity-rising" }
            else if eq_pct < -0.01 { "equity-falling" }
            else { "equity-flat" };
        let e_vec = Primitives::bind(
            &vm.get_vector("at"),
            &Primitives::bind(&vm.get_vector("equity-curve"), &vm.get_vector(eq_zone)),
        );
        facts.push(e_vec);
        labels.push(format!("(at equity-curve {})", eq_zone));

        // ── Category 1: Drawdown dynamics (deep) ──────────────────────
        // Velocity: is drawdown accelerating or decelerating?
        if self.equity_at_trade.len() >= 5 {
            let dd_now = dd;
            let dd_5ago = if self.equity_at_trade.len() >= 5 {
                let eq5 = self.equity_at_trade[self.equity_at_trade.len() - 5];
                (self.peak_equity - eq5) / self.peak_equity
            } else { 0.0 };
            let vel_zone = if dd_now < 0.001 { "dd-recovering" }
                else if dd_now > dd_5ago + 0.01 { "dd-accelerating" }
                else if dd_now < dd_5ago - 0.005 { "dd-decelerating" }
                else { "dd-stable-dd" };
            let v = Primitives::bind(&vm.get_vector("at"),
                &Primitives::bind(&vm.get_vector("dd-velocity"), &vm.get_vector(vel_zone)));
            facts.push(v); labels.push(format!("(at dd-velocity {})", vel_zone));
        }

        // Duration: how many trades since peak?
        let trades_since_peak = self.trades_taken.saturating_sub(
            self.equity_at_trade.iter().enumerate()
                .filter(|(_, &eq)| eq >= self.peak_equity * 0.999)
                .map(|(i, _)| i).last().unwrap_or(0));
        let dur_zone = if trades_since_peak < 10 { "dd-brief" }
            else if trades_since_peak < 30 { "dd-medium-dur" }
            else if trades_since_peak < 100 { "dd-extended" }
            else { "dd-chronic" };
        let dv = Primitives::bind(&vm.get_vector("at"),
            &Primitives::bind(&vm.get_vector("dd-duration"), &vm.get_vector(dur_zone)));
        facts.push(dv); labels.push(format!("(at dd-duration {})", dur_zone));

        // Historical comparison
        if !self.completed_drawdowns.is_empty() {
            let mut sorted_dds: Vec<f64> = self.completed_drawdowns.iter().copied().collect();
            sorted_dds.sort_by(|a, b| a.partial_cmp(b).unwrap());
            let median = sorted_dds[sorted_dds.len() / 2];
            let max_dd = sorted_dds.last().copied().unwrap_or(0.0);
            let hist_zone = if dd > max_dd && dd > 0.01 { "dd-unprecedented" }
                else if dd > median { "dd-worst-quartile" }
                else { "dd-normal-range" };
            let hv = Primitives::bind(&vm.get_vector("at"),
                &Primitives::bind(&vm.get_vector("dd-historical"), &vm.get_vector(hist_zone)));
            facts.push(hv); labels.push(format!("(at dd-historical {})", hist_zone));
        }

        // ── Category 3: Win rate dynamics (multi-scale) ──────────────
        if self.rolling.len() >= 10 {
            let acc10 = self.win_rate_last_n(10);
            let acc_zone = |r: f64| -> &str {
                if r > 0.65 { "acc-hot" }
                else if r > 0.57 { "acc-warm" }
                else if r > 0.48 { "acc-normal-acc" }
                else if r > 0.40 { "acc-cool" }
                else { "acc-cold" }
            };
            let v10 = Primitives::bind(&vm.get_vector("at"),
                &Primitives::bind(&vm.get_vector("acc-10"), &vm.get_vector(acc_zone(acc10))));
            facts.push(v10); labels.push(format!("(at acc-10 {})", acc_zone(acc10)));

            if self.rolling.len() >= 50 {
                let acc50 = self.win_rate_last_n(50);
                let v50 = Primitives::bind(&vm.get_vector("at"),
                    &Primitives::bind(&vm.get_vector("acc-50"), &vm.get_vector(acc_zone(acc50))));
                facts.push(v50); labels.push(format!("(at acc-50 {})", acc_zone(acc50)));

                // Trajectory
                let traj = if acc10 > acc50 + 0.08 { "acc-improving" }
                    else if acc10 < acc50 - 0.08 { "acc-declining" }
                    else { "acc-stable-acc" };
                let tv = Primitives::bind(&vm.get_vector("at"),
                    &Primitives::bind(&vm.get_vector("acc-trajectory"), &vm.get_vector(traj)));
                facts.push(tv); labels.push(format!("(at acc-trajectory {})", traj));
            }

            if self.rolling.len() >= 200 {
                let acc200 = self.win_rate_last_n(200);
                let v200 = Primitives::bind(&vm.get_vector("at"),
                    &Primitives::bind(&vm.get_vector("acc-200"), &vm.get_vector(acc_zone(acc200))));
                facts.push(v200); labels.push(format!("(at acc-200 {})", acc_zone(acc200)));

                // Divergence: short vs long term
                let div = if acc10 > 0.60 && acc200 < 0.50 { "short-hot-long-cold" }
                    else if acc10 < 0.45 && acc200 > 0.55 { "short-cold-long-hot" }
                    else { "acc-aligned" };
                let dv = Primitives::bind(&vm.get_vector("at"),
                    &Primitives::bind(&vm.get_vector("acc-divergence"), &vm.get_vector(div)));
                facts.push(dv); labels.push(format!("(at acc-divergence {})", div));
            }
        }

        // ── Category 4: Return volatility ────────────────────────────
        if self.trade_returns.len() >= 20 {
            let returns: Vec<f64> = self.trade_returns.iter().rev().take(50).copied().collect();
            let n = returns.len() as f64;
            let mean = returns.iter().sum::<f64>() / n;
            let var = returns.iter().map(|r| (r - mean).powi(2)).sum::<f64>() / n;
            let vol = var.sqrt();

            if vol > 1e-10 {
                // Sharpe
                let sharpe = mean / vol;
                let sharpe_zone = if sharpe > 1.0 { "sharpe-excellent" }
                    else if sharpe > 0.3 { "sharpe-good" }
                    else if sharpe > 0.0 { "sharpe-mediocre" }
                    else { "sharpe-negative" };
                let sv = Primitives::bind(&vm.get_vector("at"),
                    &Primitives::bind(&vm.get_vector("trade-sharpe"), &vm.get_vector(sharpe_zone)));
                facts.push(sv); labels.push(format!("(at trade-sharpe {})", sharpe_zone));
            }

            // Worst trade
            let worst = returns.iter().copied().fold(0.0_f64, f64::min);
            let worst_zone = if worst > -0.003 { "worst-mild" }
                else if worst > -0.005 { "worst-moderate-wt" }
                else if worst > -0.01 { "worst-severe" }
                else { "worst-catastrophic" };
            let wv = Primitives::bind(&vm.get_vector("at"),
                &Primitives::bind(&vm.get_vector("worst-trade"), &vm.get_vector(worst_zone)));
            facts.push(wv); labels.push(format!("(at worst-trade {})", worst_zone));
        }

        // ── Category 9: Loss correlation ─────────────────────────────
        if self.rolling.len() >= 20 {
            // Loss density (last 20)
            let losses_20 = self.rolling.iter().rev().take(20).filter(|&&x| !x).count();
            let ld_zone = if losses_20 < 6 { "ld-sparse" }
                else if losses_20 < 10 { "ld-normal" }
                else if losses_20 < 14 { "ld-dense" }
                else { "ld-overwhelming" };
            let lv = Primitives::bind(&vm.get_vector("at"),
                &Primitives::bind(&vm.get_vector("loss-density"), &vm.get_vector(ld_zone)));
            facts.push(lv); labels.push(format!("(at loss-density {})", ld_zone));

            // Consecutive losses
            let mut consec = 0usize;
            for &outcome in self.rolling.iter().rev() {
                if !outcome { consec += 1; } else { break; }
            }
            let cl_zone = if consec == 0 { "cl-none" }
                else if consec <= 3 { "cl-short" }
                else if consec <= 7 { "cl-medium" }
                else { "cl-long" };
            let cv = Primitives::bind(&vm.get_vector("at"),
                &Primitives::bind(&vm.get_vector("consec-loss"), &vm.get_vector(cl_zone)));
            facts.push(cv); labels.push(format!("(at consec-loss {})", cl_zone));

            // Loss clustering (autocorrelation of outcomes)
            if self.rolling.len() >= 30 {
                let seq: Vec<f64> = self.rolling.iter().rev().take(50)
                    .map(|&w| if w { 1.0 } else { -1.0 }).collect();
                let sm = seq.iter().sum::<f64>() / seq.len() as f64;
                let sv = seq.iter().map(|v| (v - sm).powi(2)).sum::<f64>() / seq.len() as f64;
                if sv > 1e-10 {
                    let mut cov = 0.0_f64;
                    for i in 0..seq.len() - 1 {
                        cov += (seq[i] - sm) * (seq[i + 1] - sm);
                    }
                    cov /= (seq.len() - 1) as f64;
                    let autocorr = cov / sv;
                    let lp_zone = if autocorr > 0.2 { "losses-clustered" }
                        else if autocorr < -0.2 { "losses-alternating" }
                        else { "losses-random" };
                    let lpv = Primitives::bind(&vm.get_vector("at"),
                        &Primitives::bind(&vm.get_vector("loss-pattern"), &vm.get_vector(lp_zone)));
                    facts.push(lpv); labels.push(format!("(at loss-pattern {})", lp_zone));
                }
            }
        }

        // ── Category 7: Recovery dynamics ────────────────────────────
        if dd > 0.005 && self.dd_bottom_equity < self.peak_equity * 0.99 {
            let total_dd = self.peak_equity - self.dd_bottom_equity;
            let recovered = self.equity - self.dd_bottom_equity;
            let pct = if total_dd > 0.0 { (recovered / total_dd).max(0.0) } else { 0.0 };
            let rec_zone = if self.equity <= self.dd_bottom_equity { "no-recovery" }
                else if pct < 0.30 { "early-recovery" }
                else if pct < 0.70 { "half-recovered" }
                else { "nearly-recovered" };
            let rv = Primitives::bind(&vm.get_vector("at"),
                &Primitives::bind(&vm.get_vector("recovery-progress"), &vm.get_vector(rec_zone)));
            facts.push(rv); labels.push(format!("(at recovery-progress {})", rec_zone));

            // Recovery quality
            if self.trades_since_bottom >= 5 {
                let recent_wr = self.rolling.iter().rev()
                    .take(self.trades_since_bottom.min(50))
                    .filter(|&&x| x).count() as f64
                    / self.trades_since_bottom.min(50) as f64;
                let qual = if recent_wr > 0.60 { "recovery-solid" }
                    else if recent_wr > 0.50 { "recovery-fragile" }
                    else { "recovery-volatile" };
                let qv = Primitives::bind(&vm.get_vector("at"),
                    &Primitives::bind(&vm.get_vector("recovery-quality"), &vm.get_vector(qual)));
                facts.push(qv); labels.push(format!("(at recovery-quality {})", qual));
            }
        }

        // Expert state: how are the market experts doing?
        if let Some(gen) = generalist_pred {
            let conv_zone = if gen.conviction > 0.20 { "conviction-extreme" }
                else if gen.conviction > 0.12 { "conviction-moderate" }
                else { "conviction-weak" };
            let cv = Primitives::bind(
                &vm.get_vector("at"),
                &Primitives::bind(&vm.get_vector("market-conviction"), &vm.get_vector(conv_zone)),
            );
            facts.push(cv);
            labels.push(format!("(at market-conviction {})", conv_zone));
        }

        if let Some(eps) = expert_preds {
            // Expert agreement: do they agree on direction?
            let dirs: Vec<Option<Outcome>> = eps.iter().map(|p| p.direction).collect();
            let buy_count = dirs.iter().filter(|d| **d == Some(Outcome::Buy)).count();
            let sell_count = dirs.iter().filter(|d| **d == Some(Outcome::Sell)).count();
            let agree_zone = if buy_count >= 4 || sell_count >= 4 { "experts-agree" }
                else { "experts-disagree" };
            let ag = Primitives::bind(
                &vm.get_vector("at"),
                &Primitives::bind(&vm.get_vector("expert-agreement"), &vm.get_vector(agree_zone)),
            );
            facts.push(ag);
            labels.push(format!("(at expert-agreement {})", agree_zone));

            // Highest expert conviction
            let max_conv = eps.iter().map(|p| p.conviction).fold(0.0_f64, f64::max);
            let exp_zone = if max_conv > 0.15 { "expert-confident" } else { "expert-uncertain" };
            let ec = Primitives::bind(
                &vm.get_vector("at"),
                &Primitives::bind(&vm.get_vector("expert-agreement"), &vm.get_vector(exp_zone)),
            );
            facts.push(ec);
            labels.push(format!("(at expert-state {})", exp_zone));
        }

        // Trade density: am I overtrading?
        if candle_count > 100 {
            let density = self.trades_taken as f64 / candle_count as f64;
            let den_zone = if density > 0.05 { "density-high" }
                else if density < 0.01 { "density-low" }
                else { "density-normal" };
            let dv = Primitives::bind(
                &vm.get_vector("at"),
                &Primitives::bind(&vm.get_vector("trade-density"), &vm.get_vector(den_zone)),
            );
            facts.push(dv);
            labels.push(format!("(at trade-density {})", den_zone));
        }

        (facts, labels)
    }

    /// Raw f64 risk features for the OnlineSubspace (not VSA atoms).
    /// 15 continuous features capturing portfolio health.
    pub fn risk_features(&self) -> Vec<f64> {
        let dd = if self.peak_equity > 0.0 {
            (self.peak_equity - self.equity) / self.peak_equity
        } else { 0.0 };

        // Win rates at 3 scales
        let wr10 = self.win_rate_last_n(10);
        let wr50 = self.win_rate_last_n(50);
        let wr200 = self.win_rate_last_n(200);

        // Equity trajectory (last 10 trade returns mean)
        let recent_returns: Vec<f64> = self.trade_returns.iter().rev().take(10).copied().collect();
        let ret_mean = if recent_returns.is_empty() { 0.0 }
            else { recent_returns.iter().sum::<f64>() / recent_returns.len() as f64 };
        let ret_var = if recent_returns.len() >= 2 {
            recent_returns.iter().map(|r| (r - ret_mean).powi(2)).sum::<f64>() / recent_returns.len() as f64
        } else { 0.0 };
        let sharpe = if ret_var.sqrt() > 1e-10 { ret_mean / ret_var.sqrt() } else { 0.0 };

        // Streak
        let mut streak: f64 = 0.0;
        if let Some(&last) = self.rolling.back() {
            for &o in self.rolling.iter().rev() {
                if o == last { streak += if last { 1.0 } else { -1.0 }; } else { break; }
            }
        }

        // Loss clustering (autocorrelation lag-1, capped at 50)
        let autocorr = if self.rolling.len() >= 20 {
            let seq: Vec<f64> = self.rolling.iter().rev().take(50.min(self.rolling.len()))
                .map(|&w| if w { 1.0 } else { -1.0 }).collect();
            let sm = seq.iter().sum::<f64>() / seq.len() as f64;
            let sv = seq.iter().map(|v| (v - sm).powi(2)).sum::<f64>() / seq.len() as f64;
            if sv > 1e-10 {
                let mut cov = 0.0;
                for i in 0..seq.len() - 1 { cov += (seq[i] - sm) * (seq[i+1] - sm); }
                cov / ((seq.len() - 1) as f64 * sv)
            } else { 0.0 }
        } else { 0.0 };

        // Trade density
        let density = if self.trades_taken > 0 && !self.trade_timestamps.is_empty() {
            let recent = self.trade_timestamps.iter().rev()
                .take_while(|&&ts| ts + 200 > *self.trade_timestamps.back().unwrap_or(&0))
                .count();
            recent as f64 / 200.0
        } else { 0.0 };

        // Recovery progress
        let recovery = if self.peak_equity > self.dd_bottom_equity && dd > 0.005 {
            let total = self.peak_equity - self.dd_bottom_equity;
            ((self.equity - self.dd_bottom_equity) / total).max(0.0).min(1.0)
        } else { 1.0 }; // at peak = fully recovered

        // Worst recent trade
        let worst = self.trade_returns.iter().rev().take(20)
            .copied().fold(0.0_f64, f64::min);

        vec![
            dd,             // 0: drawdown depth
            wr10,           // 1: 10-trade win rate
            wr50,           // 2: 50-trade win rate
            wr200,          // 3: 200-trade win rate
            wr10 - wr50,    // 4: accuracy trajectory (positive = improving)
            ret_mean,       // 5: recent return mean
            ret_var.sqrt(), // 6: recent return volatility
            sharpe,         // 7: trade Sharpe
            streak,         // 8: current streak (positive = winning, negative = losing)
            autocorr,       // 9: loss clustering
            density,        // 10: trade density
            recovery,       // 11: recovery progress
            worst,          // 12: worst recent trade
            self.trades_since_bottom as f64 / 100.0, // 13: trades since dd bottom (normalized)
            self.trades_taken as f64 / 1000.0,       // 14: total experience (normalized)
        ]
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

    pub fn record_timestamp(&mut self, candle_idx: usize) {
        self.trade_timestamps.push_back(candle_idx);
        if self.trade_timestamps.len() > 500 { self.trade_timestamps.pop_front(); }
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
