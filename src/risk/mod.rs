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
// VectorManager used only by RiskAtoms::new

use crate::portfolio::Portfolio;

// ─── Named constants (mirror wat/risk/mod.wat) ─────────────────────────────────
const VOLATILITY_WINDOW: usize = 50;        // rolling window for volatility/correlation outcomes
const CORRELATION_MIN_LEN: usize = 20;      // minimum trades before correlation branch activates
const LOSS_DENSITY_WINDOW: usize = 20;      // window for recent loss fraction
const DD_VELOCITY_LOOKBACK: usize = 5;      // trades back for drawdown velocity
const RECOVERY_THRESHOLD: f64 = 0.005;      // drawdown below this counts as recovered
const HIST_WORST_THRESHOLD: f64 = 0.001;    // ignore historical worst below this
const TRADES_SCALE: f64 = 100.0;            // normalise trades-since-bottom
const STREAK_SCALE: f64 = 10.0;             // normalise consecutive-loss / streak length
const DENSITY_SCALE: f64 = 1000.0;          // normalise lifetime trade count
const FREQUENCY_SCALE: f64 = 30.0;          // normalise sqrt(trades) frequency term

pub struct RiskBranch {
    pub name: &'static str,
    pub subspace: OnlineSubspace,
}

impl RiskBranch {
    pub fn new(name: &'static str, dims: usize) -> Self {
        Self {
            name,
            // OnlineSubspace::with_params(dims, n_components, learning_rate, forget_rate, threshold_sigma, min_observations)
            subspace: OnlineSubspace::with_params(dims, 8, 2.0, 0.01, 3.5, 100),
        }
    }
}

// ─── Risk encoding ──────────────────────────────────────────────────────────────
// Five branches matching wat/risk/mod.wat: drawdown, accuracy, volatility,
// correlation, panel. Each encodes named thoughts (bind atom with scalar) and
// bundles them into one f64 vector for the corresponding OnlineSubspace.

/// Pre-warmed atom vectors for all 25 risk encoding dimensions.
/// Created once at startup, passed through CandleContext.
pub struct RiskAtoms {
    pub drawdown: Vector,
    pub drawdown_velocity: Vector,
    pub recovery_progress: Vector,
    pub drawdown_duration: Vector,
    pub dd_historical: Vector,
    pub accuracy_10: Vector,
    pub accuracy_50: Vector,
    pub accuracy_200: Vector,
    pub accuracy_trajectory: Vector,
    pub acc_divergence: Vector,
    pub pnl_vol: Vector,
    pub trade_sharpe: Vector,
    pub worst_trade: Vector,
    pub return_skew: Vector,
    pub vol_best_trade: Vector,
    pub loss_pattern: Vector,
    pub loss_density: Vector,
    pub consec_loss: Vector,
    pub corr_trade_density: Vector,
    pub corr_autocorr_sign: Vector,
    pub panel_equity_pct: Vector,
    pub panel_streak: Vector,
    pub recent_accuracy: Vector,
    pub panel_trade_density: Vector,
    pub trade_frequency: Vector,
}

impl RiskAtoms {
    pub fn new(vm: &VectorManager) -> Self {
        Self {
            drawdown: vm.get_vector("drawdown"),
            drawdown_velocity: vm.get_vector("drawdown-velocity"),
            recovery_progress: vm.get_vector("recovery-progress"),
            drawdown_duration: vm.get_vector("drawdown-duration"),
            dd_historical: vm.get_vector("dd-historical"),
            accuracy_10: vm.get_vector("accuracy-10"),
            accuracy_50: vm.get_vector("accuracy-50"),
            accuracy_200: vm.get_vector("accuracy-200"),
            accuracy_trajectory: vm.get_vector("accuracy-trajectory"),
            acc_divergence: vm.get_vector("acc-divergence"),
            pnl_vol: vm.get_vector("pnl-vol"),
            trade_sharpe: vm.get_vector("trade-sharpe"),
            worst_trade: vm.get_vector("worst-trade"),
            return_skew: vm.get_vector("return-skew"),
            vol_best_trade: vm.get_vector("vol-best-trade"),
            loss_pattern: vm.get_vector("loss-pattern"),
            loss_density: vm.get_vector("loss-density"),
            consec_loss: vm.get_vector("consec-loss"),
            corr_trade_density: vm.get_vector("corr-trade-density"),
            corr_autocorr_sign: vm.get_vector("corr-autocorr-sign"),
            panel_equity_pct: vm.get_vector("panel-equity-pct"),
            panel_streak: vm.get_vector("panel-streak"),
            recent_accuracy: vm.get_vector("recent-accuracy"),
            panel_trade_density: vm.get_vector("panel-trade-density"),
            trade_frequency: vm.get_vector("trade-frequency"),
        }
    }
}

