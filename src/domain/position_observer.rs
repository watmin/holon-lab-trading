/// position_observer.rs — Estimates position distances. Learned. Two continuous reckoners
/// (trail, stop). Compiled from wat/position-observer.wat.
///
/// Intentionally simpler than MarketObserver. No noise-subspace, no curve,
/// no engram gating. Quality is measured through the BROKER's curve.

use holon::kernel::vector::Vector;
use holon::memory::{OnlineSubspace, ReckConfig, Reckoner};

use crate::types::distances::Distances;
use crate::types::enums::PositionLens;
#[cfg(test)]
use crate::learning::scalar_accumulator::ScalarAccumulator;
use crate::encoding::thought_encoder::IncrementalBundle;

/// Rolling window capacity for self-assessment.
const SELF_ASSESSMENT_WINDOW: usize = 100;

/// Estimates exit distances through a specific judgment lens.
pub struct PositionObserver {
    /// Which judgment vocabulary.
    pub lens: PositionLens,
    /// Continuous reckoner -- trailing stop distance.
    pub trail_reckoner: Reckoner,
    /// Continuous reckoner -- safety stop distance.
    pub stop_reckoner: Reckoner,
    /// The crutches (both), returned when empty.
    pub default_distances: Distances,
    /// Noise subspace — learns the background distribution for this exit lens.
    /// 8 principal components. The anomaly is what the subspace cannot explain.
    pub noise_subspace: OnlineSubspace,
    /// Incremental bundling for exit facts — optimization cache, not cognition.
    pub incremental: IncrementalBundle,
    /// Rolling window of outcomes: true=Grace, false=Violence.
    pub outcome_window: Vec<bool>,
    /// Rolling window of residue per resolution.
    pub residue_window: Vec<f64>,
    /// Fraction of Grace in the rolling window.
    pub grace_rate: f64,
    /// Average residue in the rolling window.
    pub avg_residue: f64,
}

impl PositionObserver {
    /// Construct a new position observer with two continuous reckoners.
    pub fn new(
        lens: PositionLens,
        dims: usize,
        recalib_interval: usize,
        default_trail: f64,
        default_stop: f64,
    ) -> Self {
        Self {
            lens,
            trail_reckoner: Reckoner::new(
                &format!("trail-{}", lens),
                dims,
                recalib_interval,
                ReckConfig::Continuous {
                    default_value: default_trail,
                    buckets: 10,
                },
            ),
            stop_reckoner: Reckoner::new(
                &format!("stop-{}", lens),
                dims,
                recalib_interval,
                ReckConfig::Continuous {
                    default_value: default_stop,
                    buckets: 10,
                },
            ),
            default_distances: Distances::new(default_trail, default_stop),
            noise_subspace: OnlineSubspace::new(dims, 8),
            incremental: IncrementalBundle::new(dims),
            outcome_window: Vec::with_capacity(SELF_ASSESSMENT_WINDOW),
            residue_window: Vec::with_capacity(SELF_ASSESSMENT_WINDOW),
            grace_rate: 0.0,
            avg_residue: 0.0,
        }
    }

    /// Tier 1 only: query both reckoners. Returns Some(Distances) if both
    /// reckoners are experienced, None otherwise. The broker owns the full
    /// cascade (reckoner → accumulator → default).
    /// Proposal 026: queries on position_thought only, not composed.
    pub fn reckoner_distances(&self, position_thought: &Vector) -> Option<Distances> {
        let trail_exp = self.trail_reckoner.experience();
        let stop_exp = self.stop_reckoner.experience();

        if trail_exp > 0.0 && stop_exp > 0.0 {
            let trail = self.trail_reckoner.query(position_thought);
            let stop = self.stop_reckoner.query(position_thought);
            Some(Distances::new(trail, stop))
        } else {
            None
        }
    }

