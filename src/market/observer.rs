//! Observer — a leaf node in the enterprise tree.
//!
//! Each observer thinks different thoughts at their own time scale.
//! The manager aggregates their predictions — it does not encode candle data.
//! Observers perceive, they don't decide.

use std::collections::VecDeque;

use holon::Vector;
use holon::memory::OnlineSubspace;

use crate::journal::{Journal, Label, Prediction};
use crate::window_sampler::WindowSampler;

/// Compute the q-th quantile of a deque. O(n) via selection, not O(n log n) sort.
/// Maps to the wat host form: (quantile xs q)
fn quantile(data: &VecDeque<f64>, q: f64) -> f64 {
    let mut buf: Vec<f64> = data.iter().copied().collect();
    let idx = ((buf.len() as f64 * q) as usize).min(buf.len() - 1);
    buf.select_nth_unstable_by(idx, |a, b| a.partial_cmp(b).unwrap());
    buf[idx]
}

/// Data returned from resolve() for diagnostic logging.
/// The heartbeat logs this to the ledger if diagnostics are enabled.
pub struct ResolveLog {
    pub name: &'static str,
    pub conviction: f64,
    pub direction: Label,
    pub correct: bool,
}

pub struct Observer {
    pub lens: &'static str,
    pub journal: Journal,
    pub resolved: VecDeque<(f64, bool)>,  // (conviction, correct)
    pub good_state_subspace: OnlineSubspace,
    pub recalib_wins: u32,
    pub recalib_total: u32,
    pub last_recalib_count: usize,
    pub window_sampler: WindowSampler,
    pub conviction_history: VecDeque<f64>,
    pub conviction_threshold: f64,
    /// The primary label for discriminant access (first registered label).
    pub primary_label: Label,
    /// Proof gate: the observer must prove direction accuracy before
    /// its opinion flows upstream. Silence, not noise.
    pub curve_valid: bool,
}

impl Observer {
    pub fn new(lens: &'static str, dims: usize, recalib_interval: usize, seed: u64, labels: &[&str]) -> Self {
        let mut journal = Journal::new(lens, dims, recalib_interval);
        let primary_label = journal.register(labels[0]);
        for label in &labels[1..] {
            journal.register(label);
        }
        Self {
            lens,
            journal,
            primary_label,
            resolved: VecDeque::new(),
            good_state_subspace: OnlineSubspace::new(dims, 8),
            recalib_wins: 0,
            recalib_total: 0,
            last_recalib_count: 0,
            window_sampler: WindowSampler::new(seed, 12, 2016),
            conviction_history: VecDeque::new(),
            conviction_threshold: 0.0,
            curve_valid: false,
        }
    }

    /// Resolve a prediction against an observed outcome.
    /// Handles: learning, accuracy tracking, engram gating, curve validation,
    /// conviction threshold update, and resolved prediction tracking.
    /// Returns a log record if the observer had a directional prediction.
    pub fn resolve(
        &mut self,
        thought_vec: &Vector,
        prediction: &Prediction,
        outcome: Label,
        signal_weight: f64,
        conviction_quantile: f64,
        conviction_window: usize,
    ) -> Option<ResolveLog> {
        // 1. Learn: accumulate this observation
        self.journal.observe(thought_vec, outcome, signal_weight);

        // 2. Track accuracy since last recalib (for engram gating)
        if let Some(pred_dir) = prediction.direction {
            self.recalib_total += 1;
            if pred_dir == outcome { self.recalib_wins += 1; }
        }

        // 3. Engram gating: if observer just recalibrated with good accuracy,
        //    snapshot the discriminant as a "good state"
        if self.journal.recalib_count() > self.last_recalib_count {
            self.last_recalib_count = self.journal.recalib_count();
            if self.recalib_total >= 20 {
                let acc = self.recalib_wins as f64 / self.recalib_total as f64;
                if acc > 0.55 {
                    if let Some(disc) = self.journal.discriminant(self.primary_label) {
                        let disc_owned = disc.to_vec();
                        self.good_state_subspace.update(&disc_owned);
                    }
                }
            }
            self.recalib_wins = 0;
            self.recalib_total = 0;
        }

        // 4-7: Only if the observer had a directional prediction
        let pred_dir = prediction.direction?;
        let correct = pred_dir == outcome;

        // 4. Track resolved predictions
        self.resolved.push_back((prediction.conviction, correct));
        if self.resolved.len() > conviction_window {
            self.resolved.pop_front();
        }

        // 5. Update conviction history + flip threshold
        self.conviction_history.push_back(prediction.conviction);
        if self.conviction_history.len() > conviction_window {
            self.conviction_history.pop_front();
        }
        if self.conviction_history.len() >= 200
            && self.resolved.len() % 50 == 0
        {
            self.conviction_threshold = quantile(&self.conviction_history, conviction_quantile);
        }

        // 6. Proof gate: does this observer have direction edge?
        if self.resolved.len() >= 100 {
            let high_conv: Vec<&(f64, bool)> = self.resolved.iter()
                .filter(|(c, _)| *c >= self.conviction_threshold * 0.8)
                .collect();
            if high_conv.len() >= 20 {
                let acc = high_conv.iter().filter(|(_, c)| *c).count() as f64
                    / high_conv.len() as f64;
                self.curve_valid = acc > 0.52;
            }
        }

        // 7. Return log data (heartbeat writes to ledger if diagnostics enabled)
        Some(ResolveLog {
            name: self.lens,
            conviction: prediction.conviction,
            direction: pred_dir,
            correct,
        })
    }
}
