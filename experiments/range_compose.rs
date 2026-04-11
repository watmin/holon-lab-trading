/// Experiment: decay + rebalance composed.
///
/// Decay kills old weight. Rebalance moves boundaries to where weight lives.
/// Fixed K=10. Boundaries breathe. Resolution follows the living distribution.

use holon::kernel::vector_manager::VectorManager;

const DIMS: usize = 10000;
const K: usize = 10;

fn make_vm() -> VectorManager {
    VectorManager::with_seed(DIMS, 42)
}

struct Bucket {
    sums: Vec<f64>,
    weight_total: f64,
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

    fn is_alive(&self) -> bool {
        self.weight_total > 0.1
    }
}

struct ComposedBucketed {
    k: usize,
    buckets: Vec<Bucket>,
    range_min: f64,
    range_max: f64,
    default: f64,
    initialized: bool,
    decay_factor: f64,
    obs_since_rebalance: usize,
    rebalance_interval: usize,
}

impl ComposedBucketed {
    fn new(k: usize, default: f64, decay: f64, rebalance_interval: usize) -> Self {
        Self {
            k, buckets: (0..k).map(|_| Bucket::new()).collect(),
            range_min: 0.0, range_max: 0.0, default,
            initialized: false, decay_factor: decay,
            obs_since_rebalance: 0, rebalance_interval,
        }
    }

    fn bucket_width(&self) -> f64 {
        (self.range_max - self.range_min) / self.k as f64
    }

    fn find_bucket(&self, value: f64) -> usize {
        let w = self.bucket_width();
        if w < 1e-15 { return 0; }
        let idx = ((value - self.range_min) / w).floor() as usize;
        idx.min(self.k - 1)
    }

    fn observe(&mut self, thought: &[f64], value: f64, weight: f64) {
        // Decay all buckets
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

        // Periodic rebalance: contract range to where the weight lives
        self.obs_since_rebalance += 1;
        if self.obs_since_rebalance >= self.rebalance_interval {
            self.rebalance();
            self.obs_since_rebalance = 0;
        }
    }

    fn rebalance(&mut self) {
        // Find the effective range from alive buckets
        let alive: Vec<f64> = self.buckets.iter()
            .filter(|b| b.is_alive())
            .map(|b| b.center())
            .collect();

        if alive.len() < 2 { return; } // not enough data to rebalance

        let new_min = alive.iter().cloned().fold(f64::MAX, f64::min);
        let new_max = alive.iter().cloned().fold(f64::MIN, f64::max);

        if (new_max - new_min) < 1e-10 { return; }

        // Add margin (10%) so observations near edges don't fall off
        let margin = (new_max - new_min) * 0.1;
        let new_min = (new_min - margin).max(0.0);
        let new_max = new_max + margin;

        // Redistribute: collect alive bucket data, rebuild fresh buckets
        // Save the sums from alive buckets to redistribute
        let old_buckets: Vec<_> = std::mem::replace(
            &mut self.buckets, (0..self.k).map(|_| Bucket::new()).collect()
        );

        self.range_min = new_min;
        self.range_max = new_max;

        // Pour old bucket contents into new buckets.
        // Each old bucket's accumulated sums go to the new bucket closest
        // to the old bucket's center.
        for old in &old_buckets {
            if !old.is_alive() { continue; }
            let center = old.center();
            let new_idx = self.find_bucket(center);
            // Transfer the accumulated sums directly
            let new_b = &mut self.buckets[new_idx];
            for (ns, &os) in new_b.sums.iter_mut().zip(old.sums.iter()) {
                *ns += os;
            }
            new_b.weight_total += old.weight_total;
            new_b.value_sum += old.value_sum;
            new_b.value_weight += old.value_weight;
            new_b.count += old.count;
        }
    }

