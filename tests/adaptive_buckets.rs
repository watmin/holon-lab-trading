/// Experiment: adaptive bucket count vs fixed K=10 vs brute-force.
///
/// The adaptive reckoner starts with K=1. When a bucket's observation
/// count exceeds a threshold AND the value variance within it is high,
/// it splits. K grows from experience.
///
/// Does adaptive K arrive at ~10? Does it find something better?

use holon::kernel::vector::Vector;
use holon::kernel::vector_manager::VectorManager;
use holon::memory::{ReckConfig, Reckoner};

use std::time::Instant;

const DIMS: usize = 10000;
const N_OBSERVATIONS: usize = 2000;
const N_QUERIES: usize = 100;

fn make_vm() -> VectorManager {
    VectorManager::with_seed(DIMS, 42)
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

/// A bucket that tracks its own statistics and knows when to split.
struct AdaptiveBucket {
    center: f64,
    sums: Vec<f64>,
    weight_total: f64,
    /// Track value stats for split decision
    value_sum: f64,
    value_sum_sq: f64,
    count: usize,
    /// Range this bucket covers
    range_min: f64,
    range_max: f64,
}

impl AdaptiveBucket {
    fn new(range_min: f64, range_max: f64) -> Self {
        Self {
            center: (range_min + range_max) / 2.0,
            sums: vec![0.0; DIMS],
            weight_total: 0.0,
            value_sum: 0.0,
            value_sum_sq: 0.0,
            count: 0,
            range_min,
            range_max,
        }
    }

    fn observe(&mut self, thought: &[f64], value: f64, weight: f64) {
        for (s, &v) in self.sums.iter_mut().zip(thought.iter()) {
            *s += v * weight;
        }
        self.weight_total += weight;
        self.value_sum += value;
        self.value_sum_sq += value * value;
        self.count += 1;
        // Update center to actual mean of observed values
        self.center = self.value_sum / self.count as f64;
    }

    fn prototype(&self) -> Option<Vec<f64>> {
        if self.weight_total < 1e-10 {
            return None;
        }
        let inv = 1.0 / self.weight_total;
        Some(self.sums.iter().map(|&s| s * inv).collect())
    }

    fn variance(&self) -> f64 {
        if self.count < 2 { return 0.0; }
        let mean = self.value_sum / self.count as f64;
        (self.value_sum_sq / self.count as f64) - mean * mean
    }

    fn width(&self) -> f64 {
        self.range_max - self.range_min
    }

    /// Should this bucket split? Enough data AND high variance relative to width.
    fn should_split(&self, min_count: usize) -> bool {
        if self.count < min_count { return false; }
        let std = self.variance().sqrt();
        // Split if the standard deviation is more than 25% of the bucket width
        std > self.width() * 0.25
    }
}

/// Adaptive bucketed reckoner: starts with K=1, splits when data says to.
struct AdaptiveReckoner {
    buckets: Vec<AdaptiveBucket>,
    default_value: f64,
    /// All observations stored temporarily for redistribution on split
    observations: Vec<(Vec<f64>, f64, f64)>, // (thought, value, weight)
    split_min_count: usize,
}

impl AdaptiveReckoner {
    fn new(default_value: f64, split_min_count: usize) -> Self {
        // Start with one bucket covering the entire possible range.
        // The range will be discovered from the first observations.
        Self {
            buckets: Vec::new(),
            default_value,
            observations: Vec::new(),
            split_min_count,
        }
    }

    fn find_bucket(&self, value: f64) -> Option<usize> {
        self.buckets.iter().position(|b| value >= b.range_min && value < b.range_max)
            .or_else(|| {
                // Value at or beyond the last bucket's max — goes in last bucket
                if !self.buckets.is_empty() && value >= self.buckets.last().unwrap().range_min {
                    Some(self.buckets.len() - 1)
                } else {
                    None
                }
            })
    }

    fn observe(&mut self, thought: &[f64], value: f64, weight: f64) {
        self.observations.push((thought.to_vec(), value, weight));

        if self.buckets.is_empty() {
            // First observation — create one bucket centered on it
            let margin = 0.01; // small initial range
            self.buckets.push(AdaptiveBucket::new(
                (value - margin).max(0.0),
                value + margin,
            ));
            self.buckets[0].observe(thought, value, weight);
            return;
        }

        // Expand range if needed
        let global_min = self.buckets.first().unwrap().range_min;
        let global_max = self.buckets.last().unwrap().range_max;
        if value < global_min {
            self.buckets[0].range_min = value;
        }
        if value >= global_max {
            self.buckets.last_mut().unwrap().range_max = value + 0.001;
        }

        // Find bucket and observe
        let idx = self.find_bucket(value).unwrap_or(0);
        self.buckets[idx].observe(thought, value, weight);

        // Check for splits
        self.maybe_split();
    }

    fn maybe_split(&mut self) {
        let mut split_idx = None;
        for (i, bucket) in self.buckets.iter().enumerate() {
            if bucket.should_split(self.split_min_count) {
                split_idx = Some(i);
                break;
            }
        }

        if let Some(idx) = split_idx {
            let old = &self.buckets[idx];
            let mid = (old.range_min + old.range_max) / 2.0;
            let range_min = old.range_min;
            let range_max = old.range_max;

            // Create two new buckets
            let left = AdaptiveBucket::new(range_min, mid);
            let right = AdaptiveBucket::new(mid, range_max);

            // Replace old bucket with two new ones
            self.buckets.splice(idx..=idx, vec![left, right]);

            // Redistribute ALL observations into the new bucket layout
            let obs = std::mem::take(&mut self.observations);
            // Reset all buckets
            for b in &mut self.buckets {
                b.sums = vec![0.0; DIMS];
                b.weight_total = 0.0;
                b.value_sum = 0.0;
                b.value_sum_sq = 0.0;
                b.count = 0;
            }
            // Replay
            for (thought, value, weight) in &obs {
                let bi = self.find_bucket(*value).unwrap_or(0);
                self.buckets[bi].observe(thought, *value, *weight);
            }
            self.observations = obs;
        }
    }

    fn query(&self, thought: &[f64]) -> f64 {
        if self.buckets.is_empty() {
            return self.default_value;
        }

        let mut scored: Vec<(f64, f64)> = Vec::new();
        for bucket in &self.buckets {
            if let Some(proto) = bucket.prototype() {
                let cos = cosine_f64(thought, &proto);
                if cos > 0.0 {
                    scored.push((cos, bucket.center));
                }
            }
        }
        if scored.is_empty() {
            return self.default_value;
        }
        scored.sort_by(|a, b| b.0.partial_cmp(&a.0).unwrap());
        let mut w_sum = 0.0;
        let mut v_sum = 0.0;
        for &(cos, center) in scored.iter().take(3) {
            w_sum += cos;
            v_sum += cos * center;
        }
        if w_sum < 1e-10 { scored[0].1 } else { v_sum / w_sum }
    }

    fn k(&self) -> usize {
        self.buckets.len()
    }
}

#[test]
fn adaptive_buckets_experiment() {
    let vm = make_vm();

    // Generate observations: same as bucket_sweep
    let observations: Vec<(Vec<f64>, f64)> = (0..N_OBSERVATIONS)
        .map(|i| {
            let v = vm.get_vector(&format!("obs_{}", i));
            let thought: Vec<f64> = v.data().iter().map(|&x| x as f64).collect();
            let t = (i as f64) / (N_OBSERVATIONS as f64);
            let value = 0.001 + 0.099 * (0.5 + 0.4 * (t * 7.0).sin());
            (thought, value)
        })
        .collect();

    let queries: Vec<Vec<f64>> = (0..N_QUERIES)
        .map(|i| {
            let v = vm.get_vector(&format!("query_{}", i));
            v.data().iter().map(|&x| x as f64).collect()
        })
        .collect();

    // Brute-force ground truth
    let mut brute = Reckoner::new("brute", DIMS, 500, ReckConfig::Continuous(0.02));
    for (thought, value) in &observations {
        let v = Vector::from_f64(thought);
        brute.observe_scalar(&v, *value, 1.0);
    }
    let ground_truth: Vec<f64> = queries.iter().map(|q| {
        let v = Vector::from_f64(q);
        brute.query(&v)
    }).collect();

    // Test different split thresholds to see how K evolves
    let split_counts = vec![10, 20, 30, 50, 75, 100, 150, 200];

    eprintln!("\n=== ADAPTIVE BUCKET EXPERIMENT ===");
    eprintln!("  N={}, D={}, queries={}\n", N_OBSERVATIONS, DIMS, N_QUERIES);
    eprintln!("  {:>10}  {:>6}  {:>10}  {:>10}  {:>10}",
        "min_split", "K", "mean_err", "max_err", "μs/query");
    eprintln!("  {}", "-".repeat(54));

    for &min_count in &split_counts {
        let mut adaptive = AdaptiveReckoner::new(0.02, min_count);
        for (thought, value) in &observations {
            adaptive.observe(thought, *value, 1.0);
        }

        // Log K evolution at checkpoints
        let final_k = adaptive.k();

        let mut errors = Vec::new();
        let t0 = Instant::now();
        for (i, q) in queries.iter().enumerate() {
            let val = adaptive.query(q);
            errors.push((val - ground_truth[i]).abs());
        }
        let us = t0.elapsed().as_micros();

        let mean_err: f64 = errors.iter().sum::<f64>() / errors.len() as f64;
        let max_err: f64 = errors.iter().cloned().fold(0.0, f64::max);
        let us_per = us as f64 / N_QUERIES as f64;

        eprintln!("  {:>10}  {:>6}  {:>10.6}  {:>10.6}  {:>10.1}",
            min_count, final_k, mean_err, max_err, us_per);
    }

    // Also show the K evolution over time for one setting
    eprintln!("\n  K evolution (min_split=50):");
    let mut adaptive = AdaptiveReckoner::new(0.02, 50);
    let checkpoints = vec![50, 100, 200, 500, 1000, 1500, 2000];
    let mut cp_idx = 0;
    for (i, (thought, value)) in observations.iter().enumerate() {
        adaptive.observe(thought, *value, 1.0);
        if cp_idx < checkpoints.len() && i + 1 == checkpoints[cp_idx] {
            eprintln!("    N={:>5}  K={}", i + 1, adaptive.k());
            cp_idx += 1;
        }
    }

    eprintln!();
    assert!(true);
}
