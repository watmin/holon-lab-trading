/// prove_rhythm_with_subspace.rs — test indicator rhythms with a noise
/// subspace stripping the background. Real-ish data. Real subspace.
///
/// The question: can the noise subspace separate different market regimes
/// when the raw rhythm cosine is high?

use holon::kernel::primitives::Primitives;
use holon::kernel::scalar::{ScalarEncoder, ScalarMode};
use holon::kernel::similarity::Similarity;
use holon::kernel::vector::Vector;
use holon::kernel::vector_manager::VectorManager;
use holon::memory::OnlineSubspace;

const DIMS: usize = 10_000;

/// Encode one candle's indicator fact with thermometer.
fn encode_fact(
    vm: &VectorManager,
    scalar: &ScalarEncoder,
    name: &str,
    value: f64,
    prev: Option<f64>,
    value_min: f64,
    value_max: f64,
    delta_range: f64,
) -> Vector {
    let atom = vm.get_vector(name);
    let value_vec = scalar.encode(value, ScalarMode::Thermometer { min: value_min, max: value_max });
    let fact = Primitives::bind(&atom, &value_vec);

    match prev {
        None => fact,
        Some(prev_val) => {
            let delta_atom = vm.get_vector(&format!("{}-delta", name));
            let delta_vec = scalar.encode(
                value - prev_val,
                ScalarMode::Thermometer { min: -delta_range, max: delta_range },
            );
            let delta_fact = Primitives::bind(&delta_atom, &delta_vec);
            let refs = vec![&fact, &delta_fact];
            Primitives::bundle(&refs)
        }
    }
}

/// Build a rhythm from a series of values for one indicator.
fn indicator_rhythm(
    vm: &VectorManager,
    scalar: &ScalarEncoder,
    name: &str,
    values: &[f64],
    value_min: f64,
    value_max: f64,
    delta_range: f64,
) -> Vector {
    let facts: Vec<Vector> = values
        .iter()
        .enumerate()
        .map(|(i, &val)| {
            let prev = if i > 0 { Some(values[i - 1]) } else { None };
            encode_fact(vm, scalar, name, val, prev, value_min, value_max, delta_range)
        })
        .collect();

    let trigrams: Vec<Vector> = facts
        .windows(3)
        .map(|w| {
            let ab = Primitives::bind(&w[0], &Primitives::permute(&w[1], 1));
            Primitives::bind(&ab, &Primitives::permute(&w[2], 2))
        })
        .collect();

    let pairs: Vec<Vector> = trigrams
        .windows(2)
        .map(|w| Primitives::bind(&w[0], &w[1]))
        .collect();

    if pairs.is_empty() {
        return Vector::zeros(DIMS);
    }
    let refs: Vec<&Vector> = pairs.iter().collect();
    Primitives::bundle(&refs)
}

/// Build a multi-indicator rhythm (like the market observer's thought).
fn market_rhythm(
    vm: &VectorManager,
    scalar: &ScalarEncoder,
    rsi: &[f64],
    macd: &[f64],
    adx: &[f64],
    obv: &[f64],
) -> Vector {
    let r_rsi = indicator_rhythm(vm, scalar, "rsi", rsi, 0.0, 100.0, 10.0);
    let r_macd = indicator_rhythm(vm, scalar, "macd", macd, -50.0, 50.0, 20.0);
    let r_adx = indicator_rhythm(vm, scalar, "adx", adx, 0.0, 100.0, 10.0);
    let r_obv = indicator_rhythm(vm, scalar, "obv", obv, -2.0, 2.0, 1.0);
    let refs = vec![&r_rsi, &r_macd, &r_adx, &r_obv];
    Primitives::bundle(&refs)
}

/// Generate a noisy uptrend series for one indicator.
fn noisy_uptrend(start: f64, per_step: f64, noise: f64, len: usize, seed: u64) -> Vec<f64> {
    let mut rng_state = seed;
    let mut val = start;
    let mut out = Vec::with_capacity(len);
    for _ in 0..len {
        rng_state = rng_state.wrapping_mul(6364136223846793005).wrapping_add(1);
        let r = ((rng_state >> 33) as f64 / u32::MAX as f64) * 2.0 - 1.0;
        val += per_step + noise * r;
        out.push(val);
    }
    out
}

/// Generate a noisy downtrend series.
fn noisy_downtrend(start: f64, per_step: f64, noise: f64, len: usize, seed: u64) -> Vec<f64> {
    let mut rng_state = seed;
    let mut val = start;
    let mut out = Vec::with_capacity(len);
    for _ in 0..len {
        rng_state = rng_state.wrapping_mul(6364136223846793005).wrapping_add(1);
        let r = ((rng_state >> 33) as f64 / u32::MAX as f64) * 2.0 - 1.0;
        val -= per_step + noise * r;
        out.push(val);
    }
    out
}

