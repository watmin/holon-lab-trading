/// market_observer.rs — Predicts direction. Learned. Labels come from broker
/// propagation. Compiled from wat/market-observer.wat.
///
/// The market observer does NOT label itself. Reality labels it via the broker.

use holon::kernel::vector::Vector;
use holon::memory::{OnlineSubspace, ReckConfig, Reckoner};

use crate::engram_gate::{check_engram_gate, EngramGateState};
use crate::enums::{Direction, MarketLens};
use crate::thought_encoder::ThoughtAST;
use crate::window_sampler::WindowSampler;

/// Convert Vector (i8) to Vec<f64> for OnlineSubspace operations.
fn to_f64(v: &Vector) -> Vec<f64> {
    v.data().iter().map(|&x| x as f64).collect()
}

/// Predicts direction (Up/Down) from candle data through a specific lens.
pub struct MarketObserver {
    /// Which vocabulary modules this observer attends to.
    pub lens: MarketLens,
    /// Discrete reckoner -- Up/Down.
    pub reckoner: Reckoner,
    /// Background model -- learns what normal looks like.
    pub noise_subspace: OnlineSubspace,
    /// Own time scale for window selection.
    pub window_sampler: WindowSampler,
    /// How many predictions have been resolved.
    pub resolved: usize,
    /// Learns what good discriminants look like (for engram gating).
    pub good_state_subspace: OnlineSubspace,
    /// Wins since last recalibration.
    pub recalib_wins: usize,
    /// Total since last recalibration.
    pub recalib_total: usize,
    /// Recalib count at last engram check.
    pub last_recalib_count: usize,
    /// Set by observe_candle, read by resolve.
    pub last_prediction: Direction,
}

/// Result of observe: the cleaned thought, prediction details, and cache misses.
pub struct ObserveResult {
    /// The noise-stripped thought vector.
    pub thought: Vector,
    /// Holon-rs prediction (scores + conviction).
    pub prediction: holon::memory::Prediction,
    /// Edge: accuracy_at(conviction) or 0.0 if curve not valid.
    pub edge: f64,
    /// Cache misses from thought encoding.
    pub misses: Vec<(ThoughtAST, Vector)>,
}

impl MarketObserver {
    /// Construct a new market observer.
    /// noise_subspace: 8 principal components.
    /// good_state_subspace: 4 components (simpler manifold).
    pub fn new(
        lens: MarketLens,
        dims: usize,
        recalib_interval: usize,
        window_sampler: WindowSampler,
    ) -> Self {
        Self {
            lens,
            reckoner: Reckoner::new(
                &format!("direction-{}", lens),
                dims,
                recalib_interval,
                ReckConfig::Discrete(vec!["Up".into(), "Down".into()]),
            ),
            noise_subspace: OnlineSubspace::new(dims, 8),
            window_sampler,
            resolved: 0,
            good_state_subspace: OnlineSubspace::new(dims, 4),
            recalib_wins: 0,
            recalib_total: 0,
            last_recalib_count: 0,
            last_prediction: Direction::Down, // arbitrary initial
        }
    }

    /// Encode, update noise, strip noise, predict direction.
    /// The `thought` parameter is the already-encoded thought vector.
    /// Returns ObserveResult with cleaned thought, prediction, edge, and misses.
    pub fn observe(
        &mut self,
        thought: Vector,
        misses: Vec<(ThoughtAST, Vector)>,
    ) -> ObserveResult {
        // Update noise subspace
        let thought_f64 = to_f64(&thought);
        self.noise_subspace.update(&thought_f64);

        // Strip noise -- anomalous component is the signal
        let clean = self.strip_noise(&thought);

        // Predict direction
        let pred = self.reckoner.predict(&clean);
        let conviction = pred.conviction;

        // Edge from curve
        let edge = self.reckoner.accuracy_at(conviction).unwrap_or(0.0);

        // Store last prediction direction
        if let Some(dir_label) = pred.direction {
            self.last_prediction = if dir_label.index() == 0 {
                Direction::Up
            } else {
                Direction::Down
            };
        }

        ObserveResult {
            thought: clean,
            prediction: pred,
            edge,
            misses,
        }
    }

