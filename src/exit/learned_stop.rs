//! Learned trailing stop — nearest neighbor regression on (thought, distance) pairs.
//!
//! No bins. No buckets. No discretization. Continuous.
//! Store (thought_vector, optimal_distance) pairs from resolved trades.
//! Query: given this thought right now, what distance?
//! Answer: weighted average of nearest neighbors' distances.

use holon::{Vector, Similarity};

/// One learned data point: a thought and the optimal distance at that thought.
struct LearnedPair {
    thought: Vector,
    distance: f64,
    weight: f64,  // residue amount — how much grace this distance produced
}

/// Nearest neighbor regression over (thought, distance) pairs.
/// The interface: "given this thought, what distance?"
pub struct LearnedStop {
    pairs: Vec<LearnedPair>,
    max_pairs: usize,
    default_distance: f64,
}

impl LearnedStop {
    /// Create with a default distance (used when no pairs exist yet).
    /// The default is the ignorance state. It gets replaced by experience.
    pub fn new(max_pairs: usize, default_distance: f64) -> Self {
        Self {
            pairs: Vec::new(),
            max_pairs,
            default_distance,
        }
    }

    /// Store a learned pair from a resolved trade.
    /// `thought`: the observer's thought at entry time.
    /// `optimal_distance`: computed from hindsight (compute_optimal_distance).
    /// `weight`: residue amount — how much grace this distance produced.
    pub fn observe(&mut self, thought: Vector, optimal_distance: f64, weight: f64) {
        self.pairs.push(LearnedPair {
            thought,
            distance: optimal_distance,
            weight: weight.max(0.01),
        });

        // Cap the pairs — oldest evicted (ring buffer behavior)
        if self.pairs.len() > self.max_pairs {
            self.pairs.remove(0);
        }
    }

    /// Given this thought right now, what distance?
    /// Weighted average of nearest neighbors' distances.
    /// Weights: cosine similarity × residue weight.
    pub fn recommended_distance(&self, current_thought: &Vector) -> f64 {
        if self.pairs.is_empty() {
            return self.default_distance;
        }

        let mut weighted_sum = 0.0f64;
        let mut weight_total = 0.0f64;

        for pair in &self.pairs {
            let cos = Similarity::cosine(current_thought, &pair.thought);
            // Only consider positively similar thoughts
            if cos <= 0.0 { continue; }
            let w = cos * pair.weight;
            weighted_sum += pair.distance * w;
            weight_total += w;
        }

        if weight_total < 1e-10 {
            self.default_distance
        } else {
            weighted_sum / weight_total
        }
    }

    pub fn pair_count(&self) -> usize { self.pairs.len() }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_returns_default() {
        let ls = LearnedStop::new(1000, 0.015);
        let thought = Vector::zeros(64);
        assert!((ls.recommended_distance(&thought) - 0.015).abs() < 1e-10);
    }

    #[test]
    fn single_pair_returns_its_distance() {
        let mut ls = LearnedStop::new(1000, 0.015);
        let vm = holon::VectorManager::new(64);
        let thought = vm.get_vector("test-thought");
        ls.observe(thought.clone(), 0.008, 1.0);

        // Query with the same thought — should return ~0.008
        let d = ls.recommended_distance(&thought);
        assert!((d - 0.008).abs() < 0.001,
            "same thought should return its distance: {}", d);
    }

    #[test]
    fn similar_thoughts_blend() {
        let mut ls = LearnedStop::new(1000, 0.015);
        let vm = holon::VectorManager::new(1000);

        // Two similar thoughts with different distances
        let base = vm.get_vector("base");
        let variant = vm.get_vector("base"); // same atom = same vector
        ls.observe(base.clone(), 0.01, 1.0);
        ls.observe(variant.clone(), 0.02, 1.0);

        let d = ls.recommended_distance(&base);
        eprintln!("blended distance: {:.4}", d);
        // Should be between 0.01 and 0.02
        assert!(d >= 0.009 && d <= 0.021,
            "similar thoughts should blend: {}", d);
    }

    #[test]
    fn dissimilar_thoughts_dont_influence() {
        let mut ls = LearnedStop::new(1000, 0.015);
        let vm = holon::VectorManager::new(10000);

        let thought_a = vm.get_vector("regime-trending");
        let thought_b = vm.get_vector("regime-choppy");

        // Trending regime wants tight stops
        ls.observe(thought_a.clone(), 0.005, 10.0);
        // Choppy regime wants wide stops
        ls.observe(thought_b.clone(), 0.03, 10.0);

        // Query with trending thought — should return near 0.005
        let d_trending = ls.recommended_distance(&thought_a);
        // Query with choppy thought — should return near 0.03
        let d_choppy = ls.recommended_distance(&thought_b);

        eprintln!("trending: {:.4}, choppy: {:.4}", d_trending, d_choppy);

        // At 10000 dims, random vectors are nearly orthogonal
        // So each query should strongly prefer its own pair
        assert!(d_trending < d_choppy,
            "trending should want tighter stop than choppy: {} vs {}", d_trending, d_choppy);
    }

    #[test]
    fn weight_matters() {
        let mut ls = LearnedStop::new(1000, 0.015);
        let vm = holon::VectorManager::new(64);

        let thought = vm.get_vector("same");
        // Heavy weight on tight stop
        ls.observe(thought.clone(), 0.005, 100.0);
        // Light weight on wide stop
        ls.observe(thought.clone(), 0.04, 1.0);

        let d = ls.recommended_distance(&thought);
        eprintln!("weighted: {:.4} (should be near 0.005, heavily weighted)", d);
        assert!(d < 0.01, "heavy weight should dominate: {}", d);
    }

    #[test]
    fn contextual_distance_from_optimal() {
        // The full loop: create varied market shapes, compute optimal distances,
        // store with thought vectors, query back by thought.
        use crate::exit::optimal::compute_optimal_distance;

        let vm = holon::VectorManager::new(10000);
        let mut ls = LearnedStop::new(5000, 0.015);

        // Trending regime: tight stops work
        let trending_thought = vm.get_vector("trending-regime");
        for _ in 0..50 {
            let entry = 50000.0;
            let closes: Vec<f64> = (0..50).map(|j| entry + j as f64 * 100.0).collect();
            if let Some(opt) = compute_optimal_distance(&closes, entry, 100, 0.05) {
                ls.observe(trending_thought.clone(), opt.distance_pct, opt.residue.abs().max(0.01));
            }
        }

        // Choppy regime: wide stops work
        let choppy_thought = vm.get_vector("choppy-regime");
        for _ in 0..50 {
            let entry = 50000.0;
            let closes: Vec<f64> = (0..50).map(|j| {
                let noise = if j % 3 == 0 { -500.0 } else { 200.0 };
                entry + j as f64 * 20.0 + noise
            }).collect();
            if let Some(opt) = compute_optimal_distance(&closes, entry, 100, 0.05) {
                ls.observe(choppy_thought.clone(), opt.distance_pct, opt.residue.abs().max(0.01));
            }
        }

        // Query: trending thought should get tight distance
        let d_trending = ls.recommended_distance(&trending_thought);
        let d_choppy = ls.recommended_distance(&choppy_thought);

        eprintln!("trending → {:.4}%, choppy → {:.4}%",
            d_trending * 100.0, d_choppy * 100.0);

        assert!(d_trending < d_choppy,
            "trending should be tighter than choppy: {:.4} vs {:.4}",
            d_trending, d_choppy);
    }
}
