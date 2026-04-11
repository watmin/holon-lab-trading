/// Experiment: does range inflation destroy resolution?
///
/// Simulate: 1000 observations in [0.01, 0.04] (calm market),
/// then 10 outliers at [0.08, 0.12] (crash), then 1000 more
/// in [0.01, 0.04] (calm returns).
///
/// The discovered range inflates to [0.01, 0.12] and never contracts.
/// Does this destroy the resolution in the calm band where 99% of
/// observations live?

use holon::kernel::vector_manager::VectorManager;

const DIMS: usize = 10000;

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
            k, buckets: Vec::new(), range_min: 0.0, range_max: 0.0,
            default, all_obs: Vec::new(), initialized: false,
        }
    }

    fn rebuild_buckets(&mut self) {
        let width = (self.range_max - self.range_min) / self.k as f64;
        if width < 1e-15 { return; }
        self.buckets = (0..self.k)
            .map(|i| Bucket::new(self.range_min + (i as f64 + 0.5) * width))
            .collect();
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
            self.range_max = value + 1e-10;
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

    fn range(&self) -> (f64, f64) { (self.range_min, self.range_max) }
    fn width(&self) -> f64 { (self.range_max - self.range_min) / self.k as f64 }
}

#[test]
fn range_inflation_experiment() {
    let vm = make_vm();

    let mut discovered = DiscoveredBucketed::new(10, 0.02);

    // Phase 1: calm market — 1000 observations in [0.01, 0.04]
    for i in 0..1000 {
        let v = vm.get_vector(&format!("calm1_{}", i));
        let thought: Vec<f64> = v.data().iter().map(|&x| x as f64).collect();
        let value = 0.01 + 0.03 * (i as f64 / 1000.0);
        discovered.observe(&thought, value, 1.0);
    }

    eprintln!("\n=== RANGE INFLATION EXPERIMENT ===\n");
    eprintln!("  After phase 1 (calm, N=1000):");
    eprintln!("    range: [{:.4}, {:.4}]  width: {:.4}",
        discovered.range().0, discovered.range().1, discovered.width());
    for (i, b) in discovered.buckets.iter().enumerate() {
        eprintln!("    bucket {:>2}: center={:.4} count={:>4}", i, b.center, b.count);
    }

    // Phase 2: crash — 10 outliers at [0.08, 0.12]
    for i in 0..10 {
        let v = vm.get_vector(&format!("crash_{}", i));
        let thought: Vec<f64> = v.data().iter().map(|&x| x as f64).collect();
        let value = 0.08 + 0.04 * (i as f64 / 10.0);
        discovered.observe(&thought, value, 1.0);
    }

    eprintln!("\n  After phase 2 (crash, N=10 outliers):");
    eprintln!("    range: [{:.4}, {:.4}]  width: {:.4}",
        discovered.range().0, discovered.range().1, discovered.width());
    for (i, b) in discovered.buckets.iter().enumerate() {
        eprintln!("    bucket {:>2}: center={:.4} count={:>4}", i, b.center, b.count);
    }

    // Phase 3: calm returns — 1000 more in [0.01, 0.04]
    for i in 0..1000 {
        let v = vm.get_vector(&format!("calm2_{}", i));
        let thought: Vec<f64> = v.data().iter().map(|&x| x as f64).collect();
        let value = 0.01 + 0.03 * (i as f64 / 1000.0);
        discovered.observe(&thought, value, 1.0);
    }

    eprintln!("\n  After phase 3 (calm returns, N=1000 more):");
    eprintln!("    range: [{:.4}, {:.4}]  width: {:.4}",
        discovered.range().0, discovered.range().1, discovered.width());
    for (i, b) in discovered.buckets.iter().enumerate() {
        eprintln!("    bucket {:>2}: center={:.4} count={:>4}", i, b.center, b.count);
    }

    // The question: how many buckets are wasted on the [0.04, 0.12] space
    // where only 10 observations live vs [0.01, 0.04] where 2000 live?
    let calm_count: usize = discovered.buckets.iter()
        .filter(|b| b.center < 0.045)
        .map(|b| b.count)
        .sum();
    let crash_count: usize = discovered.buckets.iter()
        .filter(|b| b.center >= 0.045)
        .map(|b| b.count)
        .sum();
    let calm_buckets = discovered.buckets.iter().filter(|b| b.center < 0.045).count();
    let crash_buckets = discovered.buckets.iter().filter(|b| b.center >= 0.045).count();

    eprintln!("\n  Resolution analysis:");
    eprintln!("    calm zone  (<0.045): {} buckets, {} observations", calm_buckets, calm_count);
    eprintln!("    crash zone (>=0.045): {} buckets, {} observations", crash_buckets, crash_count);
    eprintln!("    {} observations in {} buckets = {:.0} obs/bucket (calm)",
        calm_count, calm_buckets, calm_count as f64 / calm_buckets.max(1) as f64);
    eprintln!("    {} observations in {} buckets = {:.0} obs/bucket (crash)",
        crash_count, crash_buckets, crash_count as f64 / crash_buckets.max(1) as f64);

    eprintln!();
    assert!(true);
}
