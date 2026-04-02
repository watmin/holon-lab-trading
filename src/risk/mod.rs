//! Risk domain — portfolio health measurement and gating.
//!
//! Each branch measures health in its own domain. The worst residual drives
//! the risk multiplier. Gated updates: only learn from healthy states.
//!
//! Future: risk/manager.rs (risk manager encoding from branch signals).

// rune:scry(aspirational) — risk.wat specifies a risk MANAGER with Journal-based discriminant,
// Healthy/Unhealthy labels, and conviction-based trade rejection. Current implementation has
// only bare OnlineSubspace branches with threshold-based risk_mult gating (no risk journal,
// no risk labels, no risk discriminant).

// rune:scry(aspirational) — risk.wat specifies a risk generalist (#14) that sees ALL risk
// dimensions simultaneously via OnlineSubspace. Not yet implemented.

// rune:scry(aspirational) — risk.wat specifies a risk-alpha-journal with Profitable/Unprofitable
// labels that learns from alpha (counterfactual: did the last action beat inaction?). Not yet
// implemented — requires treasury alpha tracking.

use holon::memory::OnlineSubspace;
use holon::{Primitives, ScalarMode, VectorManager, Vector};

use crate::portfolio::Portfolio;

pub struct RiskBranch {
    pub name: &'static str,
    pub subspace: OnlineSubspace,
}

impl RiskBranch {
    pub fn new(name: &'static str, dims: usize) -> Self {
        Self {
            name,
            subspace: OnlineSubspace::with_params(dims, 8, 2.0, 0.01, 3.5, 100),
        }
    }
}

// ─── Risk encoding ──────────────────────────────────────────────────────────────
// Five branches matching wat/risk/mod.wat: drawdown, accuracy, volatility,
// correlation, panel. Each encodes named thoughts (bind atom with scalar) and
// bundles them into one f64 vector for the corresponding OnlineSubspace.

/// Encode a named risk thought: bind(atom, encode_linear(value, scale)).
fn thought(vm: &VectorManager, scalar: &holon::ScalarEncoder, name: &str, value: f64, scale: f64) -> Vector {
    let sv = scalar.encode(value, ScalarMode::Linear { scale });
    Primitives::bind(&vm.get_vector(name), &sv)
}

/// Bundle thought vectors into one f64 vector for a subspace.
fn bundle_f64(thoughts: Vec<Vector>) -> Vec<f64> {
    let refs: Vec<&Vector> = thoughts.iter().collect();
    let bundled = Primitives::bundle(&refs);
    bundled.data().iter().map(|&v| v as f64).collect()
}

fn encode_drawdown(portfolio: &Portfolio, vm: &VectorManager, scalar: &holon::ScalarEncoder) -> Vec<f64> {
    let dd = if portfolio.peak_equity > 0.0 {
        (portfolio.peak_equity - portfolio.equity) / portfolio.peak_equity
    } else {
        0.0
    };
    let dd_vel = if portfolio.equity_at_trade.len() >= 5 {
        let eq5 = portfolio.equity_at_trade[portfolio.equity_at_trade.len() - 5];
        let dd5 = if portfolio.peak_equity > 0.0 {
            (portfolio.peak_equity - eq5) / portfolio.peak_equity
        } else {
            0.0
        };
        dd - dd5
    } else {
        0.0
    };
    let recovery = if portfolio.peak_equity > portfolio.dd_bottom_equity && dd > 0.005 {
        ((portfolio.equity - portfolio.dd_bottom_equity)
            / (portfolio.peak_equity - portfolio.dd_bottom_equity))
            .max(0.0)
            .min(1.0)
    } else {
        1.0
    };
    let hist_worst = portfolio
        .completed_drawdowns
        .iter()
        .copied()
        .fold(0.0_f64, f64::max);
    bundle_f64(vec![
        thought(vm, scalar, "drawdown", dd, 1.0),
        thought(vm, scalar, "drawdown-velocity", dd_vel, 0.2),
        thought(vm, scalar, "recovery-progress", recovery, 2.0),
        thought(
            vm,
            scalar,
            "drawdown-duration",
            portfolio.trades_since_bottom as f64 / 100.0,
            2.0,
        ),
        thought(
            vm,
            scalar,
            "dd-historical",
            if hist_worst > 0.001 {
                dd / hist_worst
            } else {
                0.0
            },
            2.0,
        ),
    ])
}

fn encode_accuracy(portfolio: &Portfolio, vm: &VectorManager, scalar: &holon::ScalarEncoder) -> Vec<f64> {
    let wr10 = portfolio.win_rate_last_n(10);
    let wr50 = portfolio.win_rate_last_n(50);
    let wr200 = portfolio.win_rate_last_n(200);
    bundle_f64(vec![
        thought(vm, scalar, "accuracy-10", wr10, 2.0),
        thought(vm, scalar, "accuracy-50", wr50, 2.0),
        thought(vm, scalar, "accuracy-200", wr200, 2.0),
        thought(vm, scalar, "accuracy-trajectory", wr10 - wr50, 0.5),
        thought(vm, scalar, "acc-divergence", wr10 - wr200, 0.5),
    ])
}

