/// prove_indicator_rhythm.rs — proof that bundled bigrams of trigrams
/// encode indicator progressions as distinguishable rhythm vectors.
///
/// Uses holon-rs primitives directly. Real algebra. Real dimensions.
///
/// Proves:
/// 1. Deterministic — same input → same vector
/// 2. Similar progressions → high cosine
/// 3. Different progressions → low cosine
/// 4. Reversed progression → different vector (order preserved)
/// 5. Capacity — many pairs bundled remain distinguishable from random

use holon::kernel::primitives::Primitives;
use holon::kernel::scalar::ScalarEncoder;
use holon::kernel::similarity::Similarity;
use holon::kernel::vector::Vector;
use holon::kernel::vector_manager::VectorManager;

const DIMS: usize = 10_000;

/// Encode one candle's indicator fact: (bind (atom name) (linear value scale))
/// Plus delta from previous if available.
fn encode_fact(
    vm: &VectorManager,
    scalar: &ScalarEncoder,
    name: &str,
    value: f64,
    prev: Option<f64>,
) -> Vector {
    let atom = vm.get_vector(name);
    // Value: [0, 1] range for normalized indicators
    let value_vec = scalar.encode(value, holon::kernel::scalar::ScalarMode::Thermometer { min: 0.0, max: 1.0 });
    let fact = Primitives::bind(&atom, &value_vec);

    match prev {
        None => fact,
        Some(prev_val) => {
            let delta_atom = vm.get_vector(&format!("{}-delta", name));
            // Delta: symmetric around zero. ±0.2 covers typical per-candle changes.
            let delta_vec = scalar.encode(
                value - prev_val,
                holon::kernel::scalar::ScalarMode::Thermometer { min: -0.2, max: 0.2 },
            );
            let delta_fact = Primitives::bind(&delta_atom, &delta_vec);
            let refs = vec![&fact, &delta_fact];
            Primitives::bundle(&refs)
        }
    }
}

/// Build one indicator rhythm from a series of values.
/// Returns one vector — the bundled bigrams of trigrams.
fn indicator_rhythm(
    vm: &VectorManager,
    scalar: &ScalarEncoder,
    name: &str,
    values: &[f64],
) -> Vector {
    assert!(values.len() >= 3, "need at least 3 values for a trigram");

    // Step 1: encode each candle's fact
    let facts: Vec<Vector> = values
        .iter()
        .enumerate()
        .map(|(i, &val)| {
            let prev = if i > 0 { Some(values[i - 1]) } else { None };
            encode_fact(vm, scalar, name, val, prev)
        })
        .collect();

    // Step 2: trigrams — sliding window of 3
    let trigrams: Vec<Vector> = facts
        .windows(3)
        .map(|w| {
            let a = &w[0];
            let b = Primitives::permute(&w[1], 1);
            let c = Primitives::permute(&w[2], 2);
            let ab = Primitives::bind(a, &b);
            Primitives::bind(&ab, &c)
        })
        .collect();

    // Step 3: bigram-pairs — sliding window of 2 trigrams
    let pairs: Vec<Vector> = trigrams
        .windows(2)
        .map(|w| Primitives::bind(&w[0], &w[1]))
        .collect();

    // Step 4: bundle all pairs — the rhythm
    if pairs.is_empty() {
        return Vector::zeros(vm.dimensions());
    }
    let refs: Vec<&Vector> = pairs.iter().collect();
    Primitives::bundle(&refs)
}

#[test]
fn deterministic() {
    let vm = VectorManager::new(DIMS);
    let scalar = ScalarEncoder::new(DIMS);
    let values = vec![0.45, 0.48, 0.55, 0.62, 0.68, 0.66, 0.63];

    let r1 = indicator_rhythm(&vm, &scalar, "rsi", &values);
    let r2 = indicator_rhythm(&vm, &scalar, "rsi", &values);

    let cos = Similarity::cosine(&r1, &r2);
    assert!(
        (cos - 1.0).abs() < 1e-6,
        "same input must produce identical vector, got cosine={}",
        cos
    );
}

#[test]
fn similar_progressions_high_cosine() {
    let vm = VectorManager::new(DIMS);
    let scalar = ScalarEncoder::new(DIMS);

    // Both rising, similar rates
    let rising_a = vec![0.45, 0.48, 0.52, 0.57, 0.62, 0.66, 0.70];
    let rising_b = vec![0.44, 0.47, 0.51, 0.56, 0.61, 0.65, 0.69];

    let ra = indicator_rhythm(&vm, &scalar, "rsi", &rising_a);
    let rb = indicator_rhythm(&vm, &scalar, "rsi", &rising_b);

    let cos = Similarity::cosine(&ra, &rb);
    assert!(
        cos > 0.5,
        "similar rising progressions should have high cosine, got {}",
        cos
    );
}

#[test]
fn different_progressions_low_cosine() {
    let vm = VectorManager::new(DIMS);
    let scalar = ScalarEncoder::new(DIMS);

    // Rising
    let rising = vec![0.30, 0.35, 0.42, 0.50, 0.58, 0.65, 0.72];
    // Falling
    let falling = vec![0.72, 0.65, 0.58, 0.50, 0.42, 0.35, 0.30];

    let rr = indicator_rhythm(&vm, &scalar, "rsi", &rising);
    let rf = indicator_rhythm(&vm, &scalar, "rsi", &falling);

    let cos = Similarity::cosine(&rr, &rf);
    assert!(
        cos < 0.3,
        "rising vs falling should have low cosine, got {}",
        cos
    );
}

