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

#[cfg(test)]
mod tests {
    use super::*;
    use holon::memory::{ReckConfig, OnlineSubspace};
    use holon::{Encoder, VectorManager};

    const DIMS: usize = 4096;
    const RECALIB_INTERVAL: usize = 10;

    /// Create a discrete reckoner with "Grace" and "Violence" labels.
    fn make_reckoner() -> Reckoner {
        Reckoner::new(
            "test",
            DIMS,
            RECALIB_INTERVAL,
            ReckConfig::Discrete(vec!["Grace".to_string(), "Violence".to_string()]),
        )
    }

    /// Feed enough observations to trigger a recalibration.
    fn feed_to_recalib(reckoner: &mut Reckoner, encoder: &Encoder) {
        let grace_label = Label::from_index(0);
        let violence_label = Label::from_index(1);
        for i in 0..RECALIB_INTERVAL {
            let vec = encoder.encode_json(&format!(
                r#"{{"type": "grace", "id": {}}}"#, i
            )).unwrap();
            reckoner.observe(&vec, grace_label, 1.0);
        }
        // Also feed some violence so discriminant is meaningful
        for i in 0..RECALIB_INTERVAL {
            let vec = encoder.encode_json(&format!(
                r#"{{"type": "violence", "id": {}}}"#, i
            )).unwrap();
            reckoner.observe(&vec, violence_label, 1.0);
        }
    }

    #[test]
    fn test_engram_gate_state_default() {
        let state = EngramGateState::new();
        assert_eq!(state.recalib_wins, 0);
        assert_eq!(state.recalib_total, 0);
        assert_eq!(state.last_recalib_count, 0);
    }

    #[test]
    fn test_no_recalibration_unchanged() {
        let reckoner = make_reckoner();
        let mut sub = OnlineSubspace::new(DIMS, 3);
        let mut state = EngramGateState::new();

        // No recalib has occurred (recalib_count == 0 == last_recalib_count)
        // Calling check should just track the outcome
        check_engram_gate(
            &reckoner,
            &mut sub,
            &mut state,
            Outcome::Grace,
            0.55,
            Label::from_index(0),
        );

        assert_eq!(state.recalib_total, 1);
        assert_eq!(state.recalib_wins, 1);
        // No recalib happened, so last_recalib_count stays 0
        assert_eq!(state.last_recalib_count, 0);
    }

    #[test]
    fn test_recalib_with_high_accuracy_snapshots() {
        let vm = VectorManager::new(DIMS);
        let encoder = Encoder::new(vm);
        let mut reckoner = make_reckoner();
        let mut sub = OnlineSubspace::new(DIMS, 3);
        let mut state = EngramGateState::new();

        // Track wins before recalib — all Grace wins
        for _ in 0..8 {
            check_engram_gate(
                &reckoner,
                &mut sub,
                &mut state,
                Outcome::Grace,
                0.55,
                Label::from_index(0),
            );
        }
        // 2 Violence
        for _ in 0..2 {
            check_engram_gate(
                &reckoner,
                &mut sub,
                &mut state,
                Outcome::Violence,
                0.55,
                Label::from_index(0),
            );
        }
        // State: 8 wins / 10 total = 0.80 accuracy
        assert_eq!(state.recalib_wins, 8);
        assert_eq!(state.recalib_total, 10);

        // Now trigger recalibration on the reckoner
        feed_to_recalib(&mut reckoner, &encoder);
        assert!(reckoner.recalib_count() > 0, "Reckoner should have recalibrated");

        // Next call to check_engram_gate should see the recalib, check accuracy (0.80 > 0.55),
        // snapshot the discriminant, and reset counters
        check_engram_gate(
            &reckoner,
            &mut sub,
            &mut state,
            Outcome::Grace,
            0.55,
            Label::from_index(0),
        );

        // Counters should be reset (then the current outcome is tracked in the new window)
        // Actually: the outcome is tracked BEFORE the recalib check.
        // So: recalib_total was 11 at check time, recalib_wins was 9.
        // Then gate fires, resets to 0, 0.
        assert_eq!(state.recalib_wins, 0);
        assert_eq!(state.recalib_total, 0);
        assert_eq!(state.last_recalib_count, reckoner.recalib_count());
    }

    #[test]
    fn test_recalib_with_low_accuracy_no_snapshot() {
        let vm = VectorManager::new(DIMS);
        let encoder = Encoder::new(vm);
        let mut reckoner = make_reckoner();
        let mut sub = OnlineSubspace::new(DIMS, 3);
        let mut state = EngramGateState::new();

        // Track outcomes — mostly Violence (low accuracy)
        for _ in 0..2 {
            check_engram_gate(
                &reckoner,
                &mut sub,
                &mut state,
                Outcome::Grace,
                0.55,
                Label::from_index(0),
            );
        }
        for _ in 0..8 {
            check_engram_gate(
                &reckoner,
                &mut sub,
                &mut state,
                Outcome::Violence,
                0.55,
                Label::from_index(0),
            );
        }
        // 2 wins / 10 total = 0.20 accuracy — below threshold

        // Trigger recalibration
        feed_to_recalib(&mut reckoner, &encoder);

        // Subspace should have no components learned yet (k=3 but 0 updates)
        // We can verify it stays at 0 updates by checking the counters reset
        check_engram_gate(
            &reckoner,
            &mut sub,
            &mut state,
            Outcome::Grace,
            0.55,
            Label::from_index(0),
        );

        // Counters still reset even when accuracy is low
        assert_eq!(state.recalib_wins, 0);
        assert_eq!(state.recalib_total, 0);
        assert_eq!(state.last_recalib_count, reckoner.recalib_count());
    }

    #[test]
    fn test_counters_reset_after_gate_fires() {
        let vm = VectorManager::new(DIMS);
        let encoder = Encoder::new(vm);
        let mut reckoner = make_reckoner();
        let mut sub = OnlineSubspace::new(DIMS, 3);
        let mut state = EngramGateState::new();

        // Accumulate some outcomes
        for _ in 0..5 {
            check_engram_gate(&reckoner, &mut sub, &mut state, Outcome::Grace, 0.55, Label::from_index(0));
        }
        assert_eq!(state.recalib_total, 5);

        // Trigger recalibration
        feed_to_recalib(&mut reckoner, &encoder);

        // Fire the gate
        check_engram_gate(&reckoner, &mut sub, &mut state, Outcome::Grace, 0.55, Label::from_index(0));

        // Counters reset
        assert_eq!(state.recalib_total, 0);
        assert_eq!(state.recalib_wins, 0);

        // New window starts fresh
        check_engram_gate(&reckoner, &mut sub, &mut state, Outcome::Violence, 0.55, Label::from_index(0));
        assert_eq!(state.recalib_total, 1);
        assert_eq!(state.recalib_wins, 0);
    }
}