/// Generate a choppy sideways series.
fn noisy_chop(center: f64, amplitude: f64, len: usize, seed: u64) -> Vec<f64> {
    let mut rng_state = seed;
    let mut out = Vec::with_capacity(len);
    for _ in 0..len {
        rng_state = rng_state.wrapping_mul(6364136223846793005).wrapping_add(1);
        let r = ((rng_state >> 33) as f64 / u32::MAX as f64) * 2.0 - 1.0;
        out.push(center + amplitude * r);
    }
    out
}

fn to_f64(v: &Vector) -> Vec<f64> {
    v.data().iter().map(|&x| x as f64).collect()
}

#[test]
fn subspace_separates_regimes() {
    let vm = VectorManager::new(DIMS);
    let scalar = ScalarEncoder::new(DIMS);
    let window_len = 50;

    // Generate many uptrend windows — these are the "normal" training data.
    let mut subspace = OnlineSubspace::new(DIMS, 32);

    println!("\n=== Training subspace on 200 uptrend windows ===");
    let mut training_residuals = Vec::new();
    for seed in 0..200u64 {
        let rsi = noisy_uptrend(40.0, 0.3, 0.5, window_len, seed * 7);
        let macd = noisy_uptrend(0.0, 0.2, 0.3, window_len, seed * 13);
        let adx = noisy_uptrend(20.0, 0.15, 0.3, window_len, seed * 17);
        let obv = noisy_uptrend(0.0, 0.02, 0.05, window_len, seed * 23);
        let rhythm = market_rhythm(&vm, &scalar, &rsi, &macd, &adx, &obv);
        let rhythm_f64 = to_f64(&rhythm);
        let residual = subspace.update(&rhythm_f64);
        training_residuals.push(residual);
    }
    let avg_training = training_residuals.iter().sum::<f64>() / training_residuals.len() as f64;
    println!("  avg training residual: {:.4}", avg_training);

    // Test: new uptrend windows (should be low residual — familiar)
    println!("\n=== Testing 50 new uptrend windows (should be familiar) ===");
    let mut uptrend_residuals = Vec::new();
    for seed in 500..550u64 {
        let rsi = noisy_uptrend(40.0, 0.3, 0.5, window_len, seed * 7);
        let macd = noisy_uptrend(0.0, 0.2, 0.3, window_len, seed * 13);
        let adx = noisy_uptrend(20.0, 0.15, 0.3, window_len, seed * 17);
        let obv = noisy_uptrend(0.0, 0.02, 0.05, window_len, seed * 23);
        let rhythm = market_rhythm(&vm, &scalar, &rsi, &macd, &adx, &obv);
        let rhythm_f64 = to_f64(&rhythm);
        let residual = subspace.residual(&rhythm_f64);
        uptrend_residuals.push(residual);
    }
    let avg_up = uptrend_residuals.iter().sum::<f64>() / uptrend_residuals.len() as f64;
    println!("  avg uptrend residual: {:.4}", avg_up);

    // Test: downtrend windows (should be high residual — anomalous)
    println!("\n=== Testing 50 downtrend windows (should be anomalous) ===");
    let mut downtrend_residuals = Vec::new();
    for seed in 500..550u64 {
        let rsi = noisy_downtrend(70.0, 0.3, 0.5, window_len, seed * 7);
        let macd = noisy_downtrend(10.0, 0.2, 0.3, window_len, seed * 13);
        let adx = noisy_uptrend(20.0, 0.15, 0.3, window_len, seed * 17); // ADX rises in trends, either direction
        let obv = noisy_downtrend(0.0, 0.02, 0.05, window_len, seed * 23);
        let rhythm = market_rhythm(&vm, &scalar, &rsi, &macd, &adx, &obv);
        let rhythm_f64 = to_f64(&rhythm);
        let residual = subspace.residual(&rhythm_f64);
        downtrend_residuals.push(residual);
    }
    let avg_down = downtrend_residuals.iter().sum::<f64>() / downtrend_residuals.len() as f64;
    println!("  avg downtrend residual: {:.4}", avg_down);

    // Test: choppy windows (should be high residual — different regime)
    println!("\n=== Testing 50 choppy windows (should be anomalous) ===");
    let mut chop_residuals = Vec::new();
    for seed in 500..550u64 {
        let rsi = noisy_chop(50.0, 10.0, window_len, seed * 7);
        let macd = noisy_chop(0.0, 5.0, window_len, seed * 13);
        let adx = noisy_downtrend(30.0, 0.1, 0.3, window_len, seed * 17); // ADX falling = no trend
        let obv = noisy_chop(0.0, 0.3, window_len, seed * 23);
        let rhythm = market_rhythm(&vm, &scalar, &rsi, &macd, &adx, &obv);
        let rhythm_f64 = to_f64(&rhythm);
        let residual = subspace.residual(&rhythm_f64);
        chop_residuals.push(residual);
    }
    let avg_chop = chop_residuals.iter().sum::<f64>() / chop_residuals.len() as f64;
    println!("  avg chop residual: {:.4}", avg_chop);

    // Summary
    println!("\n=== SUMMARY ===");
    println!("  uptrend (familiar):   residual={:.4}", avg_up);
    println!("  downtrend (novel):    residual={:.4}", avg_down);
    println!("  chop (novel):         residual={:.4}", avg_chop);
    println!("  separation down/up:   {:.2}x", avg_down / avg_up);
    println!("  separation chop/up:   {:.2}x", avg_chop / avg_up);

    // The subspace should separate: downtrend and chop should have
    // significantly higher residual than uptrend.
    assert!(
        avg_down > avg_up * 1.2,
        "downtrend should have higher residual than uptrend: down={:.4} up={:.4}",
        avg_down, avg_up
    );
    assert!(
        avg_chop > avg_up * 1.2,
        "chop should have higher residual than uptrend: chop={:.4} up={:.4}",
        avg_chop, avg_up
    );
}

