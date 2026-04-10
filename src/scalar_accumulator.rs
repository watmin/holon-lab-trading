/// Per-scalar f64 learning via VSA prototypes. Compiled from wat/scalar-accumulator.wat.
///
/// Separates grace/violence observations into separate vector prototypes.
/// Extract sweeps candidates and returns the value closest to the grace centroid.

use holon::kernel::primitives::Primitives;
use holon::kernel::scalar::{ScalarEncoder, ScalarMode};
use holon::kernel::similarity::Similarity;
use holon::kernel::vector::Vector;

use crate::enums::{Outcome, ScalarEncoding};

/// Accumulated scalar observations separated by outcome.
pub struct ScalarAccumulator {
    pub name: String,
    pub encoding: ScalarEncoding,
    pub grace_acc: Vector,
    pub violence_acc: Vector,
    pub count: usize,
}

impl ScalarAccumulator {
    /// Create a new accumulator with zero vectors.
    pub fn new(name: impl Into<String>, encoding: ScalarEncoding, dims: usize) -> Self {
        Self {
            name: name.into(),
            encoding,
            grace_acc: Vector::zeros(dims),
            violence_acc: Vector::zeros(dims),
            count: 0,
        }
    }

    /// Encode value per the accumulator's encoding, amplify by weight,
    /// and bundle into the appropriate accumulator based on outcome.
    pub fn observe(
        &mut self,
        value: f64,
        outcome: Outcome,
        weight: f64,
        scalar_encoder: &ScalarEncoder,
    ) {
        let encoded = self.encode_value(value, scalar_encoder);
        let scaled = Primitives::amplify(&encoded, &encoded, weight);

        match outcome {
            Outcome::Grace => {
                self.grace_acc = Primitives::bundle(&[&self.grace_acc, &scaled]);
            }
            Outcome::Violence => {
                self.violence_acc = Primitives::bundle(&[&self.violence_acc, &scaled]);
            }
        }
        self.count += 1;
    }

    /// Sweep `steps` candidate values across `range`, encode each, cosine
    /// against the grace prototype. Return the candidate closest to grace.
    pub fn extract(
        &self,
        steps: usize,
        range: (f64, f64),
        scalar_encoder: &ScalarEncoder,
    ) -> f64 {
        let (range_min, range_max) = range;
        assert!(steps >= 2, "Need at least 2 steps for sweep");

        let step_size = (range_max - range_min) / (steps - 1) as f64;

        let mut best_value = range_min;
        let mut best_score = f64::NEG_INFINITY;

        for i in 0..steps {
            let v = range_min + i as f64 * step_size;
            let encoded = self.encode_value(v, scalar_encoder);
            let score = Similarity::cosine(&encoded, &self.grace_acc);
            if score > best_score {
                best_score = score;
                best_value = v;
            }
        }

        best_value
    }

    /// Encode a value using the accumulator's configured encoding.
    fn encode_value(&self, value: f64, scalar_encoder: &ScalarEncoder) -> Vector {
        match self.encoding {
            ScalarEncoding::Log => scalar_encoder.encode_log(value),
            ScalarEncoding::Linear { scale } => {
                scalar_encoder.encode(value, ScalarMode::Linear { scale })
            }
            ScalarEncoding::Circular { period } => {
                scalar_encoder.encode(value, ScalarMode::Circular { period })
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const DIMS: usize = 4096;

    #[test]
    fn test_new_accumulator() {
        let acc = ScalarAccumulator::new("trail-distance", ScalarEncoding::Log, DIMS);
        assert_eq!(acc.name, "trail-distance");
        assert_eq!(acc.count, 0);
        assert_eq!(acc.grace_acc.dimensions(), DIMS);
        assert_eq!(acc.violence_acc.dimensions(), DIMS);
    }

    #[test]
    fn test_observe_increments_count() {
        let se = ScalarEncoder::new(DIMS);
        let mut acc = ScalarAccumulator::new("test", ScalarEncoding::Log, DIMS);

        acc.observe(100.0, Outcome::Grace, 1.0, &se);
        assert_eq!(acc.count, 1);

        acc.observe(200.0, Outcome::Violence, 1.0, &se);
        assert_eq!(acc.count, 2);
    }

    #[test]
    fn test_extract_converges_to_grace_centroid() {
        let se = ScalarEncoder::new(DIMS);
        let mut acc =
            ScalarAccumulator::new("test", ScalarEncoding::Linear { scale: 100.0 }, DIMS);

        // Observe many grace values clustered around 50.0
        for _ in 0..20 {
            for &v in &[48.0, 49.0, 50.0, 51.0, 52.0] {
                acc.observe(v, Outcome::Grace, 1.0, &se);
            }
        }

        // Observe violence values far away
        for _ in 0..5 {
            for &v in &[5.0, 10.0, 15.0] {
                acc.observe(v, Outcome::Violence, 1.0, &se);
            }
        }

        // Extract should return a value near the grace cluster
        let extracted = acc.extract(200, (0.0, 100.0), &se);
        assert!(
            (extracted - 50.0).abs() < 15.0,
            "Expected near 50.0, got {}",
            extracted
        );
    }

    #[test]
    fn test_extract_distinguishes_grace_from_violence() {
        let se = ScalarEncoder::new(DIMS);
        let mut acc =
            ScalarAccumulator::new("test", ScalarEncoding::Linear { scale: 200.0 }, DIMS);

        // Grace values around 150, violence around 30
        for _ in 0..20 {
            acc.observe(150.0, Outcome::Grace, 1.0, &se);
            acc.observe(30.0, Outcome::Violence, 1.0, &se);
        }

        // Extract should pick a value closer to 150 than to 30
        let extracted = acc.extract(100, (0.0, 200.0), &se);
        let dist_to_grace = (extracted - 150.0).abs();
        let dist_to_violence = (extracted - 30.0).abs();
        assert!(
            dist_to_grace < dist_to_violence,
            "Expected closer to grace (150) than violence (30), got {}",
            extracted
        );
    }
}
