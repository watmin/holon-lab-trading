/// Deterministic log-uniform window selection. Each market observer owns one.
/// Its own seed, its own time scale.

/// Samples window sizes from a log-uniform distribution deterministically.
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

    /// Deterministic log-uniform sample from [min_window, max_window]
    /// using seed and encode_count to produce a reproducible window size.
    pub fn sample(&self, encode_count: usize) -> usize {
        let min_log = (self.min_window as f64).ln();
        let max_log = (self.max_window as f64).ln();

        // Deterministic hash from seed + encode_count
        let hash = (self.seed.wrapping_add(encode_count)).wrapping_mul(2_654_435_761) % 4_294_967_296;
        let t = hash as f64 / 4_294_967_296.0;
        let log_val = min_log + t * (max_log - min_log);

        let raw = log_val.exp().round() as usize;
        raw.clamp(self.min_window, self.max_window)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_window_sampler_new() {
        let ws = WindowSampler::new(42, 10, 500);
        assert_eq!(ws.seed, 42);
        assert_eq!(ws.min_window, 10);
        assert_eq!(ws.max_window, 500);
    }

    #[test]
    fn test_sample_determinism() {
        let ws1 = WindowSampler::new(42, 10, 500);
        let ws2 = WindowSampler::new(42, 10, 500);

        // Same seed, same count => same result
        for count in 0..100 {
            assert_eq!(
                ws1.sample(count),
                ws2.sample(count),
                "Determinism broken at count {}",
                count
            );
        }
    }

    #[test]
    fn test_sample_within_bounds() {
        let ws = WindowSampler::new(7, 20, 1000);

        for count in 0..1000 {
            let window = ws.sample(count);
            assert!(
                window >= 20 && window <= 1000,
                "Window {} out of bounds [20, 1000] at count {}",
                window,
                count
            );
        }
    }

    #[test]
    fn test_different_seeds_different_results() {
        let ws1 = WindowSampler::new(1, 10, 500);
        let ws2 = WindowSampler::new(99, 10, 500);

        // Different seeds should produce at least some different samples
        let mut differ = false;
        for count in 0..100 {
            if ws1.sample(count) != ws2.sample(count) {
                differ = true;
                break;
            }
        }
        assert!(differ, "Different seeds should produce different windows");
    }

    #[test]
    fn test_sample_varies_with_count() {
        let ws = WindowSampler::new(42, 10, 500);

        // Not all samples should be the same value
        let first = ws.sample(0);
        let mut varied = false;
        for count in 1..100 {
            if ws.sample(count) != first {
                varied = true;
                break;
            }
        }
        assert!(varied, "Samples should vary across different encode counts");
    }

    #[test]
    fn test_clone() {
        let ws = WindowSampler::new(42, 10, 500);
        let ws2 = ws.clone();
        assert_eq!(ws.seed, ws2.seed);
        assert_eq!(ws.min_window, ws2.min_window);
        assert_eq!(ws.max_window, ws2.max_window);
        assert_eq!(ws.sample(0), ws2.sample(0));
    }

    #[test]
    fn test_min_equals_max() {
        let ws = WindowSampler::new(42, 100, 100);
        // When min == max, all samples should be that value
        for count in 0..50 {
            assert_eq!(ws.sample(count), 100);
        }
    }
}