    fn query(&self, thought: &[f64]) -> f64 {
        let mut scored: Vec<(f64, f64)> = Vec::new();
        for b in &self.buckets {
            if !b.is_alive() { continue; }
            let dot = b.raw_dot(thought);
            if dot > 0.0 {
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
fn composed_breathing_experiment() {
    let vm = make_vm();

    // Rebalance every 100 observations. Decay 0.999 per observation.
    let mut composed = ComposedBucketed::new(K, 0.02, 0.999, 100);

    eprintln!("\n=== COMPOSED BREATHING EXPERIMENT ===");
    eprintln!("  K={}, decay=0.999, rebalance every 100 obs\n", K);

    // Phase 1: calm — 1000 obs in [0.01, 0.04]
    for i in 0..1000 {
        let v = vm.get_vector(&format!("calm1_{}", i));
        let thought: Vec<f64> = v.data().iter().map(|&x| x as f64).collect();
        let value = 0.01 + 0.03 * (i as f64 / 1000.0);
        composed.observe(&thought, value, 1.0);
    }

    eprintln!("  After phase 1 (calm, N=1000):");
    eprintln!("    range: [{:.4}, {:.4}]  width: {:.4}",
        composed.range_min, composed.range_max, composed.bucket_width());
    let alive1: Vec<_> = composed.buckets.iter().enumerate()
        .filter(|(_, b)| b.is_alive())
        .collect();
    for (i, b) in &alive1 {
        eprintln!("    bucket {:>2}: center={:.4} weight={:.1} count={}",
            i, b.center(), b.weight_total, b.count);
    }
    eprintln!("    alive: {}/{}", alive1.len(), K);

    // Phase 2: crash — 10 outliers at [0.08, 0.12]
    for i in 0..10 {
        let v = vm.get_vector(&format!("crash_{}", i));
        let thought: Vec<f64> = v.data().iter().map(|&x| x as f64).collect();
        let value = 0.08 + 0.04 * (i as f64 / 10.0);
        composed.observe(&thought, value, 1.0);
    }

    eprintln!("\n  After phase 2 (crash, N=10):");
    eprintln!("    range: [{:.4}, {:.4}]  width: {:.4}",
        composed.range_min, composed.range_max, composed.bucket_width());
    let alive2: Vec<_> = composed.buckets.iter().enumerate()
        .filter(|(_, b)| b.is_alive())
        .collect();
    for (i, b) in &alive2 {
        eprintln!("    bucket {:>2}: center={:.4} weight={:.1} count={}",
            i, b.center(), b.weight_total, b.count);
    }
    eprintln!("    alive: {}/{}", alive2.len(), K);

    // Phase 3: calm returns — 1000 obs in [0.01, 0.04]
    for i in 0..1000 {
        let v = vm.get_vector(&format!("calm2_{}", i));
        let thought: Vec<f64> = v.data().iter().map(|&x| x as f64).collect();
        let value = 0.01 + 0.03 * (i as f64 / 1000.0);
        composed.observe(&thought, value, 1.0);
    }

    eprintln!("\n  After phase 3 (calm returns, N=1000):");
    eprintln!("    range: [{:.4}, {:.4}]  width: {:.4}",
        composed.range_min, composed.range_max, composed.bucket_width());
    let alive3: Vec<_> = composed.buckets.iter().enumerate()
        .filter(|(_, b)| b.is_alive())
        .collect();
    for (i, b) in &alive3 {
        eprintln!("    bucket {:>2}: center={:.4} weight={:.1} count={}",
            i, b.center(), b.weight_total, b.count);
    }
    eprintln!("    alive: {}/{}", alive3.len(), K);

    // Did the range contract? Did the resolution recover?
    let calm_centers: Vec<f64> = alive3.iter()
        .filter(|(_, b)| b.center() >= 0.008 && b.center() <= 0.045)
        .map(|(_, b)| b.center())
        .collect();

    eprintln!("\n  Resolution recovery:");
    eprintln!("    calm centers: {:?}",
        calm_centers.iter().map(|c| format!("{:.4}", c)).collect::<Vec<_>>());
    eprintln!("    calm bucket count: {} / {} total alive", calm_centers.len(), alive3.len());
    eprintln!("    range contracted from inflated? {}",
        if composed.range_max < 0.10 { "YES" } else { "no — still inflated" });

    eprintln!();
    assert!(true);
}
