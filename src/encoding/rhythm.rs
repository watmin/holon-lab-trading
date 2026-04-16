/// rhythm.rs — the generic indicator rhythm function.
///
/// One function. Three callers: market observer, regime observer, broker-observer.
/// Takes a window of values, builds trigrams, bigram-pairs, bundles them.
/// Returns one Vector — the rhythm of one indicator over time.
///
/// Two variants:
///   indicator_rhythm  — thermometer + delta for continuous values
///   circular_rhythm   — circular encoding, no delta, for periodic values
///
/// The atom wraps the WHOLE rhythm, not each candle's fact. Proposal 056.

use holon::kernel::primitives::Primitives;
use holon::kernel::scalar::{ScalarEncoder, ScalarMode};
use holon::kernel::vector::Vector;
use holon::kernel::vector_manager::VectorManager;

/// Build one indicator rhythm from a window of f64 values.
/// Thermometer encoding for values. Thermometer encoding for deltas.
/// Atom wraps the final rhythm — one bind, not N.
///
/// Returns one Vector. One thought: "how did this indicator evolve?"
pub fn indicator_rhythm(
    vm: &VectorManager,
    scalar: &ScalarEncoder,
    atom_name: &str,
    values: &[f64],
    value_min: f64,
    value_max: f64,
    delta_range: f64,
) -> Vector {
    let dims = vm.dimensions();

    if values.len() < 3 {
        return Vector::zeros(dims);
    }

    let delta_atom = vm.get_vector("delta");

    // Step 1: each value → thermometer + delta from previous
    let facts: Vec<Vector> = values
        .iter()
        .enumerate()
        .map(|(i, &val)| {
            let v = scalar.encode(val, ScalarMode::Thermometer { min: value_min, max: value_max });
            if i == 0 {
                v
            } else {
                let delta = val - values[i - 1];
                let d = scalar.encode(delta, ScalarMode::Thermometer { min: -delta_range, max: delta_range });
                let d_bound = Primitives::bind(&delta_atom, &d);
                let refs = vec![&v, &d_bound];
                Primitives::bundle(&refs)
            }
        })
        .collect();

    // Step 2: trigrams — sliding window of 3
    let trigrams: Vec<Vector> = facts
        .windows(3)
        .map(|w| {
            let ab = Primitives::bind(&w[0], &Primitives::permute(&w[1], 1));
            Primitives::bind(&ab, &Primitives::permute(&w[2], 2))
        })
        .collect();

    // Step 3: bigram-pairs — sliding window of 2 trigrams
    let pairs: Vec<Vector> = trigrams
        .windows(2)
        .map(|w| Primitives::bind(&w[0], &w[1]))
        .collect();

    if pairs.is_empty() {
        return Vector::zeros(dims);
    }

    // Step 4: trim to capacity, bundle
    let budget = (dims as f64).sqrt() as usize;
    let start = if pairs.len() > budget { pairs.len() - budget } else { 0 };
    let trimmed: Vec<&Vector> = pairs[start..].iter().collect();
    let raw = Primitives::bundle(&trimmed);

    // Step 5: bind atom to the whole rhythm — one bind
    let atom = vm.get_vector(atom_name);
    Primitives::bind(&atom, &raw)
}

/// Build one circular rhythm from a window of periodic f64 values.
/// Circular encoding, no delta. The wrap is handled by circular similarity.
/// Atom wraps the final rhythm.
///
/// Use for: hour (period=24), day-of-week (period=7).
pub fn circular_rhythm(
    vm: &VectorManager,
    scalar: &ScalarEncoder,
    atom_name: &str,
    values: &[f64],
    period: f64,
) -> Vector {
    let dims = vm.dimensions();

    if values.len() < 3 {
        return Vector::zeros(dims);
    }

    // Step 1: each value → circular encoding, no delta
    let facts: Vec<Vector> = values
        .iter()
        .map(|&val| scalar.encode(val, ScalarMode::Circular { period }))
        .collect();

    // Step 2: trigrams
    let trigrams: Vec<Vector> = facts
        .windows(3)
        .map(|w| {
            let ab = Primitives::bind(&w[0], &Primitives::permute(&w[1], 1));
            Primitives::bind(&ab, &Primitives::permute(&w[2], 2))
        })
        .collect();

    // Step 3: bigram-pairs
    let pairs: Vec<Vector> = trigrams
        .windows(2)
        .map(|w| Primitives::bind(&w[0], &w[1]))
        .collect();

    if pairs.is_empty() {
        return Vector::zeros(dims);
    }

    // Step 4: trim + bundle
    let budget = (dims as f64).sqrt() as usize;
    let start = if pairs.len() > budget { pairs.len() - budget } else { 0 };
    let trimmed: Vec<&Vector> = pairs[start..].iter().collect();
    let raw = Primitives::bundle(&trimmed);

    // Step 5: bind atom
    let atom = vm.get_vector(atom_name);
    Primitives::bind(&atom, &raw)
}

