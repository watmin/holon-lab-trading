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
