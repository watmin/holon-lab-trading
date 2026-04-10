/// Deterministic log-uniform window selection.
/// Owned by the market observer. Not shared.

#[derive(Clone, Debug)]
pub struct WindowSampler {
    pub seed: usize,
    pub min_window: usize,
    pub max_window: usize,
}

impl WindowSampler {
    pub fn new(seed: usize, min_window: usize, max_window: usize) -> Self {
        Self { seed, min_window, max_window }
    }

    /// Deterministic log-uniform sample. Same seed + same encode_count -> same window.
    /// Log-uniform favors shorter windows (more responsive) while still sampling long ones.
    pub fn sample(&self, encode_count: usize) -> usize {
        let log_min = (self.min_window.max(1) as f64).ln();
        let log_max = (self.max_window.max(1) as f64).ln();

        // Deterministic hash: seed x encode_count -> pseudo-random float in [0, 1)
        let hash = ((self.seed.wrapping_add(encode_count)).wrapping_mul(2654435761)) % 4294967296;
        let t = hash as f64 / 4294967296.0;

        let log_val = log_min + t * (log_max - log_min);
        let window = log_val.exp().round() as usize;

        window.max(self.min_window).min(self.max_window)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_window_sampler_new() {
        let ws = WindowSampler::new(42, 10, 200);
        assert_eq!(ws.seed, 42);
        assert_eq!(ws.min_window, 10);
        assert_eq!(ws.max_window, 200);
    }

    #[test]
    fn test_sample_deterministic() {
        let ws = WindowSampler::new(42, 10, 200);
        let w1 = ws.sample(100);
        let w2 = ws.sample(100);
        assert_eq!(w1, w2, "Same seed + same encode_count must yield same window");
    }

    #[test]
    fn test_sample_within_bounds() {
        let ws = WindowSampler::new(42, 10, 200);
        for i in 0..1000 {
            let w = ws.sample(i);
            assert!(w >= 10, "Window {} below min at encode_count={}", w, i);
            assert!(w <= 200, "Window {} above max at encode_count={}", w, i);
        }
    }

    #[test]
    fn test_sample_varies_with_count() {
        let ws = WindowSampler::new(42, 10, 200);
        let w1 = ws.sample(0);
        let w2 = ws.sample(1);
        let w3 = ws.sample(2);
        // Not all three should be the same (extremely unlikely with good hash)
        assert!(
            !(w1 == w2 && w2 == w3),
            "Expected variation across encode counts"
        );
    }

    #[test]
    fn test_sample_different_seeds() {
        let ws1 = WindowSampler::new(1, 10, 200);
        let ws2 = WindowSampler::new(2, 10, 200);
        // Different seeds should (almost certainly) give different windows at some point
        let differs = (0..100).any(|i| ws1.sample(i) != ws2.sample(i));
        assert!(differs, "Different seeds should produce different windows");
    }
}
