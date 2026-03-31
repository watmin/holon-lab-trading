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