#[test]
fn reversed_window_different_vector() {
    let vm = VectorManager::new(DIMS);
    let scalar = ScalarEncoder::new(DIMS);

    let values = vec![0.45, 0.55, 0.65, 0.60, 0.50, 0.45, 0.40];
    let reversed: Vec<f64> = values.iter().rev().cloned().collect();

    let r_fwd = indicator_rhythm(&vm, &scalar, "rsi", &values);
    let r_rev = indicator_rhythm(&vm, &scalar, "rsi", &reversed);

    let cos = Similarity::cosine(&r_fwd, &r_rev);
    assert!(
        cos < 0.5,
        "forward vs reversed should be distinguishable, got cosine={}",
        cos
    );
}

#[test]
fn different_indicators_orthogonal() {
    let vm = VectorManager::new(DIMS);
    let scalar = ScalarEncoder::new(DIMS);

    let values = vec![0.45, 0.48, 0.55, 0.62, 0.68, 0.66, 0.63];

    // Same values, different atom names
    let rsi_rhythm = indicator_rhythm(&vm, &scalar, "rsi", &values);
    let macd_rhythm = indicator_rhythm(&vm, &scalar, "macd-hist", &values);

    let cos = Similarity::cosine(&rsi_rhythm, &macd_rhythm);
    assert!(
        cos.abs() < 0.3,
        "different indicator names should produce near-orthogonal rhythms, got cosine={}",
        cos
    );
}

#[test]
fn bundle_of_rhythms_preserves_individuals() {
    let vm = VectorManager::new(DIMS);
    let scalar = ScalarEncoder::new(DIMS);

    let rsi_values = vec![0.45, 0.48, 0.55, 0.62, 0.68, 0.66, 0.63];
    let macd_values = vec![5.0, 8.0, 12.0, 10.0, 6.0, 3.0, -1.0];
    let adx_values = vec![15.0, 18.0, 22.0, 28.0, 32.0, 30.0, 27.0];

    let rsi_r = indicator_rhythm(&vm, &scalar, "rsi", &rsi_values);
    let macd_r = indicator_rhythm(&vm, &scalar, "macd-hist", &macd_values);
    let adx_r = indicator_rhythm(&vm, &scalar, "adx", &adx_values);

    // Bundle all three — the market observer's thought
    let refs = vec![&rsi_r, &macd_r, &adx_r];
    let thought = Primitives::bundle(&refs);

    // Each individual rhythm should be recoverable by cosine
    let cos_rsi = Similarity::cosine(&thought, &rsi_r);
    let cos_macd = Similarity::cosine(&thought, &macd_r);
    let cos_adx = Similarity::cosine(&thought, &adx_r);

    assert!(
        cos_rsi > 0.3,
        "RSI rhythm should be present in bundle, got cosine={}",
        cos_rsi
    );
    assert!(
        cos_macd > 0.3,
        "MACD rhythm should be present in bundle, got cosine={}",
        cos_macd
    );
    assert!(
        cos_adx > 0.3,
        "ADX rhythm should be present in bundle, got cosine={}",
        cos_adx
    );
}

#[test]
fn capacity_100_pairs_still_distinguishable() {
    let vm = VectorManager::new(DIMS);
    let scalar = ScalarEncoder::new(DIMS);

    // Generate a long series — 103 candles → 101 trigrams → 100 pairs
    let long_rising: Vec<f64> = (0..103).map(|i| 0.30 + i as f64 * 0.005).collect();
    let long_falling: Vec<f64> = (0..103).map(|i| 0.80 - i as f64 * 0.005).collect();

    let rising_rhythm = indicator_rhythm(&vm, &scalar, "rsi", &long_rising);
    let falling_rhythm = indicator_rhythm(&vm, &scalar, "rsi", &long_falling);

    let cos = Similarity::cosine(&rising_rhythm, &falling_rhythm);
    assert!(
        cos < 0.3,
        "at capacity (100 pairs), rising vs falling should still be distinguishable, got cosine={}",
        cos
    );

    // Verify they're not degenerate (near-zero norm would mean the bundle collapsed)
    let self_cos = Similarity::cosine(&rising_rhythm, &rising_rhythm);
    assert!(
        (self_cos - 1.0).abs() < 1e-6,
        "self-cosine should be 1.0, got {}",
        self_cos
    );
}

#[test]
fn acceleration_vs_deceleration() {
    let vm = VectorManager::new(DIMS);
    let scalar = ScalarEncoder::new(DIMS);

    // Accelerating: deltas get larger
    let accelerating = vec![0.40, 0.42, 0.46, 0.52, 0.60, 0.70, 0.82];
    // Decelerating: deltas get smaller
    let decelerating = vec![0.40, 0.52, 0.62, 0.70, 0.76, 0.80, 0.82];

    let r_acc = indicator_rhythm(&vm, &scalar, "rsi", &accelerating);
    let r_dec = indicator_rhythm(&vm, &scalar, "rsi", &decelerating);

    let cos = Similarity::cosine(&r_acc, &r_dec);
    // Both rise from 0.40 to 0.82 — same start and end.
    // But the shape is different. The rhythm should distinguish them.
    assert!(
        cos < 0.7,
        "accelerating vs decelerating (same endpoints) should be distinguishable, got cosine={}",
        cos
    );
}
