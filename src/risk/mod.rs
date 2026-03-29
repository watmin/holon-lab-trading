//! Risk domain — portfolio health measurement and gating.
//!
//! Each branch measures health in its own domain. The worst residual drives
//! the risk multiplier. Gated updates: only learn from healthy states.
//!
//! Future: risk/manager.rs (risk manager encoding from branch signals).

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
