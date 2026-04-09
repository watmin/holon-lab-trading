//! window-sampler.wat -- deterministic log-uniform window selection
//! Depends on: nothing

/// Each market observer has its own -- its own seed, its own time scale.
/// Deterministic log-uniform selection from [min_window, max_window].
#[derive(Clone, Debug)]
pub struct WindowSampler {
    pub seed: usize,
    pub min_window: usize,
    pub max_window: usize,
}

impl WindowSampler {
    pub fn new(seed: usize, min_window: usize, max_window: usize) -> Self {
        Self {
            seed,
            min_window,
            max_window,
        }
    }

    /// Deterministic log-uniform window size from encode_count.
    /// The hash ensures reproducibility. Log-uniform gives equal probability
    /// to each order of magnitude: short windows and long windows are equally
    /// likely to be explored.
    pub fn sample(&self, encode_count: usize) -> usize {
        let hash = (encode_count.wrapping_add(self.seed)).wrapping_mul(2_654_435_761) % 4_294_967_296;
        let t = (hash % 10_000) as f64 / 10_000.0;
        let log_min = (self.min_window.max(1) as f64).ln();
        let log_max = (self.max_window as f64).ln();
        let log_val = log_min + t * (log_max - log_min);
        let raw = log_val.exp().round() as usize;
        raw.clamp(self.min_window, self.max_window)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_deterministic_same_seed_same_count() {
        let ws = WindowSampler::new(42, 10, 1000);
        let a = ws.sample(100);
        let b = ws.sample(100);
        assert_eq!(a, b, "Same seed + same encode_count must produce same result");
    }

    #[test]
    fn test_deterministic_across_instances() {
        let ws1 = WindowSampler::new(42, 10, 1000);
        let ws2 = WindowSampler::new(42, 10, 1000);
        for i in 0..50 {
            assert_eq!(ws1.sample(i), ws2.sample(i),
                       "Two instances with same params must agree at encode_count={}", i);
        }
    }

    #[test]
    fn test_different_seeds_different_results() {
        let ws1 = WindowSampler::new(1, 10, 1000);
        let ws2 = WindowSampler::new(9999, 10, 1000);
        // At least some samples should differ
        let mut differ = false;
        for i in 0..100 {
            if ws1.sample(i) != ws2.sample(i) {
                differ = true;
                break;
            }
        }
        assert!(differ, "Different seeds should produce different results for at least some inputs");
    }

    #[test]
    fn test_output_within_bounds() {
        let ws = WindowSampler::new(7, 10, 500);
        for i in 0..1000 {
            let s = ws.sample(i);
            assert!(s >= 10, "Sample {} below min: {}", i, s);
            assert!(s <= 500, "Sample {} above max: {}", i, s);
        }
    }

    #[test]
    fn test_log_uniform_spans_range() {
        // Over many samples, we should see both small and large values
        let ws = WindowSampler::new(0, 10, 10000);
        let mut min_seen = usize::MAX;
        let mut max_seen = 0;
        for i in 0..10000 {
            let s = ws.sample(i);
            min_seen = min_seen.min(s);
            max_seen = max_seen.max(s);
        }
        // Should see values near the bottom (< 100) and near the top (> 5000)
        assert!(min_seen < 100,
                "Expected some small values, min seen was {}", min_seen);
        assert!(max_seen > 5000,
                "Expected some large values, max seen was {}", max_seen);
    }

    #[test]
    fn test_different_encode_counts_vary() {
        let ws = WindowSampler::new(42, 10, 1000);
        let mut seen = std::collections::HashSet::new();
        for i in 0..100 {
            seen.insert(ws.sample(i));
        }
        // Should produce more than one distinct value
        assert!(seen.len() > 1, "Expected variation across encode_counts, got {} distinct values", seen.len());
    }
}
