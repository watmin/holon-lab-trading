//! Scalar accumulator — learns a continuous value from outcomes.
//!
//! Each scalar (k_trail, k_stop, k_tp) gets its own accumulator.
//! Not bundled with thoughts. Not on the sphere with the facts.
//! Its own f64 space. Its own prototype.
//!
//! Grace outcomes accumulate the scalar encoding that produced grace.
//! Violence outcomes accumulate the scalar encoding that produced violence.
//! The grace prototype IS the learned optimal scalar.
//! Extract via sweep: which candidate encoding is the grace prototype closest to?

use holon::{ScalarEncoder, ScalarMode, Primitives};

use super::tuple::{normalize_scalar, denormalize_scalar, SCALAR_SCALE};

/// Accumulates f64-encoded scalar values by outcome.
/// Two accumulators: grace and violence.
pub struct ScalarAccumulator {
    name: String,
    max_value: f64,
    dims: usize,
    grace_sums: Vec<f64>,
    violence_sums: Vec<f64>,
    grace_count: usize,
    violence_count: usize,
    encoder: ScalarEncoder,
}

impl ScalarAccumulator {
    pub fn new(name: &str, max_value: f64, dims: usize) -> Self {
        Self {
            name: name.to_string(),
            max_value,
            dims,
            grace_sums: vec![0.0; dims],
            violence_sums: vec![0.0; dims],
            grace_count: 0,
            violence_count: 0,
            encoder: ScalarEncoder::new(dims),
        }
    }

    /// Accumulate a scalar value with an outcome.
    /// `value`: the raw scalar (e.g., k_trail=1.5).
    /// `grace`: true = this value produced grace, false = violence.
    /// `weight`: how much grace/violence (the amount).
    pub fn observe(&mut self, value: f64, grace: bool, weight: f64) {
        let normalized = normalize_scalar(value, self.max_value);
        let mode = ScalarMode::Linear { scale: SCALAR_SCALE };
        let encoded = self.encoder.encode_f64(normalized, mode);

        let (sums, count) = if grace {
            (&mut self.grace_sums, &mut self.grace_count)
        } else {
            (&mut self.violence_sums, &mut self.violence_count)
        };

        for (s, &e) in sums.iter_mut().zip(encoded.iter()) {
            *s += e * weight;
        }
        *count += 1;
    }

    /// Extract the learned optimal scalar from the grace accumulator.
    /// Sweep f64 candidates against the grace prototype. Return the best match.
    /// Returns None if no grace observations yet.
    pub fn extract(&self) -> Option<f64> {
        if self.grace_count == 0 { return None; }

        let mode = ScalarMode::Linear { scale: SCALAR_SCALE };
        let mut best_val = 0.0f64;
        let mut best_cos = -2.0f64;

        // Coarse sweep: 200 candidates
        for i in 0..=200 {
            let v = i as f64 / 200.0;
            let enc = self.encoder.encode_f64(v, mode);
            let cos = Primitives::cosine_f64(&self.grace_sums, &enc);
            if cos > best_cos { best_cos = cos; best_val = v; }
        }

        // Refine: 100 candidates around the best
        let step = 1.0 / 200.0;
        let lo = (best_val - step * 2.0).max(0.0);
        let hi = (best_val + step * 2.0).min(1.0);
        for i in 0..=100 {
            let v = lo + (hi - lo) * i as f64 / 100.0;
            let enc = self.encoder.encode_f64(v, mode);
            let cos = Primitives::cosine_f64(&self.grace_sums, &enc);
            if cos > best_cos { best_cos = cos; best_val = v; }
        }

        Some(denormalize_scalar(best_val, self.max_value))
    }

    pub fn grace_count(&self) -> usize { self.grace_count }
    pub fn violence_count(&self) -> usize { self.violence_count }
    pub fn name(&self) -> &str { &self.name }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scalar_accumulator_recovers_grace_value() {
        // Grace always uses k_trail=1.7. Violence always uses k_trail=0.5.
        // The accumulator should recover ~1.7 from the grace side.
        let mut acc = ScalarAccumulator::new("k-trail", 5.0, 10000);

        for _ in 0..500 {
            acc.observe(1.7, true, 1.0);   // grace
            acc.observe(0.5, false, 1.0);  // violence
        }

        let recovered = acc.extract().expect("should have grace observations");
        eprintln!("recovered k_trail: {:.2} (expected ~1.7)", recovered);
        assert!((recovered - 1.7).abs() < 0.5,
            "recovered {:.2} should be near 1.7", recovered);
    }

    #[test]
    fn scalar_accumulator_distinguishes_values() {
        // Grace uses k_trail=2.5. Violence uses k_trail=1.0.
        let mut acc = ScalarAccumulator::new("k-trail", 5.0, 10000);

        for _ in 0..200 {
            acc.observe(2.5, true, 1.0);
            acc.observe(1.0, false, 1.0);
        }

        let recovered = acc.extract().unwrap();
        eprintln!("recovered: {:.2} (expected ~2.5)", recovered);
        assert!((recovered - 2.5).abs() < 0.5,
            "recovered {:.2} should be near 2.5", recovered);
    }

    #[test]
    fn scalar_accumulator_weighted() {
        // Heavy grace at 2.0, light grace at 1.0. Should recover ~2.0.
        let mut acc = ScalarAccumulator::new("k-trail", 5.0, 10000);

        for _ in 0..200 {
            acc.observe(2.0, true, 10.0);  // heavy weight
            acc.observe(1.0, true, 1.0);   // light weight
            acc.observe(0.5, false, 1.0);
        }

        let recovered = acc.extract().unwrap();
        eprintln!("recovered: {:.2} (expected ~2.0, weighted toward heavy)", recovered);
        assert!((recovered - 2.0).abs() < 0.5,
            "recovered {:.2} should be near 2.0", recovered);
    }
}
