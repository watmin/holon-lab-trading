/// Experiment: bucket count vs interpolation error.
///
/// Builds a continuous reckoner with N observations (brute-force ground truth).
/// Then builds bucketed approximations at K=2, 5, 10, 15, 20, 30, 50.
/// Queries both with 100 test thoughts. Measures the error.
///
/// Reports: K, mean_error, max_error, cost_ratio, query_us
/// The curve reveals the optimal K.

use holon::kernel::primitives::Primitives;
use holon::kernel::vector::Vector;
use holon::kernel::vector_manager::VectorManager;
use holon::memory::{ReckConfig, Reckoner};

use std::time::Instant;

const DIMS: usize = 10000;
const N_OBSERVATIONS: usize = 2000;
const N_QUERIES: usize = 100;
const SCALAR_MIN: f64 = 0.001;
const SCALAR_MAX: f64 = 0.10;

fn make_vm() -> VectorManager {
    VectorManager::with_seed(DIMS, 42)
}

/// A single bucket: accumulates thoughts as a running sum + count.
struct Bucket {
    center: f64,
    sums: Vec<f64>,
    weight_total: f64,
}

impl Bucket {
    fn new(center: f64) -> Self {
        Self {
            center,
            sums: vec![0.0; DIMS],
            weight_total: 0.0,
        }
    }

    fn observe(&mut self, thought: &[f64], weight: f64) {
        for (s, &v) in self.sums.iter_mut().zip(thought.iter()) {
            *s += v * weight;
        }
        self.weight_total += weight;
    }

    fn prototype(&self) -> Option<Vec<f64>> {
        if self.weight_total < 1e-10 {
            return None;
        }
        let inv = 1.0 / self.weight_total;
        Some(self.sums.iter().map(|&s| s * inv).collect())
    }
}

/// Bucketed reckoner: K buckets over [min, max].
struct BucketedReckoner {
    buckets: Vec<Bucket>,
    min: f64,
    width: f64,
}

impl BucketedReckoner {
    fn new(k: usize, min: f64, max: f64) -> Self {
        let width = (max - min) / k as f64;
        let buckets = (0..k)
            .map(|i| Bucket::new(min + (i as f64 + 0.5) * width))
            .collect();
        Self { buckets, min, width }
    }

    fn observe(&mut self, thought: &[f64], value: f64, weight: f64) {
        let idx = ((value - self.min) / self.width).floor() as usize;
        let idx = idx.min(self.buckets.len() - 1);
        self.buckets[idx].observe(thought, weight);
    }

    fn query(&self, thought: &[f64]) -> f64 {
        // Cosine against each bucket's prototype. Soft-weight top-3.
        let mut scored: Vec<(f64, f64)> = Vec::new(); // (cosine, center)
        for bucket in &self.buckets {
            if let Some(proto) = bucket.prototype() {
                let cos = cosine_f64(thought, &proto);
                if cos > 0.0 {
                    scored.push((cos, bucket.center));
                }
            }
        }
        if scored.is_empty() {
            return (self.min + (self.buckets.len() as f64 * self.width) / 2.0);
        }
        scored.sort_by(|a, b| b.0.partial_cmp(&a.0).unwrap());
        let top = scored.iter().take(3);
        let mut w_sum = 0.0;
        let mut v_sum = 0.0;
        for &(cos, center) in top.clone() {
            w_sum += cos;
            v_sum += cos * center;
        }
        if w_sum < 1e-10 {
            scored[0].1
        } else {
            v_sum / w_sum
        }
    }
}

fn cosine_f64(a: &[f64], b: &[f64]) -> f64 {
    let mut dot = 0.0;
    let mut na = 0.0;
    let mut nb = 0.0;
    for (&x, &y) in a.iter().zip(b.iter()) {
        dot += x * y;
        na += x * x;
        nb += y * y;
    }
    let denom = na.sqrt() * nb.sqrt();
    if denom < 1e-10 { 0.0 } else { dot / denom }
}