    /// Full cascade: reckoner -> accumulator -> default.
    /// Kept for tests only — the broker owns the cascade in production.
    /// Proposal 026: queries on position_thought only, not composed.
    #[cfg(test)]
    pub fn recommended_distances(
        &self,
        position_thought: &Vector,
        broker_accums: &[ScalarAccumulator],
        scalar_encoder: &holon::kernel::scalar::ScalarEncoder,
    ) -> (Distances, f64) {
        let trail_exp = self.trail_reckoner.experience();
        let stop_exp = self.stop_reckoner.experience();

        // Trail distance cascade
        let trail = if trail_exp > 0.0 {
            self.trail_reckoner.query(position_thought)
        } else if broker_accums.len() > 0 && broker_accums[0].count > 0 {
            broker_accums[0].extract(100, (0.001, 0.10), scalar_encoder)
        } else {
            self.default_distances.trail
        };

        // Stop distance cascade
        let stop = if stop_exp > 0.0 {
            self.stop_reckoner.query(position_thought)
        } else if broker_accums.len() > 1 && broker_accums[1].count > 0 {
            broker_accums[1].extract(100, (0.001, 0.10), scalar_encoder)
        } else {
            self.default_distances.stop
        };

        let total_exp = trail_exp.min(stop_exp);
        (Distances::new(trail, stop), total_exp)
    }

    /// Learn from hindsight-optimal distances. Both reckoners learn from
    /// one resolution. The position_thought is the position observer's own encoded
    /// facts — NOT the composition with market thought.
    /// Proposal 026: position learns from position_thought only.
    /// Also updates the rolling self-assessment window.
    pub fn observe_distances(
        &mut self,
        position_thought: &Vector,
        optimal: &Distances,
        weight: f64,
        is_grace: bool,
        residue: f64,
    ) {
        self.trail_reckoner.observe_scalar(position_thought, optimal.trail, weight);
        self.stop_reckoner.observe_scalar(position_thought, optimal.stop, weight);

        // Update rolling self-assessment window
        self.outcome_window.push(is_grace);
        if self.outcome_window.len() > SELF_ASSESSMENT_WINDOW {
            self.outcome_window.remove(0);
        }
        self.residue_window.push(residue);
        if self.residue_window.len() > SELF_ASSESSMENT_WINDOW {
            self.residue_window.remove(0);
        }

        // Recompute rates from window
        if !self.outcome_window.is_empty() {
            let grace_count = self.outcome_window.iter().filter(|&&g| g).count();
            self.grace_rate = grace_count as f64 / self.outcome_window.len() as f64;
        }
        if !self.residue_window.is_empty() {
            self.avg_residue = self.residue_window.iter().sum::<f64>() / self.residue_window.len() as f64;
        }
    }

    /// Return the anomalous component — what the noise subspace CANNOT explain.
    /// Same pattern as market_observer.rs.
    pub fn strip_noise(&self, thought: &Vector) -> Vector {
        let thought_f64 = crate::to_f64(thought);
        let anomalous = self.noise_subspace.anomalous_component(&thought_f64);
        Vector::from_f64(&anomalous)
    }