fn encode_volatility(
    portfolio: &Portfolio,
    vm: &VectorManager,
    scalar: &holon::ScalarEncoder,
) -> Vec<f64> {
    let returns: Vec<f64> = portfolio
        .trade_returns
        .iter()
        .rev()
        .take(50)
        .copied()
        .collect();
    if returns.len() >= 5 {
        let n = returns.len() as f64;
        let mean = returns.iter().sum::<f64>() / n;
        let var = returns.iter().map(|r| (r - mean).powi(2)).sum::<f64>() / n;
        let vol = var.sqrt();
        let sharpe = if vol > 1e-10 { mean / vol } else { 0.0 };
        let worst = returns.iter().copied().fold(0.0_f64, f64::min);
        let best = returns.iter().copied().fold(0.0_f64, f64::max);
        let skew = if vol > 1e-10 {
            returns
                .iter()
                .map(|r| ((r - mean) / vol).powi(3))
                .sum::<f64>()
                / n
        } else {
            0.0
        };
        bundle_f64(vec![
            thought(vm, scalar, "pnl-vol", vol, 0.1),
            thought(vm, scalar, "trade-sharpe", sharpe, 4.0),
            thought(vm, scalar, "worst-trade", worst, 0.1),
            thought(vm, scalar, "return-skew", skew, 4.0),
            thought(vm, scalar, "equity-curve", best, 0.1),
        ])
    } else {
        vec![0.0; vm.dimensions()]
    }
}

fn encode_correlation(
    portfolio: &Portfolio,
    vm: &VectorManager,
    scalar: &holon::ScalarEncoder,
) -> Vec<f64> {
    if portfolio.rolling.len() >= 20 {
        let seq: Vec<f64> = portfolio
            .rolling
            .iter()
            .rev()
            .take(50)
            .map(|&w| if w { 1.0 } else { -1.0 })
            .collect();
        let seq_mean = seq.iter().sum::<f64>() / seq.len() as f64;
        let seq_var = seq
            .iter()
            .map(|v| (v - seq_mean).powi(2))
            .sum::<f64>()
            / seq.len() as f64;
        let autocorr = if seq_var > 1e-10 {
            let mut c = 0.0;
            for i in 0..seq.len() - 1 {
                c += (seq[i] - seq_mean) * (seq[i + 1] - seq_mean);
            }
            c / ((seq.len() - 1) as f64 * seq_var)
        } else {
            0.0
        };
        let loss_density = portfolio
            .rolling
            .iter()
            .rev()
            .take(20)
            .filter(|&&x| !x)
            .count() as f64
            / 20.0;
        let mut consec_losses = 0.0_f64;
        for &o in portfolio.rolling.iter().rev() {
            if !o {
                consec_losses += 1.0;
            } else {
                break;
            }
        }
        bundle_f64(vec![
            thought(vm, scalar, "loss-pattern", autocorr, 2.0),
            thought(vm, scalar, "loss-density", loss_density, 2.0),
            thought(vm, scalar, "consec-loss", consec_losses / 10.0, 2.0),
            thought(
                vm,
                scalar,
                "trade-density",
                portfolio.trades_taken as f64 / 1000.0,
                2.0,
            ),
            thought(vm, scalar, "streak", autocorr.signum(), 2.0),
        ])
    } else {
        vec![0.0; vm.dimensions()]
    }
}

fn encode_panel(portfolio: &Portfolio, vm: &VectorManager, scalar: &holon::ScalarEncoder) -> Vec<f64> {
    let eq_pct =
        (portfolio.equity - portfolio.initial_equity) / portfolio.initial_equity;
    let mut streak_val = 0.0_f64;
    if let Some(&last) = portfolio.rolling.back() {
        for &o in portfolio.rolling.iter().rev() {
            if o == last {
                streak_val += if last { 1.0 } else { -1.0 };
            } else {
                break;
            }
        }
    }
    let win_rate_all = if portfolio.trades_taken > 0 {
        portfolio.trades_won as f64 / portfolio.trades_taken as f64
    } else {
        0.5
    };
    bundle_f64(vec![
        thought(vm, scalar, "equity-curve", eq_pct, 2.0),
        thought(vm, scalar, "streak", streak_val / 10.0, 2.0),
        thought(vm, scalar, "recent-accuracy", win_rate_all, 2.0),
        thought(
            vm,
            scalar,
            "trade-density",
            portfolio.trades_taken as f64 / 1000.0,
            2.0,
        ),
        thought(
            vm,
            scalar,
            "trade-frequency",
            (portfolio.trades_taken as f64).sqrt() / 30.0,
            2.0,
        ),
    ])
}

/// Five risk branch feature vectors — [drawdown, accuracy, volatility, correlation, panel].
/// Each is a bundled thought vector at full dimensionality, ready for its OnlineSubspace.
pub fn encode_risk_branches(
    portfolio: &Portfolio,
    vm: &VectorManager,
    scalar: &holon::ScalarEncoder,
) -> [Vec<f64>; 5] {
    [
        encode_drawdown(portfolio, vm, scalar),
        encode_accuracy(portfolio, vm, scalar),
        encode_volatility(portfolio, vm, scalar),
        encode_correlation(portfolio, vm, scalar),
        encode_panel(portfolio, vm, scalar),
    ]
}