#[test]
fn raw_cosine_vs_anomaly_cosine() {
    let vm = VectorManager::new(DIMS);
    let scalar = ScalarEncoder::new(DIMS);
    let window_len = 50;

    // Train subspace on uptrends
    let mut subspace = OnlineSubspace::new(DIMS, 32);
    for seed in 0..200u64 {
        let rsi = noisy_uptrend(40.0, 0.3, 0.5, window_len, seed * 7);
        let macd = noisy_uptrend(0.0, 0.2, 0.3, window_len, seed * 13);
        let adx = noisy_uptrend(20.0, 0.15, 0.3, window_len, seed * 17);
        let obv = noisy_uptrend(0.0, 0.02, 0.05, window_len, seed * 23);
        let rhythm = market_rhythm(&vm, &scalar, &rsi, &macd, &adx, &obv);
        subspace.update(&to_f64(&rhythm));
    }

    // One uptrend and one downtrend
    let up_rsi = noisy_uptrend(40.0, 0.3, 0.5, window_len, 9999);
    let up_macd = noisy_uptrend(0.0, 0.2, 0.3, window_len, 9998);
    let up_adx = noisy_uptrend(20.0, 0.15, 0.3, window_len, 9997);
    let up_obv = noisy_uptrend(0.0, 0.02, 0.05, window_len, 9996);
    let up_rhythm = market_rhythm(&vm, &scalar, &up_rsi, &up_macd, &up_adx, &up_obv);

    let dn_rsi = noisy_downtrend(70.0, 0.3, 0.5, window_len, 9999);
    let dn_macd = noisy_downtrend(10.0, 0.2, 0.3, window_len, 9998);
    let dn_adx = noisy_uptrend(20.0, 0.15, 0.3, window_len, 9997);
    let dn_obv = noisy_downtrend(0.0, 0.02, 0.05, window_len, 9996);
    let dn_rhythm = market_rhythm(&vm, &scalar, &dn_rsi, &dn_macd, &dn_adx, &dn_obv);

    // Raw cosine
    let raw_cos = Similarity::cosine(&up_rhythm, &dn_rhythm);

    // Anomaly cosine — strip the background, compare what's left
    let up_f64 = to_f64(&up_rhythm);
    let dn_f64 = to_f64(&dn_rhythm);
    let up_anomaly_f64 = subspace.anomalous_component(&up_f64);
    let dn_anomaly_f64 = subspace.anomalous_component(&dn_f64);
    let up_anomaly = Vector::from_f64(&up_anomaly_f64);
    let dn_anomaly = Vector::from_f64(&dn_anomaly_f64);
    let anomaly_cos = Similarity::cosine(&up_anomaly, &dn_anomaly);

    println!("\n=== RAW vs ANOMALY cosine ===");
    println!("  raw rhythm:   uptrend vs downtrend cosine={:.4}", raw_cos);
    println!("  anomaly:      uptrend vs downtrend cosine={:.4}", anomaly_cos);
    println!("  separation improvement: raw={:.4} → anomaly={:.4}", raw_cos, anomaly_cos);

    // The anomaly cosine should be LOWER than the raw cosine —
    // the subspace stripped the shared structure.
    assert!(
        anomaly_cos < raw_cos,
        "anomaly cosine should be lower than raw: anomaly={:.4} raw={:.4}",
        anomaly_cos, raw_cos
    );
}
