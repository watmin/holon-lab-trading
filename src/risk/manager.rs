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
}

impl RiskManagerAtoms {
    pub fn new(vm: &VectorManager) -> Self {
        Self {
            drawdown_branch: vm.get_vector("risk-drawdown-branch"),
            accuracy_branch: vm.get_vector("risk-accuracy-branch"),
            volatility_branch: vm.get_vector("risk-volatility-branch"),
            correlation_branch: vm.get_vector("risk-correlation-branch"),
            panel_branch: vm.get_vector("risk-panel-branch"),
        }
    }
}

/// Encode 5 branch residual ratios as one risk manager thought.
/// Each ratio is [0.1, 1.0] — 1.0 = healthy, 0.1 = worst allowed.
pub fn encode_risk_manager_thought(
    ratios: &[f64; 5],
    atoms: &RiskManagerAtoms,
    scalar: &ScalarEncoder,
) -> Vector {
    Primitives::bundle(&[
        &Primitives::bind(&atoms.drawdown_branch, &scalar.encode(ratios[0], ScalarMode::Linear { scale: 1.0 })),
        &Primitives::bind(&atoms.accuracy_branch, &scalar.encode(ratios[1], ScalarMode::Linear { scale: 1.0 })),
        &Primitives::bind(&atoms.volatility_branch, &scalar.encode(ratios[2], ScalarMode::Linear { scale: 1.0 })),
        &Primitives::bind(&atoms.correlation_branch, &scalar.encode(ratios[3], ScalarMode::Linear { scale: 1.0 })),
        &Primitives::bind(&atoms.panel_branch, &scalar.encode(ratios[4], ScalarMode::Linear { scale: 1.0 })),
    ])
}

/// The risk manager's state. Lives on the enterprise (not per-desk).
pub struct RiskManager {
    pub journal: Journal,
    pub healthy: Label,
    pub unhealthy: Label,
    pub curve_valid: bool,
    pub cached_conviction: f64,
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
            cached_conviction: 0.0,
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
    /// High conviction toward Healthy → 1.0 (full sizing).
    /// High conviction toward Unhealthy → scaled down.
    /// Low conviction → 0.5 (cautious default).
    pub fn risk_mult_from_prediction(&self, pred: &crate::journal::Prediction) -> f64 {
        if !self.curve_valid {
            return 0.5; // no curve yet — cautious
        }
        match pred.direction {
            Some(dir) if dir == self.healthy => {
                // Confident it's healthy — scale toward 1.0 with conviction
                (0.5 + pred.conviction * 0.5).min(1.0)
            }
            Some(dir) if dir == self.unhealthy => {
                // Confident it's unhealthy — scale toward 0.1
                (0.5 - pred.conviction * 0.4).max(0.1)
            }
            _ => 0.5,
        }
    }
}
