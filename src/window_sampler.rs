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
