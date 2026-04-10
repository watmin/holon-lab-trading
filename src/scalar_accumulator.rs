/// Per-magic-number f64 learning.
/// Lives on the broker. Global per-pair.

use crate::enums::{Outcome, ScalarEncoding};
use holon::kernel::primitives::Primitives;
use holon::kernel::scalar::{ScalarEncoder, ScalarMode};
use holon::kernel::similarity::Similarity;
use holon::kernel::vector::Vector;

#[derive(Clone)]
pub struct ScalarAccumulator {
    pub name: String,
    pub encoding: ScalarEncoding,
    pub grace_acc: Vector,
    pub violence_acc: Vector,
    pub count: usize,
    dims: usize,
    scalar_encoder: ScalarEncoder,
}

impl std::fmt::Debug for ScalarAccumulator {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ScalarAccumulator")
            .field("name", &self.name)
            .field("encoding", &self.encoding)
            .field("count", &self.count)
            .field("dims", &self.dims)
            .finish()
    }
}

impl ScalarAccumulator {
    pub fn new(name: impl Into<String>, encoding: ScalarEncoding, dims: usize) -> Self {
        Self {
            name: name.into(),
            encoding,
            grace_acc: Vector::zeros(dims),
            violence_acc: Vector::zeros(dims),
            count: 0,
            dims,
            scalar_encoder: ScalarEncoder::new(dims),
        }
    }

    /// Encode a scalar value using the configured encoding.
    fn encode_scalar_value(&self, value: f64) -> Vector {
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

    /// Observe a scalar value with its outcome.
    /// Grace outcomes accumulate into grace_acc, Violence into violence_acc.
    pub fn observe(&mut self, value: f64, outcome: &Outcome, weight: f64) {
        let encoded = self.encode_scalar_value(value);
        let amplified = Primitives::amplify(&encoded, &encoded, weight);
        match outcome {
            Outcome::Grace => {
                self.grace_acc = Primitives::bundle(&[&self.grace_acc, &amplified]);
            }
            Outcome::Violence => {
                self.violence_acc = Primitives::bundle(&[&self.violence_acc, &amplified]);
            }
        }
        self.count += 1;
    }

    /// Extract the scalar value that Grace prefers.
    /// Sweep candidates across the range, encode each, cosine against
    /// the Grace prototype. Return the candidate closest to Grace.
    pub fn extract(&self, steps: usize, bounds: (f64, f64)) -> f64 {
        let (lo, hi) = bounds;
        let step_size = (hi - lo) / steps as f64;
        let grace_proto = &self.grace_acc;

        let mut best_val = lo;
        let mut best_sim = f64::NEG_INFINITY;

        for i in 0..=steps {
            let candidate = lo + i as f64 * step_size;
            let encoded = self.encode_scalar_value(candidate);
            let sim = Similarity::cosine(&encoded, grace_proto);
            if sim > best_sim {
                best_sim = sim;
                best_val = candidate;
            }
        }

        best_val
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_scalar_accumulator_new() {
        let acc = ScalarAccumulator::new("trail-distance", ScalarEncoding::Log, 4096);
        assert_eq!(acc.name, "trail-distance");
        assert_eq!(acc.encoding, ScalarEncoding::Log);
        assert_eq!(acc.count, 0);
        assert_eq!(acc.grace_acc.dimensions(), 4096);
        assert_eq!(acc.violence_acc.dimensions(), 4096);
    }

    #[test]
    fn test_observe_increments_count() {
        let mut acc = ScalarAccumulator::new("test", ScalarEncoding::Log, 4096);
        acc.observe(0.02, &Outcome::Grace, 1.0);
        assert_eq!(acc.count, 1);
        acc.observe(0.05, &Outcome::Violence, 1.0);
        assert_eq!(acc.count, 2);
    }

    #[test]
    fn test_extract_converges_toward_grace() {
        let mut acc = ScalarAccumulator::new("test", ScalarEncoding::Log, 4096);

        // Repeatedly observe the same Grace value
        for _ in 0..20 {
            acc.observe(0.02, &Outcome::Grace, 1.0);
        }
        // Observe Violence at a different value
        for _ in 0..20 {
            acc.observe(0.10, &Outcome::Violence, 1.0);
        }

        let extracted = acc.extract(100, (0.005, 0.15));
        // The extracted value should be closer to 0.02 than to 0.10
        let dist_grace = (extracted - 0.02).abs();
        let dist_violence = (extracted - 0.10).abs();
        assert!(
            dist_grace < dist_violence,
            "Expected extraction closer to Grace (0.02), got {:.4} (dist_grace={:.4}, dist_violence={:.4})",
            extracted, dist_grace, dist_violence
        );
    }

    #[test]
    fn test_linear_encoding() {
        let mut acc = ScalarAccumulator::new("linear-test", ScalarEncoding::Linear { scale: 10.0 }, 4096);
        acc.observe(5.0, &Outcome::Grace, 1.0);
        assert_eq!(acc.count, 1);
    }

    #[test]
    fn test_circular_encoding() {
        let mut acc = ScalarAccumulator::new("circular-test", ScalarEncoding::Circular { period: 24.0 }, 4096);
        acc.observe(12.0, &Outcome::Grace, 1.0);
        assert_eq!(acc.count, 1);
    }
}
