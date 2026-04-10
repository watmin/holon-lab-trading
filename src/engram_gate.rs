/// Engram gating for reckoner quality.
/// After recalibration with good accuracy, snapshot the discriminant.
/// An OnlineSubspace learns what good discriminants look like.

use crate::enums::Outcome;
use holon::memory::{OnlineSubspace, Reckoner};

/// Tracks the gating state between recalibrations.
#[derive(Clone, Debug)]
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

/// Check if the reckoner has recalibrated since the last check.
/// If so, evaluate accuracy and update the engram gate.
/// Returns true if a snapshot was taken.
pub fn check_engram_gate(
    reckoner: &Reckoner,
    good_state_subspace: &mut OnlineSubspace,
    gate_state: &mut EngramGateState,
    outcome: &Outcome,
) -> bool {
    let current_recalib = reckoner.recalib_count();

    // Track wins/total for accuracy measurement
    if *outcome == Outcome::Grace {
        gate_state.recalib_wins += 1;
    }
    gate_state.recalib_total += 1;

    if current_recalib > gate_state.last_recalib_count {
        // Recalibration happened — evaluate and maybe snapshot
        let accuracy = if gate_state.recalib_total > 0 {
            gate_state.recalib_wins as f64 / gate_state.recalib_total as f64
        } else {
            0.0
        };

        let took_snapshot = if accuracy > 0.5 {
            // Good accuracy — snapshot the discriminant into the subspace
            let labels = reckoner.labels();
            if let Some(first_label) = labels.first() {
                if let Some(disc) = reckoner.discriminant(*first_label) {
                    good_state_subspace.update(disc);
                    true
                } else {
                    false
                }
            } else {
                false
            }
        } else {
            false
        };

        // Reset counters
        gate_state.recalib_wins = 0;
        gate_state.recalib_total = 0;
        gate_state.last_recalib_count = current_recalib;

        took_snapshot
    } else {
        // No recalibration — just update counters
        false
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use holon::memory::ReckConfig;

    #[test]
    fn test_engram_gate_state_new() {
        let gs = EngramGateState::new();
        assert_eq!(gs.recalib_wins, 0);
        assert_eq!(gs.recalib_total, 0);
        assert_eq!(gs.last_recalib_count, 0);
    }

    #[test]
    fn test_gate_at_threshold() {
        let dims = 4096;
        let reck = Reckoner::new(
            "test",
            dims,
            10, // recalib every 10
            ReckConfig::Discrete(vec!["Up".into(), "Down".into()]),
        );
        let mut subspace = OnlineSubspace::new(dims, 3);
        let mut gate_state = EngramGateState::new();

        // Feed outcomes without recalibration — should not snapshot
        for _ in 0..5 {
            let snapped = check_engram_gate(&reck, &mut subspace, &mut gate_state, &Outcome::Grace);
            assert!(!snapped, "No recalibration happened yet, should not snapshot");
        }
        assert_eq!(gate_state.recalib_total, 5);
        assert_eq!(gate_state.recalib_wins, 5);
    }

    #[test]
    fn test_gate_tracks_accuracy() {
        let dims = 4096;
        let reck = Reckoner::new(
            "test",
            dims,
            10,
            ReckConfig::Discrete(vec!["Up".into(), "Down".into()]),
        );
        let mut subspace = OnlineSubspace::new(dims, 3);
        let mut gate_state = EngramGateState::new();

        // 3 grace + 2 violence = 60% accuracy
        check_engram_gate(&reck, &mut subspace, &mut gate_state, &Outcome::Grace);
        check_engram_gate(&reck, &mut subspace, &mut gate_state, &Outcome::Grace);
        check_engram_gate(&reck, &mut subspace, &mut gate_state, &Outcome::Grace);
        check_engram_gate(&reck, &mut subspace, &mut gate_state, &Outcome::Violence);
        check_engram_gate(&reck, &mut subspace, &mut gate_state, &Outcome::Violence);

        assert_eq!(gate_state.recalib_wins, 3);
        assert_eq!(gate_state.recalib_total, 5);
        // Accuracy would be 0.6 > 0.55 threshold — but no recalib so no snapshot
    }
}
