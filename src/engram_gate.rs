//! engram-gate.wat -- engram gating logic shared by market observers and brokers
//! Depends on: primitives only (OnlineSubspace, Reckoner)

use holon::memory::{Label, OnlineSubspace, Reckoner};

use crate::enums::Outcome;

/// Mutable tracking state for the engram gate.
/// Lives on the caller (market observer or broker).
pub struct EngramGateState {
    pub recalib_wins: usize,
    pub recalib_total: usize,
    pub last_recalib_count: usize,
}

impl EngramGateState {
    pub fn new() -> Self {
        Self {
            recalib_wins: 0,
            recalib_total: 0,
            last_recalib_count: 0,
        }
    }
}

impl Default for EngramGateState {
    fn default() -> Self {
        Self::new()
    }
}

/// Called after observing an outcome.
/// Tracks per-recalibration accuracy. When a recalibration completes
/// and accuracy exceeds the threshold, the current discriminant is
/// fed to the good-state subspace as a positive example.
pub fn check_engram_gate(
    reckoner: &Reckoner,
    good_state_sub: &mut OnlineSubspace,
    state: &mut EngramGateState,
    outcome: Outcome,
    accuracy_threshold: f64,
    label: Label,
) {
    let current_recalib = reckoner.recalib_count();

    // Track this outcome
    state.recalib_total += 1;
    if outcome == Outcome::Grace {
        state.recalib_wins += 1;
    }

    // Check if a new recalibration has occurred
    if current_recalib > state.last_recalib_count {
        let accuracy = if state.recalib_total > 0 {
            state.recalib_wins as f64 / state.recalib_total as f64
        } else {
            0.0
        };

        // If accuracy exceeds threshold, feed the discriminant to the subspace
        if accuracy > accuracy_threshold {
            if let Some(disc) = reckoner.discriminant(label) {
                good_state_sub.update(disc);
            }
        }

        // Reset tracking for the new recalibration window
        state.recalib_wins = 0;
        state.recalib_total = 0;
        state.last_recalib_count = current_recalib;
    }
}
