/// exit_observer.rs — Estimates exit distances. Learned. Two continuous reckoners
/// (trail, stop). Compiled from wat/exit-observer.wat.
///
/// Intentionally simpler than MarketObserver. No noise-subspace, no curve,
/// no engram gating. Quality is measured through the BROKER's curve.

use holon::kernel::vector::Vector;
use holon::memory::{ReckConfig, Reckoner};

use crate::distances::Distances;
use crate::enums::ExitLens;
use crate::scalar_accumulator::ScalarAccumulator;
use crate::thought_encoder::IncrementalBundle;

/// Estimates exit distances through a specific judgment lens.
pub struct ExitObserver {
    /// Which judgment vocabulary.
    pub lens: ExitLens,
    /// Continuous reckoner -- trailing stop distance.
    pub trail_reckoner: Reckoner,
    /// Continuous reckoner -- safety stop distance.
    pub stop_reckoner: Reckoner,
    /// The crutches (both), returned when empty.
    pub default_distances: Distances,
    /// Incremental bundling for exit facts — optimization cache, not cognition.
    pub incremental: IncrementalBundle,
}

impl ExitObserver {
    /// Construct a new exit observer with two continuous reckoners.
    pub fn new(
        lens: ExitLens,
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
                ReckConfig::Continuous(default_trail),
            ),
            stop_reckoner: Reckoner::new(
                &format!("stop-{}", lens),
                dims,
                recalib_interval,
                ReckConfig::Continuous(default_stop),
            ),
            default_distances: Distances::new(default_trail, default_stop),
            incremental: IncrementalBundle::new(dims),
        }
    }

    /// Recommended distances: cascade from reckoner -> accumulator -> default.
    /// Returns (Distances, experience).
    ///
    /// The cascade, per distance:
    ///   experienced? reckoner -> predict (contextual for THIS thought)
    ///   has-data? broker-accum -> extract-scalar (global per-pair)
    ///   default-distance (crutch)
    pub fn recommended_distances(
        &self,
        composed: &Vector,
        broker_accums: &[ScalarAccumulator],
        scalar_encoder: &holon::kernel::scalar::ScalarEncoder,
    ) -> (Distances, f64) {
        let trail_exp = self.trail_reckoner.experience();
        let stop_exp = self.stop_reckoner.experience();

        // Trail distance cascade
        let trail = if trail_exp > 0.0 {
            self.trail_reckoner.query(composed)
        } else if broker_accums.len() > 0 && broker_accums[0].count > 0 {
            broker_accums[0].extract(100, (0.001, 0.10), scalar_encoder)
        } else {
            self.default_distances.trail
        };

        // Stop distance cascade
        let stop = if stop_exp > 0.0 {
            self.stop_reckoner.query(composed)
        } else if broker_accums.len() > 1 && broker_accums[1].count > 0 {
            broker_accums[1].extract(100, (0.001, 0.10), scalar_encoder)
        } else {
            self.default_distances.stop
        };

        let total_exp = trail_exp.min(stop_exp);
        (Distances::new(trail, stop), total_exp)
    }

    /// Learn from hindsight-optimal distances. Both reckoners learn from
    /// one resolution. The composed thought is the COMPOSED vector
    /// (market + exit facts), not the raw market thought.
    pub fn observe_distances(
        &mut self,
        composed: &Vector,
        optimal: &Distances,
        weight: f64,
    ) {
        self.trail_reckoner.observe_scalar(composed, optimal.trail, weight);
        self.stop_reckoner.observe_scalar(composed, optimal.stop, weight);
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
    use crate::enums::ScalarEncoding;

    const DIMS: usize = 4096;
    const RECALIB: usize = 100;
    const DEFAULT_TRAIL: f64 = 0.02;
    const DEFAULT_STOP: f64 = 0.05;

    fn make_observer() -> ExitObserver {
        ExitObserver::new(ExitLens::Volatility, DIMS, RECALIB, DEFAULT_TRAIL, DEFAULT_STOP)
    }

    fn random_vector(name: &str) -> Vector {
        let vm = VectorManager::new(DIMS);
        vm.get_vector(name)
    }

    #[test]
    fn test_exit_observer_new() {
        let obs = make_observer();
        assert_eq!(obs.lens, ExitLens::Volatility);
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
        let composed = random_vector("composed");
        let optimal = Distances::new(0.03, 0.06);
        obs.observe_distances(&composed, &optimal, 1.0);
        assert!(obs.experienced());
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
            let composed = random_vector(&format!("training_{}", i));
            let optimal = Distances::new(0.03, 0.06);
            obs.observe_distances(&composed, &optimal, 1.0);
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
}