/// Encode a risk thought: bind(pre-warmed atom, encode_linear(value, scale)).
fn thought(atom: &Vector, scalar: &holon::ScalarEncoder, value: f64, scale: f64) -> Vector {
    let sv = scalar.encode(value, ScalarMode::Linear { scale });
    Primitives::bind(atom, &sv)
}

/// Bundle thought vectors into one f64 vector for a subspace.
fn bundle_f64(thoughts: Vec<Vector>) -> Vec<f64> {
    let refs: Vec<&Vector> = thoughts.iter().collect();
    let bundled = Primitives::bundle(&refs);
    bundled.data().iter().map(|&v| v as f64).collect()
}

fn encode_drawdown(portfolio: &Portfolio, atoms: &RiskAtoms, scalar: &holon::ScalarEncoder) -> Vec<f64> {
    let drawdown = if portfolio.peak_equity > 0.0 {
        (portfolio.peak_equity - portfolio.equity) / portfolio.peak_equity
    } else {
        0.0
    };
    let drawdown_velocity = if portfolio.equity_at_trade.len() >= DD_VELOCITY_LOOKBACK {
        let eq5 = portfolio.equity_at_trade[portfolio.equity_at_trade.len() - DD_VELOCITY_LOOKBACK];
        let dd5 = if portfolio.peak_equity > 0.0 {
            (portfolio.peak_equity - eq5) / portfolio.peak_equity
        } else {
            0.0
        };
        drawdown - dd5
    } else {
        0.0
    };
    let recovery = if portfolio.peak_equity > portfolio.dd_bottom_equity && drawdown > RECOVERY_THRESHOLD {
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
        thought(&atoms.drawdown, scalar, drawdown, 1.0),
        thought(&atoms.drawdown_velocity, scalar, drawdown_velocity, 0.2),
        thought(&atoms.recovery_progress, scalar, recovery, 2.0),
        thought(&atoms.drawdown_duration, scalar,
            portfolio.trades_since_bottom as f64 / TRADES_SCALE, 2.0),
        thought(&atoms.dd_historical, scalar,
            if hist_worst > HIST_WORST_THRESHOLD { drawdown / hist_worst } else { 0.0 }, 2.0),
    ])
}

fn encode_accuracy(portfolio: &Portfolio, atoms: &RiskAtoms, scalar: &holon::ScalarEncoder) -> Vec<f64> {
    let win_rate_10 = portfolio.win_rate_last_n(10);
    let win_rate_50 = portfolio.win_rate_last_n(50);
    let win_rate_200 = portfolio.win_rate_last_n(200);
    bundle_f64(vec![
        thought(&atoms.accuracy_10, scalar, win_rate_10, 2.0),
        thought(&atoms.accuracy_50, scalar, win_rate_50, 2.0),
        thought(&atoms.accuracy_200, scalar, win_rate_200, 2.0),
        thought(&atoms.accuracy_trajectory, scalar, win_rate_10 - win_rate_50, 0.5),
        thought(&atoms.acc_divergence, scalar, win_rate_10 - win_rate_200, 0.5),
    ])
}

fn encode_volatility(
    portfolio: &Portfolio,
    atoms: &RiskAtoms,
    scalar: &holon::ScalarEncoder,
) -> Vec<f64> {
    let returns: Vec<f64> = portfolio
        .trade_returns
        .iter()
        .rev()
        .take(VOLATILITY_WINDOW)
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
            thought(&atoms.pnl_vol, scalar, vol, 0.1),
            thought(&atoms.trade_sharpe, scalar, sharpe, 4.0),
            thought(&atoms.worst_trade, scalar, worst, 0.1),
            thought(&atoms.return_skew, scalar, skew, 4.0),
            thought(&atoms.vol_best_trade, scalar, best, 0.1),
        ])
    } else {
        vec![0.0; atoms.drawdown.data().len()]
    }
}

