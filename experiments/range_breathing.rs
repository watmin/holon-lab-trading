/// Experiment: do decayed bucket centers self-heal after range inflation?
///
/// Each bucket tracks a running weighted center: the decayed mean of
/// observed values. The center drifts toward where the CURRENT weight is.
/// After a crash, crash buckets decay. Their centers are irrelevant.
/// Calm buckets stay strong. Their centers concentrate.
///
/// Does this recover the resolution lost to inflation?

use holon::kernel::vector_manager::VectorManager;

const DIMS: usize = 10000;

fn make_vm() -> VectorManager {
    VectorManager::with_seed(DIMS, 42)
}

struct Bucket {
    sums: Vec<f64>,
    weight_total: f64,
    /// Running weighted center — drifts with observations
    value_sum: f64,
    value_weight: f64,
    count: usize,
}

impl Bucket {
    fn new() -> Self {
        Self { sums: vec![0.0; DIMS], weight_total: 0.0,
               value_sum: 0.0, value_weight: 0.0, count: 0 }
    }

    fn observe(&mut self, thought: &[f64], value: f64, weight: f64) {
        for (s, &v) in self.sums.iter_mut().zip(thought.iter()) {
            *s += v * weight;
        }
        self.weight_total += weight;
        self.value_sum += value * weight;
        self.value_weight += weight;
        self.count += 1;
    }

    fn decay(&mut self, factor: f64) {
        for s in self.sums.iter_mut() { *s *= factor; }
        self.weight_total *= factor;
        self.value_sum *= factor;
        self.value_weight *= factor;
    }

    fn center(&self) -> f64 {
        if self.value_weight < 1e-10 { 0.0 }
        else { self.value_sum / self.value_weight }
    }

    fn raw_dot(&self, thought: &[f64]) -> f64 {
        self.sums.iter().zip(thought.iter()).map(|(&s, &t)| s * t).sum()
    }

    fn effective_weight(&self) -> f64 {
        self.weight_total
    }
}

struct BreathingBucketed {
    k: usize,
    buckets: Vec<Bucket>,
    range_min: f64,
    range_max: f64,
    default: f64,
    initialized: bool,
    decay_factor: f64,
}

impl BreathingBucketed {
    fn new(k: usize, default: f64, decay: f64) -> Self {
        Self {
            k, buckets: (0..k).map(|_| Bucket::new()).collect(),
            range_min: 0.0, range_max: 0.0, default,
            initialized: false, decay_factor: decay,
        }
    }

    fn find_bucket(&self, value: f64) -> usize {
        let width = (self.range_max - self.range_min) / self.k as f64;
        if width < 1e-15 { return 0; }
        let idx = ((value - self.range_min) / width).floor() as usize;
        idx.min(self.k - 1)
    }

    fn observe(&mut self, thought: &[f64], value: f64, weight: f64) {
        // Decay all buckets first — every observation triggers a tick of decay
        for b in &mut self.buckets {
            b.decay(self.decay_factor);
        }

        if !self.initialized {
            self.range_min = value - 0.001;
            self.range_max = value + 0.001;
            self.initialized = true;
        }

        // Expand range if needed
        if value < self.range_min { self.range_min = value; }
        if value > self.range_max { self.range_max = value + 1e-10; }

        let idx = self.find_bucket(value);
        self.buckets[idx].observe(thought, value, weight);
    }

    fn query(&self, thought: &[f64]) -> f64 {
        let mut scored: Vec<(f64, f64)> = Vec::new();
        for b in &self.buckets {
            if b.effective_weight() < 1e-10 { continue; }
            let dot = b.raw_dot(thought);
            if dot > 0.0 {
                // Use the DRIFTED center, not the grid center
                scored.push((dot, b.center()));
            }
        }
        if scored.is_empty() { return self.default; }
        scored.sort_by(|a, b| b.0.partial_cmp(&a.0).unwrap());
        let mut w = 0.0;
        let mut v = 0.0;
        for &(d, c) in scored.iter().take(3) { w += d; v += d * c; }
        if w < 1e-10 { self.default } else { v / w }
    }
}