#[test]
fn bucket_sweep() {
    let vm = make_vm();

    // Generate N observations: random thought + scalar value in [min, max]
    let observations: Vec<(Vec<f64>, f64)> = (0..N_OBSERVATIONS)
        .map(|i| {
            let v = vm.get_vector(&format!("obs_{}", i));
            let thought: Vec<f64> = v.data().iter().map(|&x| x as f64).collect();
            // Scalar: spread across the range with some clustering
            let t = (i as f64) / (N_OBSERVATIONS as f64);
            let value = SCALAR_MIN + (SCALAR_MAX - SCALAR_MIN) * (0.5 + 0.4 * (t * 7.0).sin());
            (thought, value)
        })
        .collect();

    // Generate N test queries
    let queries: Vec<Vec<f64>> = (0..N_QUERIES)
        .map(|i| {
            let v = vm.get_vector(&format!("query_{}", i));
            v.data().iter().map(|&x| x as f64).collect()
        })
        .collect();

    // Build brute-force reckoner (ground truth)
    let mut brute = Reckoner::new("brute", DIMS, 500, ReckConfig::Continuous(0.02));
    for (thought, value) in &observations {
        let v = Vector::from_f64(thought);
        brute.observe_scalar(&v, *value, 1.0);
    }

    // Query brute-force for ground truth
    let ground_truth: Vec<f64> = queries
        .iter()
        .map(|q| {
            let v = Vector::from_f64(q);
            brute.query(&v)
        })
        .collect();

    // Time the brute-force queries
    let t0 = Instant::now();
    for q in &queries {
        let v = Vector::from_f64(q);
        let _ = brute.query(&v);
    }
    let brute_us = t0.elapsed().as_micros();

    // Sweep K values
    let ks: Vec<usize> = (2..=30).collect();

    eprintln!("\n=== BUCKET SWEEP: N={}, D={}, queries={} ===", N_OBSERVATIONS, DIMS, N_QUERIES);
    eprintln!("  brute-force: {}μs for {} queries ({:.1}μs/query)\n",
        brute_us, N_QUERIES, brute_us as f64 / N_QUERIES as f64);
    eprintln!("  {:>4}  {:>10}  {:>10}  {:>10}  {:>12}  {:>10}",
        "K", "mean_err", "max_err", "μs/query", "speedup", "optimal_K?");
    eprintln!("  {}",  "-".repeat(62));

    let optimal_k = (4.0 * N_OBSERVATIONS as f64).powf(1.0 / 3.0);

    for k in &ks {
        // Build bucketed reckoner with same observations
        let mut bucketed = BucketedReckoner::new(*k, SCALAR_MIN, SCALAR_MAX);
        for (thought, value) in &observations {
            bucketed.observe(thought, *value, 1.0);
        }

        // Query and measure error vs ground truth
        let mut errors = Vec::with_capacity(N_QUERIES);
        for (i, q) in queries.iter().enumerate() {
            let bucketed_val = bucketed.query(q);
            errors.push((bucketed_val - ground_truth[i]).abs());
        }

        let mean_err: f64 = errors.iter().sum::<f64>() / errors.len() as f64;
        let max_err: f64 = errors.iter().cloned().fold(0.0, f64::max);

        // Time the bucketed queries
        let t0 = Instant::now();
        for q in &queries {
            let _ = bucketed.query(q);
        }
        let bucket_us = t0.elapsed().as_micros();
        let us_per_query = bucket_us as f64 / N_QUERIES as f64;
        let speedup = brute_us as f64 / bucket_us.max(1) as f64;

        let near_optimal = if (*k as f64 - optimal_k).abs() < optimal_k * 0.3 { "<--" } else { "" };

        eprintln!("  {:>4}  {:>10.6}  {:>10.6}  {:>10.1}  {:>10.1}x  {:>10}",
            k, mean_err, max_err, us_per_query, speedup, near_optimal);
    }

    eprintln!("\n  theoretical optimal K = (4N)^(1/3) = {:.1}", optimal_k);
    eprintln!("  brute-force cost grows with N. bucketed cost is constant.\n");

    // The test passes — this is an experiment, not an assertion
    assert!(true);
}
