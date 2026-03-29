//! Risk branch — specialized subspace for one domain of portfolio health.
//!
//! Each branch measures health in its own domain. The worst residual drives
//! the risk multiplier. Gated updates: only learn from healthy states.
//! Template 2 (REACTION) applied N times.
//!
//! Seeds the future risk/ module (risk manager, risk generalist).

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