fn encode_correlation(
    portfolio: &Portfolio,
    atoms: &RiskAtoms,
    scalar: &holon::ScalarEncoder,
) -> Vec<f64> {
    if portfolio.rolling.len() >= CORRELATION_MIN_LEN {
        let seq: Vec<f64> = portfolio
            .rolling
            .iter()
            .rev()
            .take(VOLATILITY_WINDOW)
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
        let loss_density = seq.iter().take(LOSS_DENSITY_WINDOW).filter(|&&v| v < 0.0).count() as f64 / LOSS_DENSITY_WINDOW as f64;
        let mut consec_losses = 0.0_f64;
        for &v in &seq {
            if v < 0.0 { consec_losses += 1.0; } else { break; }
        }
        bundle_f64(vec![
            thought(&atoms.loss_pattern, scalar, autocorr, 2.0),
            thought(&atoms.loss_density, scalar, loss_density, 2.0),
            thought(&atoms.consec_loss, scalar, consec_losses / STREAK_SCALE, 2.0),
            thought(&atoms.corr_trade_density, scalar, portfolio.trades_taken as f64 / DENSITY_SCALE, 2.0),
            thought(&atoms.corr_autocorr_sign, scalar, autocorr.signum(), 2.0),
        ])
    } else {
        vec![0.0; atoms.drawdown.data().len()]
    }
}

fn encode_panel(portfolio: &Portfolio, atoms: &RiskAtoms, scalar: &holon::ScalarEncoder) -> Vec<f64> {
    let eq_pct =
        (portfolio.equity - portfolio.initial_equity) / portfolio.initial_equity;
    let streak_val = portfolio.streak();
    let win_rate_all = if portfolio.trades_taken > 0 {
        portfolio.trades_won as f64 / portfolio.trades_taken as f64
    } else {
        0.5
    };
    bundle_f64(vec![
        thought(&atoms.panel_equity_pct, scalar, eq_pct, 2.0),
        thought(&atoms.panel_streak, scalar, streak_val / STREAK_SCALE, 2.0),
        thought(&atoms.recent_accuracy, scalar, win_rate_all, 2.0),
        thought(&atoms.panel_trade_density, scalar, portfolio.trades_taken as f64 / DENSITY_SCALE, 2.0),
        thought(&atoms.trade_frequency, scalar, (portfolio.trades_taken as f64).sqrt() / FREQUENCY_SCALE, 2.0),
    ])
}

/// Evaluate risk branches: encode features, score anomalies, update if healthy.
/// Returns the risk multiplier (1.0 = fully healthy, 0.1 = worst allowed).
/// Gated updates: only learn from healthy states so the subspaces model
/// what "good" looks like, not what "crisis" looks like.
pub fn evaluate_risk_branches(
    branches: &mut [RiskBranch],
    portfolio: &Portfolio,
    atoms: &RiskAtoms,
    scalar: &holon::ScalarEncoder,
) -> f64 {
    let branch_features = encode_risk_branches(portfolio, atoms, scalar);
    let mut worst_ratio = 1.0_f64;
    let healthy = portfolio.is_healthy() && portfolio.trades_taken >= 20;
    for (branch_idx, branch) in branches.iter_mut().enumerate() {
        let features = &branch_features[branch_idx];
        if branch.subspace.n() >= 10 {
            let residual = branch.subspace.residual(features);
            let threshold = branch.subspace.threshold();
            let ratio = if residual < threshold { 1.0 }
                else { (threshold / residual).max(0.1) };
            worst_ratio = worst_ratio.min(ratio);
        }
        if healthy { branch.subspace.update(features); }
    }
    if branches[0].subspace.n() >= 10 { worst_ratio } else { 0.5 }
}

/// Five risk branch feature vectors — [drawdown, accuracy, volatility, correlation, panel].
/// Each is a bundled thought vector at full dimensionality, ready for its OnlineSubspace.
pub fn encode_risk_branches(
    portfolio: &Portfolio,
    atoms: &RiskAtoms,
    scalar: &holon::ScalarEncoder,
) -> [Vec<f64>; 5] {
    [
        encode_drawdown(portfolio, atoms, scalar),
        encode_accuracy(portfolio, atoms, scalar),
        encode_volatility(portfolio, atoms, scalar),
        encode_correlation(portfolio, atoms, scalar),
        encode_panel(portfolio, atoms, scalar),
    ]
}
