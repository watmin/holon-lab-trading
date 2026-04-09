//! scalar-accumulator.wat -- per-magic-number f64 learning
//! Depends on: enums.wat (Outcome, ScalarEncoding)

use holon::{Primitives, ScalarEncoder, ScalarMode, Similarity, Vector};

use crate::enums::{Outcome, ScalarEncoding};

/// Lives on the broker. Global per-pair. Each distance (trail, stop,
/// tp, runner-trail) gets its own. Grace outcomes accumulate one way,
/// Violence outcomes the other.
#[derive(Clone)]
pub struct ScalarAccumulator {
    pub name: String,
    pub encoding: ScalarEncoding,
    pub grace_acc: Vector,
    pub violence_acc: Vector,
    pub count: usize,
    pub dims: usize,
    scalar_encoder: ScalarEncoder,
}

impl ScalarAccumulator {
    pub fn new(name: String, encoding: ScalarEncoding, dims: usize) -> Self {
        Self {
            name,
            encoding,
            grace_acc: Vector::zeros(dims),
            violence_acc: Vector::zeros(dims),
            count: 0,
            dims,
            scalar_encoder: ScalarEncoder::new(dims),
        }
    }

    /// Dispatch on ScalarEncoding to produce a vector.
    fn encode_by_scheme(&self, value: f64) -> Vector {
        match &self.encoding {
            ScalarEncoding::Log => self.scalar_encoder.encode_log(value),
            ScalarEncoding::Linear { scale } => {
                self.scalar_encoder.encode(value, ScalarMode::Linear { scale: *scale })
            }
            ScalarEncoding::Circular { period } => {
                self.scalar_encoder.encode(value, ScalarMode::Circular { period: *period })
            }
        }
    }

    /// Accumulate an encoded value into the appropriate prototype.
    pub fn observe(&mut self, value: f64, outcome: Outcome, weight: f64) {
        let encoded = self.encode_by_scheme(value);
        let weighted = Primitives::amplify(&encoded, &encoded, weight);
        match outcome {
            Outcome::Grace => {
                self.grace_acc = Primitives::bundle(&[&self.grace_acc, &weighted]);
                self.count += 1;
            }
            Outcome::Violence => {
                self.violence_acc = Primitives::bundle(&[&self.violence_acc, &weighted]);
                self.count += 1;
            }
        }
    }

    /// Sweep candidates, find the one Grace prefers.
    pub fn extract(&self, steps: usize, bounds: (f64, f64)) -> f64 {
        let (lo, hi) = bounds;
        let step_size = (hi - lo) / steps.max(1) as f64;
        let mut best_value = lo;
        let mut best_score = f64::NEG_INFINITY;

        for i in 0..=steps {
            let candidate = lo + i as f64 * step_size;
            let encoded = self.encode_by_scheme(candidate);
            let score = Similarity::cosine(&encoded, &self.grace_acc);
            if score > best_score {
                best_value = candidate;
                best_score = score;
            }
        }

        best_value
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const DIMS: usize = 4096;

    #[test]
    fn test_construct_log() {
        let acc = ScalarAccumulator::new("trail".to_string(), ScalarEncoding::Log, DIMS);
        assert_eq!(acc.name, "trail");
        assert_eq!(acc.count, 0);
        assert_eq!(acc.dims, DIMS);
    }

    #[test]
    fn test_construct_linear() {
        let acc = ScalarAccumulator::new("stop".to_string(), ScalarEncoding::Linear { scale: 100.0 }, DIMS);
        assert_eq!(acc.name, "stop");
        assert_eq!(acc.encoding, ScalarEncoding::Linear { scale: 100.0 });
    }

    #[test]
    fn test_observe_increments_count() {
        let mut acc = ScalarAccumulator::new("trail".to_string(), ScalarEncoding::Log, DIMS);
        acc.observe(0.02, Outcome::Grace, 1.0);
        assert_eq!(acc.count, 1);
        acc.observe(0.05, Outcome::Violence, 1.0);
        assert_eq!(acc.count, 2);
    }

    #[test]
    fn test_extract_converges_to_grace_log() {
        let mut acc = ScalarAccumulator::new("trail".to_string(), ScalarEncoding::Log, DIMS);

        // Grace prefers 0.02
        for _ in 0..20 {
            acc.observe(0.02, Outcome::Grace, 1.0);
        }
        // Violence gets 0.05
        for _ in 0..20 {
            acc.observe(0.05, Outcome::Violence, 1.0);
        }

        let extracted = acc.extract(100, (0.005, 0.10));
        // Extracted should be closer to 0.02 than to 0.05
        let dist_grace = (extracted - 0.02).abs();
        let dist_violence = (extracted - 0.05).abs();
        assert!(
            dist_grace < dist_violence,
            "extract should converge toward Grace value (0.02). Got {:.4}, dist_grace={:.4}, dist_violence={:.4}",
            extracted, dist_grace, dist_violence
        );
    }

    #[test]
    fn test_extract_converges_to_grace_linear() {
        let mut acc = ScalarAccumulator::new(
            "stop".to_string(),
            ScalarEncoding::Linear { scale: 100.0 },
            DIMS,
        );

        // Grace prefers 0.03
        for _ in 0..20 {
            acc.observe(0.03, Outcome::Grace, 1.0);
        }
        // Violence gets 0.08
        for _ in 0..20 {
            acc.observe(0.08, Outcome::Violence, 1.0);
        }

        let extracted = acc.extract(100, (0.01, 0.10));
        let dist_grace = (extracted - 0.03).abs();
        let dist_violence = (extracted - 0.08).abs();
        assert!(
            dist_grace < dist_violence,
            "Linear extract should converge toward Grace value (0.03). Got {:.4}",
            extracted
        );
    }

    #[test]
    fn test_extract_empty_returns_lo() {
        let acc = ScalarAccumulator::new("trail".to_string(), ScalarEncoding::Log, DIMS);
        // With no observations, grace_acc is zeros. Any candidate will have similar
        // cosine. The sweep starts at lo and best_value starts at lo.
        let extracted = acc.extract(100, (0.01, 0.10));
        // Should return something within bounds
        assert!(extracted >= 0.01 && extracted <= 0.10,
                "Expected value in bounds, got {}", extracted);
    }

    #[test]
    fn test_grace_violence_separate() {
        let mut acc = ScalarAccumulator::new("trail".to_string(), ScalarEncoding::Log, DIMS);

        // Only observe Grace
        for _ in 0..20 {
            acc.observe(0.02, Outcome::Grace, 1.0);
        }

        // grace_acc should be non-zero, violence_acc should still be zero
        let grace_nnz: usize = acc.grace_acc.data().iter().filter(|&&x| x != 0).count();
        let violence_nnz: usize = acc.violence_acc.data().iter().filter(|&&x| x != 0).count();
        assert!(grace_nnz > 0, "Grace accumulator should be non-zero after observations");
        assert_eq!(violence_nnz, 0, "Violence accumulator should still be zero");
    }
}
