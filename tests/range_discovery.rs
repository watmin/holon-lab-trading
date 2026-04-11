/// Experiment: does the range need to be known upfront?
///
/// Compare two approaches:
/// 1. Fixed range [0.001, 0.10] — hardcoded, known from domain
/// 2. Discovered range — starts empty, grows from min/max of observations
///
/// Both use K=10. Same observations. Same queries. Compare answers.
/// If discovered range produces equivalent answers, the hardcoded range is magic.

use holon::kernel::vector::Vector;
use holon::kernel::vector_manager::VectorManager;

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

struct Bucket {
    sums: Vec<f64>,
    weight_total: f64,
    center: f64,
    count: usize,
}

impl Bucket {
    fn new(center: f64) -> Self {
        Self { sums: vec![0.0; DIMS], weight_total: 0.0, center, count: 0 }
    }

    fn observe(&mut self, thought: &[f64], weight: f64) {
        for (s, &v) in self.sums.iter_mut().zip(thought.iter()) {
            *s += v * weight;
        }
        self.weight_total += weight;
        self.count += 1;
    }

    fn raw_dot(&self, thought: &[f64]) -> f64 {
        self.sums.iter().zip(thought.iter()).map(|(&s, &t)| s * t).sum()
    }
}

struct FixedBucketed {
    buckets: Vec<Bucket>,
    range_min: f64,
    width: f64,
    default: f64,
}

impl FixedBucketed {
    fn new(k: usize, min: f64, max: f64, default: f64) -> Self {
        let width = (max - min) / k as f64;
        let buckets = (0..k).map(|i| Bucket::new(min + (i as f64 + 0.5) * width)).collect();
        Self { buckets, range_min: min, width, default }
    }

    fn observe(&mut self, thought: &[f64], value: f64, weight: f64) {
        let idx = ((value - self.range_min) / self.width).floor() as usize;
        let idx = idx.min(self.buckets.len() - 1);
        self.buckets[idx].observe(thought, weight);
    }

    fn query(&self, thought: &[f64]) -> f64 {
        let mut scored: Vec<(f64, f64)> = Vec::new();
        for b in &self.buckets {
            if b.count == 0 { continue; }
            let dot = b.raw_dot(thought);
            if dot > 0.0 { scored.push((dot, b.center)); }
        }
        if scored.is_empty() { return self.default; }
        scored.sort_by(|a, b| b.0.partial_cmp(&a.0).unwrap());
        let mut w = 0.0;
        let mut v = 0.0;
        for &(d, c) in scored.iter().take(3) { w += d; v += d * c; }
        if w < 1e-10 { self.default } else { v / w }
    }
}

struct DiscoveredBucketed {
    k: usize,
    buckets: Vec<Bucket>,
    range_min: f64,
    range_max: f64,
    default: f64,
    all_obs: Vec<(Vec<f64>, f64, f64)>,
    initialized: bool,
}

impl DiscoveredBucketed {
    fn new(k: usize, default: f64) -> Self {
        Self {
            k,
            buckets: Vec::new(),
            range_min: 0.0,
            range_max: 0.0,
            default,
            all_obs: Vec::new(),
            initialized: false,
        }
    }

    fn rebuild_buckets(&mut self) {
        let width = (self.range_max - self.range_min) / self.k as f64;
        if width < 1e-15 { return; }
        self.buckets = (0..self.k)
            .map(|i| Bucket::new(self.range_min + (i as f64 + 0.5) * width))
            .collect();
        // Replay all observations into new buckets
        for (thought, value, weight) in &self.all_obs {
            let idx = ((*value - self.range_min) / width).floor() as usize;
            let idx = idx.min(self.k - 1);
            self.buckets[idx].observe(thought, *weight);
        }
    }

