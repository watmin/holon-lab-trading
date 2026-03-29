//! Deterministic window size sampling for adaptive-depth encoding.
//!
//! Each candle gets a window size drawn from a log-uniform distribution
//! over [min_window, max_window]. The sampling is deterministic: same
//! candle index + same seed = same window size. Reproducible across runs.
//!
//! Log-uniform means we explore small windows as densely as large ones.
//! The difference between 48 and 96 candles is as likely to be sampled
//! as the difference between 960 and 1920.

/// Deterministic window sampler. Same seed + same candle = same window.
pub struct WindowSampler {
    seed: u64,
    pub min_window: usize,
    pub max_window: usize,
}

impl WindowSampler {
    pub fn new(seed: u64, min_window: usize, max_window: usize) -> Self {
        Self { seed, min_window, max_window }
    }

    /// Sample a window size for a given candle index.
    /// Returns a value in [min_window, max_window], log-uniformly distributed.
    /// Deterministic: same candle_idx always returns the same window.
    pub fn sample(&self, candle_idx: usize) -> usize {
        // Simple hash: mix candle index with seed
        let mut h = self.seed.wrapping_mul(6364136223846793005)
            .wrapping_add(candle_idx as u64)
            .wrapping_mul(1442695040888963407);
        h ^= h >> 33;
        h = h.wrapping_mul(0xff51afd7ed558ccd);
        h ^= h >> 33;

        // Map to [0, 1) uniformly
        let u = (h >> 11) as f64 / (1u64 << 53) as f64;

        // Log-uniform: exp(uniform(ln(min), ln(max)))
        let ln_min = (self.min_window as f64).ln();
        let ln_max = (self.max_window as f64).ln();
        let ln_w = ln_min + u * (ln_max - ln_min);
        let w = ln_w.exp().round() as usize;

        w.clamp(self.min_window, self.max_window)
    }

    /// The horizon for a given window: 75% of window size.
    /// Starting heuristic — the horizon expert will learn the real ratio.
    pub fn horizon_for(&self, window: usize) -> usize {
        (window * 3 / 4).max(12) // at least 12 candles (1 hour)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn deterministic() {
        let s = WindowSampler::new(42, 12, 2016);
        let a = s.sample(1000);
        let b = s.sample(1000);
        assert_eq!(a, b);
    }

    #[test]
    fn in_range() {
        let s = WindowSampler::new(42, 12, 2016);
        for i in 0..10000 {
            let w = s.sample(i);
            assert!(w >= 12 && w <= 2016, "window {} out of range at candle {}", w, i);
        }
    }

    #[test]
    fn log_uniform_spread() {
        // Roughly equal samples in each octave: 12-24, 24-48, 48-96, ...
        let s = WindowSampler::new(42, 12, 2016);
        let mut small = 0; // 12-48
        let mut mid = 0;   // 48-192
        let mut big = 0;   // 192-2016
        for i in 0..30000 {
            let w = s.sample(i);
            if w < 48 { small += 1; }
            else if w < 192 { mid += 1; }
            else { big += 1; }
        }
        // Each bucket should be roughly 1/3 on log scale
        // (ln(48)-ln(12))/(ln(2016)-ln(12)) ≈ 0.27
        // (ln(192)-ln(48))/(ln(2016)-ln(12)) ≈ 0.27
        // (ln(2016)-ln(192))/(ln(2016)-ln(12)) ≈ 0.46
        assert!(small > 5000, "too few small windows: {}", small);
        assert!(mid > 5000, "too few mid windows: {}", mid);
        assert!(big > 5000, "too few big windows: {}", big);
    }
}