#[cfg(test)]
mod tests {
    use super::*;
    use holon::kernel::similarity::Similarity;

    const DIMS: usize = 10_000;

    #[test]
    fn deterministic() {
        let vm = VectorManager::new(DIMS);
        let scalar = ScalarEncoder::new(DIMS);
        let values = vec![0.45, 0.48, 0.55, 0.62, 0.68, 0.66, 0.63];

        let r1 = indicator_rhythm(&vm, &scalar, "rsi", &values, 0.0, 100.0, 10.0);
        let r2 = indicator_rhythm(&vm, &scalar, "rsi", &values, 0.0, 100.0, 10.0);

        let cos = Similarity::cosine(&r1, &r2);
        assert!((cos - 1.0).abs() < 1e-6, "same input must produce identical vector, got {}", cos);
    }

    #[test]
    fn different_atoms_orthogonal() {
        let vm = VectorManager::new(DIMS);
        let scalar = ScalarEncoder::new(DIMS);
        let values = vec![0.45, 0.48, 0.55, 0.62, 0.68, 0.66, 0.63];

        let rsi = indicator_rhythm(&vm, &scalar, "rsi", &values, 0.0, 100.0, 10.0);
        let macd = indicator_rhythm(&vm, &scalar, "macd", &values, 0.0, 100.0, 10.0);

        let cos = Similarity::cosine(&rsi, &macd);
        assert!(cos.abs() < 0.15, "different atoms should be near-orthogonal, got {}", cos);
    }

    #[test]
    fn similar_values_high_cosine() {
        let vm = VectorManager::new(DIMS);
        let scalar = ScalarEncoder::new(DIMS);

        let a = vec![40.0, 42.0, 45.0, 50.0, 55.0, 58.0, 60.0];
        let b = vec![41.0, 43.0, 46.0, 51.0, 56.0, 59.0, 61.0];

        let ra = indicator_rhythm(&vm, &scalar, "rsi", &a, 0.0, 100.0, 10.0);
        let rb = indicator_rhythm(&vm, &scalar, "rsi", &b, 0.0, 100.0, 10.0);

        let cos = Similarity::cosine(&ra, &rb);
        assert!(cos > 0.5, "similar progressions should have high cosine, got {}", cos);
    }

    #[test]
    fn circular_wraps_correctly() {
        let vm = VectorManager::new(DIMS);
        let scalar = ScalarEncoder::new(DIMS);

        // 22, 23, 0, 1, 2 — wraps at midnight
        let evening = vec![22.0, 23.0, 0.0, 1.0, 2.0];
        // 14, 15, 16, 17, 18 — afternoon, no wrap
        let afternoon = vec![14.0, 15.0, 16.0, 17.0, 18.0];

        let r_eve = circular_rhythm(&vm, &scalar, "hour", &evening, 24.0);
        let r_aft = circular_rhythm(&vm, &scalar, "hour", &afternoon, 24.0);

        // Both are valid progressions — should be non-degenerate
        let self_cos = Similarity::cosine(&r_eve, &r_eve);
        assert!((self_cos - 1.0).abs() < 1e-6, "self-cosine should be 1.0, got {}", self_cos);

        // Should be distinguishable — different times of day
        let cos = Similarity::cosine(&r_eve, &r_aft);
        assert!(cos < 0.8, "different time periods should be distinguishable, got {}", cos);
    }

    #[test]
    fn too_few_values_returns_zeros() {
        let vm = VectorManager::new(DIMS);
        let scalar = ScalarEncoder::new(DIMS);

        let short = vec![0.5, 0.6];
        let r = indicator_rhythm(&vm, &scalar, "rsi", &short, 0.0, 100.0, 10.0);
        assert_eq!(r, Vector::zeros(DIMS));
    }

    #[test]
    fn bundle_preserves_individuals() {
        let vm = VectorManager::new(DIMS);
        let scalar = ScalarEncoder::new(DIMS);

        let rsi_vals = vec![40.0, 45.0, 50.0, 55.0, 60.0, 65.0, 70.0];
        let adx_vals = vec![15.0, 18.0, 22.0, 28.0, 32.0, 30.0, 27.0];

        let rsi_r = indicator_rhythm(&vm, &scalar, "rsi", &rsi_vals, 0.0, 100.0, 10.0);
        let adx_r = indicator_rhythm(&vm, &scalar, "adx", &adx_vals, 0.0, 100.0, 10.0);

        let refs = vec![&rsi_r, &adx_r];
        let thought = Primitives::bundle(&refs);

        let cos_rsi = Similarity::cosine(&thought, &rsi_r);
        let cos_adx = Similarity::cosine(&thought, &adx_r);

        assert!(cos_rsi > 0.3, "RSI rhythm should be present in bundle, got {}", cos_rsi);
        assert!(cos_adx > 0.3, "ADX rhythm should be present in bundle, got {}", cos_adx);
    }
}