    fn observe(&mut self, thought: &[f64], value: f64, weight: f64) {
        self.all_obs.push((thought.to_vec(), value, weight));

        if !self.initialized {
            self.range_min = value;
            self.range_max = value + 1e-10; // avoid zero width
            self.initialized = true;
            self.rebuild_buckets();
            return;
        }

        let mut changed = false;
        if value < self.range_min { self.range_min = value; changed = true; }
        if value > self.range_max { self.range_max = value; changed = true; }

        if changed {
            self.rebuild_buckets();
        } else {
            let width = (self.range_max - self.range_min) / self.k as f64;
            let idx = ((value - self.range_min) / width).floor() as usize;
            let idx = idx.min(self.k - 1);
            self.buckets[idx].observe(thought, weight);
        }
    }

    fn query(&self, thought: &[f64]) -> f64 {
        if self.buckets.is_empty() { return self.default; }
        let mut scored: Vec<(f64, f64)> = Vec::new();
        for b in &self.buckets {
            if b.count == 0 { continue; }
            let dot = b.raw_dot(thought);
            if dot > 0.0 { scored.push((dot, b.center)); }
        }
        if scored.is_empty() { return self.default; }
        scored.sort_by(|a, b| b.0.partial_cmp(&a.0).unwrap());
        let mut w = 0.0;
        let mut v = 0.0;
        for &(d, c) in scored.iter().take(3) { w += d; v += d * c; }
        if w < 1e-10 { self.default } else { v / w }
    }

    fn range(&self) -> (f64, f64) {
        (self.range_min, self.range_max)
    }
}

#[test]
fn range_discovery_experiment() {
    let vm = make_vm();

    // Same observations as bucket_sweep
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

    // Track the actual min/max of observed values
    let obs_min = observations.iter().map(|(_, v)| *v).fold(f64::MAX, f64::min);
    let obs_max = observations.iter().map(|(_, v)| *v).fold(f64::MIN, f64::max);

    // Fixed range
    let mut fixed = FixedBucketed::new(10, 0.001, 0.10, 0.02);
    for (thought, value) in &observations {
        fixed.observe(thought, *value, 1.0);
    }

    // Discovered range
    let mut discovered = DiscoveredBucketed::new(10, 0.02);
    for (thought, value) in &observations {
        discovered.observe(thought, *value, 1.0);
    }

    eprintln!("\n=== RANGE DISCOVERY EXPERIMENT ===");
    eprintln!("  N={}, K=10, D={}", N_OBSERVATIONS, DIMS);
    eprintln!("\n  Observed scalar range: [{:.6}, {:.6}]", obs_min, obs_max);
    eprintln!("  Fixed range:           [0.001000, 0.100000]");
    eprintln!("  Discovered range:      [{:.6}, {:.6}]", discovered.range().0, discovered.range().1);
    eprintln!("  Fixed bucket width:    {:.6}", 0.099 / 10.0);
    eprintln!("  Discovered width:      {:.6}", (discovered.range().1 - discovered.range().0) / 10.0);

    // Compare query results
    let mut diffs = Vec::new();
    for q in &queries {
        let f = fixed.query(q);
        let d = discovered.query(q);
        diffs.push((f - d).abs());
    }

    let mean_diff: f64 = diffs.iter().sum::<f64>() / diffs.len() as f64;
    let max_diff: f64 = diffs.iter().cloned().fold(0.0, f64::max);

    eprintln!("\n  Fixed vs Discovered query diff:");
    eprintln!("    mean: {:.6}", mean_diff);
    eprintln!("    max:  {:.6}", max_diff);

    // Show bucket occupancy for both
    eprintln!("\n  Bucket occupancy (fixed range):");
    for (i, b) in fixed.buckets.iter().enumerate() {
        eprintln!("    bucket {:>2}: center={:.4} count={:>4}", i, b.center, b.count);
    }

    eprintln!("\n  Bucket occupancy (discovered range):");
    for (i, b) in discovered.buckets.iter().enumerate() {
        eprintln!("    bucket {:>2}: center={:.4} count={:>4}", i, b.center, b.count);
    }

    eprintln!();
    assert!(true);
}