#[test]
fn range_breathing_experiment() {
    let vm = make_vm();

    // Decay factor: 0.999 per observation. After 1000 obs, old weight = 0.999^1000 ≈ 0.37.
    // After 2000 obs, old weight = 0.999^2000 ≈ 0.14. Fades but doesn't vanish.
    let mut breathing = BreathingBucketed::new(10, 0.02, 0.999);

    // Phase 1: calm — 1000 obs in [0.01, 0.04]
    for i in 0..1000 {
        let v = vm.get_vector(&format!("calm1_{}", i));
        let thought: Vec<f64> = v.data().iter().map(|&x| x as f64).collect();
        let value = 0.01 + 0.03 * (i as f64 / 1000.0);
        breathing.observe(&thought, value, 1.0);
    }

    eprintln!("\n=== RANGE BREATHING EXPERIMENT ===\n");
    eprintln!("  After phase 1 (calm, N=1000):");
    eprintln!("    range: [{:.4}, {:.4}]", breathing.range_min, breathing.range_max);
    let active1: Vec<_> = breathing.buckets.iter().enumerate()
        .filter(|(_, b)| b.effective_weight() > 0.1)
        .map(|(i, b)| (i, b.center(), b.effective_weight(), b.count))
        .collect();
    for (i, c, w, n) in &active1 {
        eprintln!("    bucket {:>2}: center={:.4} weight={:.1} count={}", i, c, w, n);
    }
    eprintln!("    active buckets: {}", active1.len());

    // Phase 2: crash — 10 outliers at [0.08, 0.12]
    for i in 0..10 {
        let v = vm.get_vector(&format!("crash_{}", i));
        let thought: Vec<f64> = v.data().iter().map(|&x| x as f64).collect();
        let value = 0.08 + 0.04 * (i as f64 / 10.0);
        breathing.observe(&thought, value, 1.0);
    }

    eprintln!("\n  After phase 2 (crash, N=10):");
    eprintln!("    range: [{:.4}, {:.4}]", breathing.range_min, breathing.range_max);
    let active2: Vec<_> = breathing.buckets.iter().enumerate()
        .filter(|(_, b)| b.effective_weight() > 0.1)
        .map(|(i, b)| (i, b.center(), b.effective_weight(), b.count))
        .collect();
    for (i, c, w, n) in &active2 {
        eprintln!("    bucket {:>2}: center={:.4} weight={:.1} count={}", i, c, w, n);
    }
    eprintln!("    active buckets: {}", active2.len());

    // Phase 3: calm returns — 1000 obs in [0.01, 0.04]
    for i in 0..1000 {
        let v = vm.get_vector(&format!("calm2_{}", i));
        let thought: Vec<f64> = v.data().iter().map(|&x| x as f64).collect();
        let value = 0.01 + 0.03 * (i as f64 / 1000.0);
        breathing.observe(&thought, value, 1.0);
    }

    eprintln!("\n  After phase 3 (calm returns, N=1000):");
    eprintln!("    range: [{:.4}, {:.4}]", breathing.range_min, breathing.range_max);
    let active3: Vec<_> = breathing.buckets.iter().enumerate()
        .filter(|(_, b)| b.effective_weight() > 0.1)
        .map(|(i, b)| (i, b.center(), b.effective_weight(), b.count))
        .collect();
    for (i, c, w, n) in &active3 {
        eprintln!("    bucket {:>2}: center={:.4} weight={:.1} count={}", i, c, w, n);
    }
    eprintln!("    active buckets: {}", active3.len());

    // The question: did the crash buckets decay away? Are the active
    // centers concentrated in the calm zone?
    let calm_centers: Vec<f64> = active3.iter()
        .filter(|(_, c, _, _)| *c < 0.045)
        .map(|(_, c, _, _)| *c)
        .collect();
    let crash_centers: Vec<f64> = active3.iter()
        .filter(|(_, c, _, _)| *c >= 0.045)
        .map(|(_, c, _, _)| *c)
        .collect();

    eprintln!("\n  Resolution recovery:");
    eprintln!("    calm centers:  {:?}", calm_centers.iter().map(|c| format!("{:.4}", c)).collect::<Vec<_>>());
    eprintln!("    crash centers: {:?}", crash_centers.iter().map(|c| format!("{:.4}", c)).collect::<Vec<_>>());
    eprintln!("    calm center count: {} (want ~10)", calm_centers.len());
    eprintln!("    crash center count: {} (want ~0)", crash_centers.len());

    eprintln!();
    assert!(true);
}
