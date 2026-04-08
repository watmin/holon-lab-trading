//! Risk manager — Template 1 (prediction) over branch residual ratios.
//!
//! The five risk branches produce residual ratios [0.1, 1.0].
//! The risk manager encodes those ratios as a thought vector,
//! learns Healthy/Unhealthy from portfolio outcomes, and produces
//! a conviction about portfolio health.
//!
//! Same pattern as market/manager: encode specialist outputs → Journal
//! → conviction → gate. The risk manager modulates, it doesn't decide.

use holon::{Primitives, ScalarEncoder, ScalarMode, Vector, VectorManager};
use holon::memory::Journal;
use crate::journal::Label;

/// Immutable atom vectors for risk manager encoding.
pub struct RiskManagerAtoms {
    pub drawdown_branch: Vector,
    pub accuracy_branch: Vector,
    pub volatility_branch: Vector,
    pub correlation_branch: Vector,
    pub panel_branch: Vector,
    pub generalist_branch: Vector,
}

impl RiskManagerAtoms {
    pub fn new(vm: &VectorManager) -> Self {
        Self {
            drawdown_branch: vm.get_vector("risk-drawdown-branch"),
            accuracy_branch: vm.get_vector("risk-accuracy-branch"),
            volatility_branch: vm.get_vector("risk-volatility-branch"),
            correlation_branch: vm.get_vector("risk-correlation-branch"),
            panel_branch: vm.get_vector("risk-panel-branch"),
            generalist_branch: vm.get_vector("risk-generalist-branch"),
        }
    }
}

/// Encode branch residual ratios as one risk manager thought.
/// Each ratio is [0.1, 1.0] — 1.0 = healthy, 0.1 = worst allowed.
pub fn encode_risk_manager_thought(
    ratios: &super::BranchRatios,
    atoms: &RiskManagerAtoms,
    scalar: &ScalarEncoder,
) -> Vector {
    Primitives::bundle(&[
        &Primitives::bind(&atoms.drawdown_branch, &scalar.encode(ratios.drawdown, ScalarMode::Linear { scale: 1.0 })),
        &Primitives::bind(&atoms.accuracy_branch, &scalar.encode(ratios.accuracy, ScalarMode::Linear { scale: 1.0 })),
        &Primitives::bind(&atoms.volatility_branch, &scalar.encode(ratios.volatility, ScalarMode::Linear { scale: 1.0 })),
        &Primitives::bind(&atoms.correlation_branch, &scalar.encode(ratios.correlation, ScalarMode::Linear { scale: 1.0 })),
        &Primitives::bind(&atoms.panel_branch, &scalar.encode(ratios.panel, ScalarMode::Linear { scale: 1.0 })),
        &Primitives::bind(&atoms.generalist_branch, &scalar.encode(ratios.generalist, ScalarMode::Linear { scale: 1.0 })),
    ])
}

/// The risk manager's state. Lives on the enterprise (not per-desk).
pub struct RiskManager {
    pub journal: Journal,
    pub healthy: Label,
    pub unhealthy: Label,
    pub curve_valid: bool,
}

impl RiskManager {
    pub fn new(dims: usize, recalib_interval: usize) -> Self {
        let mut journal = Journal::new("risk-manager", dims, recalib_interval);
        let healthy = journal.register("Healthy");
        let unhealthy = journal.register("Unhealthy");
        Self {
            journal,
            healthy,
            unhealthy,
            curve_valid: false,
        }
    }

    /// Predict portfolio health from current branch ratios.
    pub fn predict(&self, thought: &Vector) -> crate::journal::Prediction {
        self.journal.predict(thought)
    }

    /// Learn from outcome: was the portfolio healthy or unhealthy
    /// after this configuration of branch ratios?
    pub fn observe(&mut self, thought: &Vector, was_healthy: bool, weight: f64) {
        let label = if was_healthy { self.healthy } else { self.unhealthy };
        self.journal.observe(thought, label, weight);
    }

    /// Decay the journal accumulators.
    pub fn decay(&mut self, rate: f64) {
        self.journal.decay(rate);
    }

    /// Convert the prediction into a risk multiplier [0.1, 1.0].
    /// Pure: takes its dependencies as arguments, doesn't reach into self beyond labels.
    pub fn risk_mult_from_prediction(&self, pred: &crate::journal::Prediction) -> f64 {
        risk_mult(pred, self.curve_valid, self.healthy, self.unhealthy)
    }
}

