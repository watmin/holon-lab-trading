//! Observer — a leaf node in the enterprise tree.
//!
//! Each observer thinks different thoughts at their own time scale.
//! The manager aggregates their predictions — it does not encode candle data.
//! Observers perceive, they don't decide.

use std::collections::VecDeque;

use holon::memory::OnlineSubspace;

use crate::journal::Journal;
use crate::window_sampler::WindowSampler;

pub struct Observer {
    pub name: &'static str,
    pub profile: &'static str,
    pub journal: Journal,
    pub resolved: VecDeque<(f64, bool)>,  // (conviction, correct)
    pub good_state_subspace: OnlineSubspace,
    pub recalib_wins: u32,
    pub recalib_total: u32,
    pub last_recalib_count: usize,
    pub window_sampler: WindowSampler,
    pub conviction_history: VecDeque<f64>,
    pub flip_threshold: f64,
    /// Proof gate: the expert must prove direction accuracy before
    /// its opinion flows upstream. Silence, not noise.
    pub curve_valid: bool,
}

impl Observer {
    pub fn new(profile: &'static str, dims: usize, recalib_interval: usize, seed: u64) -> Self {
        Self {
            name: profile,
            profile,
            journal: Journal::new(profile, dims, recalib_interval),
            resolved: VecDeque::new(),
            good_state_subspace: OnlineSubspace::new(dims, 8),
            recalib_wins: 0,
            recalib_total: 0,
            last_recalib_count: 0,
            window_sampler: WindowSampler::new(seed, 12, 2016),
            conviction_history: VecDeque::new(),
            flip_threshold: 0.0,
            curve_valid: false,
        }
    }
}
