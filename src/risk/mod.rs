//! Risk domain — portfolio health measurement and gating.
//!
//! Two templates:
//!   Template 2 (reaction): OnlineSubspace branches learn healthy manifold, residuals gate.
//!   Template 1 (prediction): risk manager Journal learns Healthy/Unhealthy from branch ratios.
//!
//! The branches measure. The manager predicts. Together they gate sizing.

pub mod manager;

// Risk manager (Template 1) lives in risk/manager.rs — Journal with Healthy/Unhealthy labels.
// Risk generalist (Template 2) is an OnlineSubspace on EnterpriseState — holistic cross-branch.

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

/// Per-branch residual ratios [0.1, 1.0]. Named fields prevent index confusion.
/// 6 branches: 5 specialists + 1 generalist (same shape as market observers).
pub struct BranchRatios {
    pub drawdown: f64,
    pub accuracy: f64,
    pub volatility: f64,
    pub correlation: f64,
    pub panel: f64,
    pub generalist: f64,
}

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
    pub drawdown_historical: Vector,
    pub accuracy_10: Vector,
    pub accuracy_50: Vector,
    pub accuracy_200: Vector,
    pub accuracy_trajectory: Vector,
    pub accuracy_divergence: Vector,
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
            drawdown_historical: vm.get_vector("drawdown-historical"),
            accuracy_10: vm.get_vector("accuracy-10"),
            accuracy_50: vm.get_vector("accuracy-50"),
            accuracy_200: vm.get_vector("accuracy-200"),
            accuracy_trajectory: vm.get_vector("accuracy-trajectory"),
            accuracy_divergence: vm.get_vector("accuracy-divergence"),
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
        thought(&atoms.drawdown_historical, scalar,
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
        thought(&atoms.accuracy_divergence, scalar, win_rate_10 - win_rate_200, 0.5),
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

/// Evaluate risk branches: encode (pmap), score (pmap), update (pfor-each).
/// Returns (worst_ratio, per_branch_ratios). The ratios feed the risk manager.
/// Also evaluates the generalist (holistic cross-branch pattern).
pub fn evaluate_risk_branches(
    branches: &mut [RiskBranch],
    generalist: &mut OnlineSubspace,
    portfolio: &Portfolio,
    atoms: &RiskAtoms,
    scalar: &holon::ScalarEncoder,
) -> (f64, BranchRatios) {
    use rayon::prelude::*;

    let branch_features = encode_risk_branches(portfolio, atoms, scalar);
    let healthy = portfolio.is_healthy() && portfolio.trades_taken >= 20;

    // pmap: score each branch independently (immutable read of subspace)
    let ratios: Vec<f64> = branches.par_iter().enumerate().map(|(branch_idx, branch)| {
        let features = &branch_features[branch_idx];
        if branch.subspace.n() >= 10 {
            let residual = branch.subspace.residual(features);
            let threshold = branch.subspace.threshold();
            if residual < threshold { 1.0 } else { (threshold / residual).max(0.1) }
        } else {
            1.0
        }
    }).collect();

    // pfor-each: update when healthy (disjoint branches)
    if healthy {
        branches.par_iter_mut().enumerate().for_each(|(branch_idx, branch)| {
            branch.subspace.update(&branch_features[branch_idx]);
        });
    }

    let mut worst_ratio = ratios.iter().fold(1.0_f64, |a, &b| a.min(b));

    // Generalist: bundle ALL branch feature vectors into one holistic thought.
    let branch_vecs: Vec<Vector> = branch_features.iter()
        .map(|f| Vector::from_f64(f))
        .collect();
    let branch_refs: Vec<&Vector> = branch_vecs.iter().collect();
    let generalist_thought = Primitives::bundle(&branch_refs);
    let generalist_features: Vec<f64> = generalist_thought.data().iter().map(|&v| v as f64).collect();
    let gen_ratio = if generalist.n() >= 10 {
        let residual = generalist.residual(&generalist_features);
        let threshold = generalist.threshold();
        let ratio = if residual < threshold { 1.0 }
            else { (threshold / residual).max(0.1) };
        worst_ratio = worst_ratio.min(ratio);
        ratio
    } else {
        1.0
    };
    if healthy { generalist.update(&generalist_features); }

    let mult = if branches[0].subspace.n() >= 10 { worst_ratio } else { 0.5 };
    let branch_ratios = BranchRatios {
        drawdown: ratios[0], accuracy: ratios[1], volatility: ratios[2],
        correlation: ratios[3], panel: ratios[4], generalist: gen_ratio,
    };
    (mult, branch_ratios)
}

/// Five risk branch feature vectors — [drawdown, accuracy, volatility, correlation, panel].
/// Each is a bundled thought vector at full dimensionality, ready for its OnlineSubspace.
fn encode_risk_branches(
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::portfolio::Portfolio;

    const TEST_DIMS: usize = 64;

    fn make_vm() -> VectorManager {
        VectorManager::new(TEST_DIMS)
    }

    fn make_atoms(vm: &VectorManager) -> RiskAtoms {
        RiskAtoms::new(vm)
    }

    fn make_scalar() -> holon::ScalarEncoder {
        holon::ScalarEncoder::new(TEST_DIMS)
    }

    fn make_branches() -> [RiskBranch; 5] {
        [
            RiskBranch::new("drawdown", TEST_DIMS),
            RiskBranch::new("accuracy", TEST_DIMS),
            RiskBranch::new("volatility", TEST_DIMS),
            RiskBranch::new("correlation", TEST_DIMS),
            RiskBranch::new("panel", TEST_DIMS),
        ]
    }

    // ── BranchRatios ─────────────────────────────────────────────────────────

    #[test]
    fn branch_ratios_has_named_fields() {
        let br = BranchRatios {
            drawdown: 0.9,
            accuracy: 0.8,
            volatility: 0.7,
            correlation: 0.6,
            panel: 0.5,
            generalist: 1.0,
        };
        assert!((br.drawdown - 0.9).abs() < 1e-10);
        assert!((br.accuracy - 0.8).abs() < 1e-10);
        assert!((br.volatility - 0.7).abs() < 1e-10);
        assert!((br.correlation - 0.6).abs() < 1e-10);
        assert!((br.panel - 0.5).abs() < 1e-10);
        assert!((br.generalist - 1.0).abs() < 1e-10);
    }

    // ── RiskBranch construction ──────────────────────────────────────────────

    #[test]
    fn risk_branch_new_has_zero_observations() {
        let branch = RiskBranch::new("test", TEST_DIMS);
        assert_eq!(branch.name, "test");
        assert_eq!(branch.subspace.n(), 0);
    }

    // ── RiskAtoms construction ───────────────────────────────────────────────

    #[test]
    fn risk_atoms_creates_distinct_vectors() {
        let vm = make_vm();
        let atoms = make_atoms(&vm);
        // Two different atoms should produce different vectors
        let sim = holon::similarity::Similarity::cosine(&atoms.drawdown, &atoms.accuracy_10);
        assert!(sim.abs() < 0.5, "distinct atoms should have low similarity, got {sim}");
    }

    // ── evaluate_risk_branches ───────────────────────────────────────────────

    #[test]
    fn evaluate_returns_default_when_no_observations() {
        let vm = make_vm();
        let atoms = make_atoms(&vm);
        let scalar = make_scalar();
        let mut branches = make_branches();
        let mut generalist = OnlineSubspace::with_params(TEST_DIMS, 8, 2.0, 0.01, 3.5, 100);
        let portfolio = Portfolio::new(10000.0, 0);

        let (mult, ratios) = evaluate_risk_branches(
            &mut branches, &mut generalist, &portfolio, &atoms, &scalar,
        );

        // With n < 10, all branches return 1.0, but the final mult uses 0.5 default
        assert!((mult - 0.5).abs() < 1e-10, "default mult should be 0.5, got {mult}");
        assert!((ratios.drawdown - 1.0).abs() < 1e-10);
        assert!((ratios.accuracy - 1.0).abs() < 1e-10);
        assert!((ratios.volatility - 1.0).abs() < 1e-10);
        assert!((ratios.correlation - 1.0).abs() < 1e-10);
        assert!((ratios.panel - 1.0).abs() < 1e-10);
        assert!((ratios.generalist - 1.0).abs() < 1e-10);
    }

    #[test]
    fn evaluate_returns_f64_and_branch_ratios() {
        let vm = make_vm();
        let atoms = make_atoms(&vm);
        let scalar = make_scalar();
        let mut branches = make_branches();
        let mut generalist = OnlineSubspace::with_params(TEST_DIMS, 8, 2.0, 0.01, 3.5, 100);
        let portfolio = Portfolio::new(10000.0, 0);

        let (mult, _ratios) = evaluate_risk_branches(
            &mut branches, &mut generalist, &portfolio, &atoms, &scalar,
        );

        // mult should be a valid f64 in [0.1, 1.0] or the 0.5 default
        assert!(mult >= 0.1 && mult <= 1.0, "mult out of range: {mult}");
    }

    #[test]
    fn evaluate_with_trained_branches() {
        let vm = make_vm();
        let atoms = make_atoms(&vm);
        let scalar = make_scalar();
        let mut branches = make_branches();
        let mut generalist = OnlineSubspace::with_params(TEST_DIMS, 8, 2.0, 0.01, 3.5, 100);

        // Build a portfolio with enough healthy trades to pass the is_healthy gate.
        // We need: low drawdown, >55% win rate last 50, positive mean return.
        let mut portfolio = Portfolio::new(10000.0, 0);
        portfolio.phase = crate::portfolio::Phase::Tentative;

        // Record trades that make the portfolio healthy: 70% wins
        for i in 0..100 {
            if i % 10 < 7 {
                // Win: +2% move, long
                portfolio.record_trade(0.02, 0.01, crate::journal::Direction::Long, 0.0, 0.0);
            } else {
                // Loss: -1% move, long (smaller losses than wins)
                portfolio.record_trade(-0.01, 0.01, crate::journal::Direction::Long, 0.0, 0.0);
            }

            // Feed each observation to the branches
            let branch_features = [
                encode_drawdown(&portfolio, &atoms, &scalar),
                encode_accuracy(&portfolio, &atoms, &scalar),
                encode_volatility(&portfolio, &atoms, &scalar),
                encode_correlation(&portfolio, &atoms, &scalar),
                encode_panel(&portfolio, &atoms, &scalar),
            ];
            for (idx, branch) in branches.iter_mut().enumerate() {
                branch.subspace.update(&branch_features[idx]);
            }
            // Also feed the generalist
            let bvecs: Vec<Vector> = branch_features.iter().map(|f| Vector::from_f64(f)).collect();
            let brefs: Vec<&Vector> = bvecs.iter().collect();
            let gen_thought = Primitives::bundle(&brefs);
            let gen_f: Vec<f64> = gen_thought.data().iter().map(|&v| v as f64).collect();
            generalist.update(&gen_f);
        }

        // Now all branches should have n >= 10
        assert!(branches[0].subspace.n() >= 10);

        // Evaluate — with trained branches and a healthy portfolio, should get real ratios
        let (mult, ratios) = evaluate_risk_branches(
            &mut branches, &mut generalist, &portfolio, &atoms, &scalar,
        );

        // mult should come from actual residual scoring now, not the 0.5 default
        assert!(mult >= 0.1 && mult <= 1.0, "mult out of range: {mult}");
        // Each ratio should be in [0.1, 1.0]
        assert!(ratios.drawdown >= 0.1 && ratios.drawdown <= 1.0);
        assert!(ratios.accuracy >= 0.1 && ratios.accuracy <= 1.0);
        assert!(ratios.volatility >= 0.1 && ratios.volatility <= 1.0);
        assert!(ratios.correlation >= 0.1 && ratios.correlation <= 1.0);
        assert!(ratios.panel >= 0.1 && ratios.panel <= 1.0);
        assert!(ratios.generalist >= 0.1 && ratios.generalist <= 1.0);
    }

    // ── encode helpers (private, tested via evaluate) ────────────────────────

    #[test]
    fn encode_drawdown_produces_correct_length() {
        let vm = make_vm();
        let atoms = make_atoms(&vm);
        let scalar = make_scalar();
        let portfolio = Portfolio::new(10000.0, 0);
        let vec = encode_drawdown(&portfolio, &atoms, &scalar);
        assert_eq!(vec.len(), TEST_DIMS, "drawdown vector should match dims");
    }

    #[test]
    fn encode_accuracy_produces_correct_length() {
        let vm = make_vm();
        let atoms = make_atoms(&vm);
        let scalar = make_scalar();
        let portfolio = Portfolio::new(10000.0, 0);
        let vec = encode_accuracy(&portfolio, &atoms, &scalar);
        assert_eq!(vec.len(), TEST_DIMS);
    }

    #[test]
    fn encode_volatility_empty_returns_zeros() {
        let vm = make_vm();
        let atoms = make_atoms(&vm);
        let scalar = make_scalar();
        let portfolio = Portfolio::new(10000.0, 0);
        let vec = encode_volatility(&portfolio, &atoms, &scalar);
        assert_eq!(vec.len(), TEST_DIMS);
        // With no trade returns, should be all zeros
        assert!(vec.iter().all(|&v| v == 0.0));
    }

    #[test]
    fn encode_correlation_empty_returns_zeros() {
        let vm = make_vm();
        let atoms = make_atoms(&vm);
        let scalar = make_scalar();
        let portfolio = Portfolio::new(10000.0, 0);
        let vec = encode_correlation(&portfolio, &atoms, &scalar);
        assert_eq!(vec.len(), TEST_DIMS);
        assert!(vec.iter().all(|&v| v == 0.0));
    }

    #[test]
    fn encode_panel_produces_correct_length() {
        let vm = make_vm();
        let atoms = make_atoms(&vm);
        let scalar = make_scalar();
        let portfolio = Portfolio::new(10000.0, 0);
        let vec = encode_panel(&portfolio, &atoms, &scalar);
        assert_eq!(vec.len(), TEST_DIMS);
    }
}
