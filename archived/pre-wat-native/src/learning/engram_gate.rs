/// Shared utility for gating reckoner quality. Compiled from wat/engram-gate.wat.
///
/// After recalibration with good accuracy, snapshot the discriminant
/// into a good-state subspace. Used by both MarketObserver and Broker.

use holon::memory::OnlineSubspace;
use holon::memory::Reckoner;

/// Tracks wins and total predictions since last recalibration.
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

    /// Record a resolved prediction outcome.
    pub fn record(&mut self, win: bool) {
        self.recalib_total += 1;
        if win {
            self.recalib_wins += 1;
        }
    }
}

/// Check if the reckoner has crossed a recalibration boundary.
/// If accuracy exceeds the threshold, snapshot discriminants into the subspace.
/// Returns the updated gate state.
pub fn check_engram_gate(
    reckoner: &Reckoner,
    good_state_subspace: &mut OnlineSubspace,
    gate_state: &EngramGateState,
    _recalib_interval: usize,
    accuracy_threshold: f64,
) -> EngramGateState {
    let current_recalib = reckoner.recalib_count();

    if current_recalib > gate_state.last_recalib_count {
        // Recalibration boundary crossed -- evaluate and possibly snapshot
        let accuracy = if gate_state.recalib_total > 0 {
            gate_state.recalib_wins as f64 / gate_state.recalib_total as f64
        } else {
            0.0
        };

        if accuracy >= accuracy_threshold {
            // Good accuracy -- snapshot discriminants into subspace
            for label in reckoner.labels() {
                if let Some(disc) = reckoner.discriminant(label) {
                    good_state_subspace.update(disc);
                }
            }
        }

        // Reset counters for next recalibration period
        EngramGateState {
            recalib_wins: 0,
            recalib_total: 0,
            last_recalib_count: current_recalib,
        }
    } else {
        // Same recalibration period -- return current state
        gate_state.clone()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use holon::memory::{Label, ReckConfig};

    const DIMS: usize = 4096;
    const RECALIB: usize = 10;

    fn make_reckoner() -> Reckoner {
        Reckoner::new(
            "test",
            DIMS,
            RECALIB,
            ReckConfig::Discrete(vec!["Up".into(), "Down".into()]),
        )
    }

    fn make_subspace() -> OnlineSubspace {
        OnlineSubspace::new(DIMS, 3)
    }

    use std::sync::atomic::{AtomicU64, Ordering};
    static COUNTER: AtomicU64 = AtomicU64::new(0);

    fn random_vector() -> holon::Vector {
        use holon::VectorManager;
        let vm = VectorManager::new(DIMS);
        let id = COUNTER.fetch_add(1, Ordering::Relaxed);
        vm.get_vector(&format!("test_vec_{}", id))
    }

    #[test]
    fn test_initial_state() {
        let state = EngramGateState::new();
        assert_eq!(state.recalib_wins, 0);
        assert_eq!(state.recalib_total, 0);
        assert_eq!(state.last_recalib_count, 0);
    }

    #[test]
    fn test_record_updates_counters() {
        let mut state = EngramGateState::new();
        state.record(true);
        state.record(false);
        state.record(true);
        assert_eq!(state.recalib_wins, 2);
        assert_eq!(state.recalib_total, 3);
    }

    #[test]
    fn test_no_recalib_returns_same_state() {
        let reck = make_reckoner();
        let mut sub = make_subspace();
        let state = EngramGateState::new();

        // No observations yet, recalib_count is 0 = last_recalib_count
        let new_state = check_engram_gate(&reck, &mut sub, &state, RECALIB, 0.5);
        assert_eq!(new_state.last_recalib_count, 0);
    }

    fn train_reckoner(reck: &mut Reckoner, n: usize) {
        let up = Label::from_index(0);
        let down = Label::from_index(1);
        // Feed alternating labels so discriminants form
        for i in 0..n {
            let v = random_vector();
            if i % 2 == 0 {
                reck.observe(&v, up, 1.0);
            } else {
                reck.observe(&v, down, 1.0);
            }
        }
    }

    #[test]
    fn test_gate_resets_after_recalib_boundary() {
        let mut reck = make_reckoner();
        let mut sub = make_subspace();

        // Feed enough observations to trigger at least one recalibration
        train_reckoner(&mut reck, RECALIB * 2);

        // Recalib count should have advanced
        assert!(
            reck.recalib_count() > 0,
            "recalib_count should be > 0 after {} observations, got {}",
            RECALIB * 2,
            reck.recalib_count()
        );

        // Set up a gate state with some wins
        let mut state = EngramGateState::new();
        state.record(true);
        state.record(true);
        state.record(false);
        // 2/3 = 0.667 accuracy

        let new_state = check_engram_gate(&reck, &mut sub, &state, RECALIB, 0.5);

        // Should have reset counters
        assert_eq!(new_state.recalib_wins, 0);
        assert_eq!(new_state.recalib_total, 0);
        assert_eq!(new_state.last_recalib_count, reck.recalib_count());
    }

    #[test]
    fn test_gate_does_not_snapshot_below_threshold() {
        let mut reck = make_reckoner();
        let mut sub = make_subspace();

        train_reckoner(&mut reck, RECALIB * 2);

        // Poor accuracy: 1/10 = 0.1
        let mut state = EngramGateState::new();
        state.record(true);
        for _ in 0..9 {
            state.record(false);
        }

        // The gate should still reset counters but NOT snapshot
        let new_state = check_engram_gate(&reck, &mut sub, &state, RECALIB, 0.5);
        assert_eq!(new_state.recalib_wins, 0);
        assert_eq!(new_state.recalib_total, 0);
    }
}