    /// True if both reckoners have accumulated enough observations to
    /// produce meaningful predictions.
    pub fn experienced(&self) -> bool {
        self.trail_reckoner.experience() > 0.0
            && self.stop_reckoner.experience() > 0.0
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use holon::kernel::scalar::ScalarEncoder;
    use holon::kernel::vector_manager::VectorManager;
    use crate::types::enums::ScalarEncoding;

    const DIMS: usize = 4096;
    const RECALIB: usize = 100;
    const DEFAULT_TRAIL: f64 = 0.02;
    const DEFAULT_STOP: f64 = 0.05;

    fn make_observer() -> PositionObserver {
        PositionObserver::new(PositionLens::Core, DIMS, RECALIB, DEFAULT_TRAIL, DEFAULT_STOP)
    }

    fn random_vector(name: &str) -> Vector {
        let vm = VectorManager::new(DIMS);
        vm.get_vector(name)
    }

    #[test]
    fn test_position_observer_new() {
        let obs = make_observer();
        assert_eq!(obs.lens, PositionLens::Core);
        assert!((obs.default_distances.trail - DEFAULT_TRAIL).abs() < 1e-10);
        assert!((obs.default_distances.stop - DEFAULT_STOP).abs() < 1e-10);
    }

    #[test]
    fn test_recommended_distances_returns_defaults_when_empty() {
        let obs = make_observer();
        let composed = random_vector("composed");
        let se = ScalarEncoder::new(DIMS);
        let accums: Vec<ScalarAccumulator> = vec![
            ScalarAccumulator::new("trail-distance", ScalarEncoding::Log, DIMS),
            ScalarAccumulator::new("stop-distance", ScalarEncoding::Log, DIMS),
        ];

        let (distances, exp) = obs.recommended_distances(&composed, &accums, &se);
        assert!((distances.trail - DEFAULT_TRAIL).abs() < 1e-10);
        assert!((distances.stop - DEFAULT_STOP).abs() < 1e-10);
        assert!((exp - 0.0).abs() < 1e-10);
    }

    #[test]
    fn test_experienced_false_initially() {
        let obs = make_observer();
        assert!(!obs.experienced());
    }

    #[test]
    fn test_observe_distances_makes_experienced() {
        let mut obs = make_observer();
        let position_thought = random_vector("position_thought");
        let optimal = Distances::new(0.03, 0.06);
        obs.observe_distances(&position_thought, &optimal, 1.0, true, 0.01);
        assert!(obs.experienced());
    }

    #[test]
    fn test_self_assessment_window() {
        let mut obs = make_observer();
        let position_thought = random_vector("position_thought");
        let optimal = Distances::new(0.03, 0.06);

        // Add some Grace outcomes
        for _ in 0..3 {
            obs.observe_distances(&position_thought, &optimal, 1.0, true, 0.01);
        }
        // Add a Violence outcome
        obs.observe_distances(&position_thought, &optimal, 1.0, false, 0.005);

        assert_eq!(obs.outcome_window.len(), 4);
        assert!((obs.grace_rate - 0.75).abs() < 1e-10);
        assert!(obs.avg_residue > 0.0);
    }

    #[test]
    fn test_reckoner_cascade_after_experience() {
        let mut obs = make_observer();
        let se = ScalarEncoder::new(DIMS);
        let accums: Vec<ScalarAccumulator> = vec![
            ScalarAccumulator::new("trail-distance", ScalarEncoding::Log, DIMS),
            ScalarAccumulator::new("stop-distance", ScalarEncoding::Log, DIMS),
        ];

        // Teach the reckoner
        for i in 0..10 {
            let position_thought = random_vector(&format!("training_{}", i));
            let optimal = Distances::new(0.03, 0.06);
            obs.observe_distances(&position_thought, &optimal, 1.0, true, 0.01);
        }

        assert!(obs.experienced());

        // Now recommended_distances should use the reckoner, not defaults
        let composed = random_vector("test_query");
        let (distances, exp) = obs.recommended_distances(&composed, &accums, &se);
        // With experience, values come from reckoner (may differ from defaults)
        assert!(distances.trail > 0.0);
        assert!(distances.stop > 0.0);
        assert!(exp > 0.0);
    }

    #[test]
    fn test_two_reckoners_independent() {
        let obs = make_observer();
        assert!(obs.trail_reckoner.is_continuous());
        assert!(obs.stop_reckoner.is_continuous());
        // They are separate reckoners with different names
        assert_ne!(obs.trail_reckoner.name(), obs.stop_reckoner.name());
    }

    #[test]
    fn test_strip_noise_returns_vector() {
        let obs = make_observer();
        let thought = random_vector("position_thought");
        let stripped = obs.strip_noise(&thought);
        assert_eq!(stripped.dimensions(), DIMS);
    }

    #[test]
    fn test_noise_subspace_initialized() {
        let obs = make_observer();
        // Noise subspace exists and can process vectors
        let thought = random_vector("test");
        let thought_f64 = crate::to_f64(&thought);
        let _residual = obs.noise_subspace.anomalous_component(&thought_f64);
    }
}