/// Pure risk multiplier computation. No self needed.
/// High conviction toward Healthy → 1.0 (full sizing).
/// High conviction toward Unhealthy → scaled down.
/// Low conviction → 0.5 (cautious default).
pub fn risk_mult(
    pred: &crate::journal::Prediction,
    curve_valid: bool,
    healthy: Label,
    unhealthy: Label,
) -> f64 {
    if !curve_valid {
        return 0.5;
    }
    match pred.direction {
        Some(dir) if dir == healthy => {
            (0.5 + pred.conviction * 0.5).min(1.0)
        }
        Some(dir) if dir == unhealthy => {
            (0.5 - pred.conviction * 0.4).max(0.1)
        }
        _ => 0.5,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::journal::{Label, Prediction};
    use holon::{ScalarEncoder, VectorManager};

    fn test_vm() -> VectorManager {
        VectorManager::new(64)
    }

    fn test_labels() -> (Label, Label) {
        let mut journal = holon::memory::Journal::new("test", 64, 50);
        let healthy = journal.register("Healthy");
        let unhealthy = journal.register("Unhealthy");
        (healthy, unhealthy)
    }

    fn make_prediction(direction: Option<Label>, conviction: f64) -> Prediction {
        Prediction {
            scores: vec![],
            direction,
            conviction,
            raw_cos: conviction,
        }
    }

    // ── RiskManagerAtoms ────────────────────────────────────────────

    #[test]
    fn atoms_new_does_not_panic() {
        let vm = test_vm();
        let _atoms = RiskManagerAtoms::new(&vm);
    }

    // ── encode_risk_manager_thought ─────────────────────────────────

    #[test]
    fn encode_risk_manager_thought_returns_nonzero_vector() {
        let vm = test_vm();
        let atoms = RiskManagerAtoms::new(&vm);
        let scalar = ScalarEncoder::new(64);
        let ratios = super::super::BranchRatios {
            drawdown: 0.8,
            accuracy: 0.9,
            volatility: 0.7,
            correlation: 1.0,
            panel: 0.6,
            generalist: 0.95,
        };
        let v = encode_risk_manager_thought(&ratios, &atoms, &scalar);
        let nonzero = v.data().iter().any(|&x| x != 0);
        assert!(nonzero, "encoded vector should have non-zero components");
    }

    // ── RiskManager::new ────────────────────────────────────────────

    #[test]
    fn risk_manager_new_creates_with_labels() {
        let rm = RiskManager::new(64, 50);
        // Labels are distinct handles
        assert_ne!(rm.healthy, rm.unhealthy);
        assert!(!rm.curve_valid);
    }

    // ── risk_mult: curve_valid=false ────────────────────────────────

    #[test]
    fn risk_mult_curve_invalid_returns_half() {
        let (healthy, unhealthy) = test_labels();
        let pred = make_prediction(Some(healthy), 0.9);
        let result = risk_mult(&pred, false, healthy, unhealthy);
        assert!((result - 0.5).abs() < 1e-10, "curve_valid=false should return 0.5, got {result}");
    }

    // ── risk_mult: healthy direction, high conviction ───────────────

    #[test]
    fn risk_mult_healthy_high_conviction_near_one() {
        let (healthy, unhealthy) = test_labels();
        let pred = make_prediction(Some(healthy), 0.95);
        let result = risk_mult(&pred, true, healthy, unhealthy);
        assert!(result > 0.9, "healthy + high conviction should be near 1.0, got {result}");
        assert!(result <= 1.0, "should not exceed 1.0, got {result}");
    }

    // ── risk_mult: unhealthy direction, high conviction ─────────────

    #[test]
    fn risk_mult_unhealthy_high_conviction_near_floor() {
        let (healthy, unhealthy) = test_labels();
        let pred = make_prediction(Some(unhealthy), 0.95);
        let result = risk_mult(&pred, true, healthy, unhealthy);
        assert!(result < 0.2, "unhealthy + high conviction should be near 0.1, got {result}");
        assert!(result >= 0.1, "should not go below 0.1, got {result}");
    }

    // ── risk_mult: no direction ─────────────────────────────────────

    #[test]
    fn risk_mult_no_direction_returns_half() {
        let (healthy, unhealthy) = test_labels();
        let pred = make_prediction(None, 0.0);
        let result = risk_mult(&pred, true, healthy, unhealthy);
        assert!((result - 0.5).abs() < 1e-10, "no direction should return 0.5, got {result}");
    }

    // ── RiskManager::observe ────────────────────────────────────────

    #[test]
    fn risk_manager_observe_does_not_panic() {
        let mut rm = RiskManager::new(64, 50);
        let vm = test_vm();
        let atoms = RiskManagerAtoms::new(&vm);
        let scalar = ScalarEncoder::new(64);
        let ratios = super::super::BranchRatios {
            drawdown: 0.8,
            accuracy: 0.9,
            volatility: 0.7,
            correlation: 1.0,
            panel: 0.6,
            generalist: 0.95,
        };
        let thought = encode_risk_manager_thought(&ratios, &atoms, &scalar);
        rm.observe(&thought, true, 1.0);
        rm.observe(&thought, false, 1.0);
    }

    // ── RiskManager::predict ────────────────────────────────────────

    #[test]
    fn risk_manager_predict_returns_prediction() {
        let rm = RiskManager::new(64, 50);
        let vm = test_vm();
        let atoms = RiskManagerAtoms::new(&vm);
        let scalar = ScalarEncoder::new(64);
        let ratios = super::super::BranchRatios {
            drawdown: 0.8,
            accuracy: 0.9,
            volatility: 0.7,
            correlation: 1.0,
            panel: 0.6,
            generalist: 0.95,
        };
        let thought = encode_risk_manager_thought(&ratios, &atoms, &scalar);
        let pred = rm.predict(&thought);
        // Fresh journal with no observations — conviction should be zero or near-zero
        assert!(pred.conviction >= 0.0, "conviction should be non-negative");
    }
}