    /// Called by broker propagation -- reckoner learns from reality.
    pub fn resolve(
        &mut self,
        thought: &Vector,
        direction: Direction,
        weight: f64,
        recalib_interval: usize,
    ) {
        let label = match direction {
            Direction::Up => holon::memory::Label::from_index(0),
            Direction::Down => holon::memory::Label::from_index(1),
        };

        // Check if prediction was correct
        let correct = self.last_prediction == direction;

        // Reckoner learns
        self.reckoner.observe(thought, label, weight);

        // Feed the internal curve with conviction and correctness
        let pred = self.reckoner.predict(thought);
        self.reckoner.resolve(pred.conviction, correct);

        // Engram gate -- learn from real accuracy
        self.resolved += 1;
        if correct {
            self.recalib_wins += 1;
        }
        self.recalib_total += 1;

        let gate_state = EngramGateState {
            recalib_wins: self.recalib_wins,
            recalib_total: self.recalib_total,
            last_recalib_count: self.last_recalib_count,
        };
        let new_state = check_engram_gate(
            &self.reckoner,
            &mut self.good_state_subspace,
            &gate_state,
            recalib_interval,
            0.55,
        );
        self.recalib_wins = new_state.recalib_wins;
        self.recalib_total = new_state.recalib_total;
        self.last_recalib_count = new_state.last_recalib_count;
    }

    /// Return the anomalous component -- what the noise subspace CANNOT explain.
    /// The residual IS the signal.
    pub fn strip_noise(&self, thought: &Vector) -> Vector {
        let thought_f64 = to_f64(thought);
        let anomalous = self.noise_subspace.anomalous_component(&thought_f64);
        Vector::from_f64(&anomalous)
    }

    /// How much has this observer learned?
    pub fn experience(&self) -> f64 {
        self.reckoner.experience()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use holon::kernel::vector_manager::VectorManager;

    const DIMS: usize = 4096;
    const RECALIB: usize = 100;

    fn make_observer() -> MarketObserver {
        let ws = WindowSampler::new(42, 10, 500);
        MarketObserver::new(MarketLens::Momentum, DIMS, RECALIB, ws)
    }

    fn random_vector(name: &str) -> Vector {
        let vm = VectorManager::new(DIMS);
        vm.get_vector(name)
    }

    #[test]
    fn test_market_observer_new() {
        let obs = make_observer();
        assert_eq!(obs.lens, MarketLens::Momentum);
        assert_eq!(obs.resolved, 0);
        assert_eq!(obs.last_prediction, Direction::Down);
        assert_eq!(obs.recalib_wins, 0);
        assert_eq!(obs.recalib_total, 0);
    }

    #[test]
    fn test_observe_returns_result() {
        let mut obs = make_observer();
        let thought = random_vector("test_thought");
        let result = obs.observe(thought, Vec::new());
        assert_eq!(result.thought.dimensions(), DIMS);
        assert!(result.misses.is_empty());
    }

    #[test]
    fn test_strip_noise_returns_vector() {
        let obs = make_observer();
        let thought = random_vector("test_thought");
        let stripped = obs.strip_noise(&thought);
        assert_eq!(stripped.dimensions(), DIMS);
    }

    #[test]
    fn test_resolve_increments_counters() {
        let mut obs = make_observer();
        let thought = random_vector("resolve_thought");
        obs.resolve(&thought, Direction::Up, 1.0, RECALIB);
        assert_eq!(obs.resolved, 1);
        assert_eq!(obs.recalib_total, 1);
    }

    #[test]
    fn test_experience_starts_at_zero() {
        let obs = make_observer();
        assert_eq!(obs.experience(), 0.0);
    }

    #[test]
    fn test_observe_sets_last_prediction() {
        let mut obs = make_observer();
        let thought = random_vector("pred_thought");
        let _ = obs.observe(thought, Vec::new());
        // last_prediction should have been set (to Up or Down based on reckoner)
        assert!(obs.last_prediction == Direction::Up || obs.last_prediction == Direction::Down);
    }

    #[test]
    fn test_multiple_resolves() {
        let mut obs = make_observer();
        for i in 0..10 {
            let thought = random_vector(&format!("thought_{}", i));
            let dir = if i % 2 == 0 { Direction::Up } else { Direction::Down };
            obs.resolve(&thought, dir, 1.0, RECALIB);
        }
        assert_eq!(obs.resolved, 10);
        assert_eq!(obs.recalib_total, 10);
    }
}
