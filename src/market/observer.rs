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

// ─── Observer thresholds ──────────────────────────────────────────────────
/// Minimum conviction history entries before updating threshold.
const MIN_CONVICTION_HISTORY: usize = 200;
/// Recompute conviction threshold every N resolved predictions.
const THRESHOLD_UPDATE_INTERVAL: usize = 50;
/// Minimum resolved predictions before evaluating proof gate.
const MIN_RESOLVED_FOR_PROOF: usize = 100;
/// Fraction of conviction threshold for high-conviction filter in proof gate.
const PROOF_CONVICTION_FACTOR: f64 = 0.8;
/// Minimum high-conviction samples to evaluate accuracy.
const MIN_PROOF_SAMPLES: usize = 20;
/// Accuracy above this means the observer has proven directional edge.
const PROOF_ACCURACY_THRESHOLD: f64 = 0.52;
/// Minimum window size (candles) for observer sampling.
const MIN_WINDOW: usize = 12;
/// Maximum window size (candles) for observer sampling.
const MAX_WINDOW: usize = 2016;
/// Minimum accuracy to snapshot a discriminant as "good state" during engram recalibration.
const ENGRAM_MIN_ACC: f64 = 0.55;
/// Minimum resolved predictions in a recalib window before engram gating applies.
const ENGRAM_MIN_TOTAL: u32 = 20;

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
    pub name: super::Lens,
    pub conviction: f64,
    pub direction: Label,
    pub correct: bool,
}

pub struct Observer {
    pub lens: super::Lens,
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
    /// Cached rolling accuracy of resolved predictions. Updated when resolved changes.
    pub cached_acc: f64,
}

impl Observer {
    pub fn new(lens: super::Lens, dims: usize, recalib_interval: usize, seed: u64, labels: &[&str]) -> Self {
        let mut journal = Journal::new(lens.as_str(), dims, recalib_interval);
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
            window_sampler: WindowSampler::new(seed, MIN_WINDOW, MAX_WINDOW),
            conviction_history: VecDeque::new(),
            conviction_threshold: 0.0,
            curve_valid: false,
            cached_acc: 0.0,
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
            if self.recalib_total >= ENGRAM_MIN_TOTAL {
                let acc = self.recalib_wins as f64 / self.recalib_total as f64;
                if acc > ENGRAM_MIN_ACC {
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

        // 4. Track resolved predictions + update cached accuracy
        self.resolved.push_back((prediction.conviction, correct));
        if self.resolved.len() > conviction_window {
            self.resolved.pop_front();
        }
        // 5. Update conviction history + flip threshold
        self.conviction_history.push_back(prediction.conviction);
        if self.conviction_history.len() > conviction_window {
            self.conviction_history.pop_front();
        }
        if self.conviction_history.len() >= MIN_CONVICTION_HISTORY
            && self.resolved.len() % THRESHOLD_UPDATE_INTERVAL == 0
        {
            self.conviction_threshold = quantile(&self.conviction_history, conviction_quantile);
        }

        // 6. Single pass: compute accuracy + proof gate simultaneously
        let proof_threshold = self.conviction_threshold * PROOF_CONVICTION_FACTOR;
        let (total, all_correct, proof_count, proof_correct) = self.resolved.iter().fold(
            (0usize, 0usize, 0usize, 0usize),
            |(t, ac, pn, pc), (c, w)| (
                t + 1,
                ac + *w as usize,
                pn + (*c >= proof_threshold) as usize,
                pc + (*c >= proof_threshold && *w) as usize,
            ),
        );
        self.cached_acc = if total == 0 { 0.0 } else { all_correct as f64 / total as f64 };
        if total >= MIN_RESOLVED_FOR_PROOF && proof_count >= MIN_PROOF_SAMPLES {
            self.curve_valid = proof_correct as f64 / proof_count as f64 > PROOF_ACCURACY_THRESHOLD;
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

#[cfg(test)]
mod tests {
    use super::*;

    const TEST_DIMS: usize = 64;

    #[test]
    fn observer_new_creates_with_correct_fields() {
        let obs = Observer::new(
            super::super::Lens::Momentum,
            TEST_DIMS,
            500,  // recalib_interval
            42,   // seed
            &["Buy", "Sell"],
        );

        assert_eq!(obs.lens, super::super::Lens::Momentum);
        assert!(obs.resolved.is_empty());
        assert!(obs.conviction_history.is_empty());
        assert_eq!(obs.conviction_threshold, 0.0);
        assert!(!obs.curve_valid);
        assert_eq!(obs.cached_acc, 0.0);
        assert_eq!(obs.recalib_wins, 0);
        assert_eq!(obs.recalib_total, 0);
        assert_eq!(obs.last_recalib_count, 0);
    }

    #[test]
    fn observer_new_registers_primary_label() {
        let obs = Observer::new(
            super::super::Lens::Structure,
            TEST_DIMS,
            500,
            7,
            &["Buy", "Sell"],
        );
        // primary_label should be the first registered label (index 0)
        assert_eq!(obs.primary_label.index(), 0);
    }

    #[test]
    fn observer_new_with_different_lenses() {
        for lens in &[
            super::super::Lens::Momentum,
            super::super::Lens::Volume,
            super::super::Lens::Regime,
            super::super::Lens::Generalist,
        ] {
            let obs = Observer::new(*lens, TEST_DIMS, 500, 1, &["Buy", "Sell"]);
            assert_eq!(obs.lens, *lens);
        }
    }

    #[test]
    fn observer_resolve_without_direction_returns_none() {
        let mut obs = Observer::new(
            super::super::Lens::Momentum,
            TEST_DIMS,
            500,
            42,
            &["Buy", "Sell"],
        );

        let thought = holon::Vector::zeros(TEST_DIMS);
        // Prediction with no direction
        let pred = Prediction {
            scores: Vec::new(),
            direction: None,
            conviction: 0.0,
            raw_cos: 0.0,
        };

        let result = obs.resolve(&thought, &pred, obs.primary_label, 1.0, 0.5, 1000);
        assert!(result.is_none(), "no direction means no resolve log");
    }

    #[test]
    fn observer_resolve_with_direction_returns_some() {
        let mut obs = Observer::new(
            super::super::Lens::Momentum,
            TEST_DIMS,
            500,
            42,
            &["Buy", "Sell"],
        );

        let thought = holon::Vector::zeros(TEST_DIMS);
        let buy_label = obs.primary_label;
        let pred = Prediction {
            scores: Vec::new(),
            direction: Some(buy_label),
            conviction: 0.5,
            raw_cos: 0.5,
        };

        let result = obs.resolve(&thought, &pred, buy_label, 1.0, 0.5, 1000);
        assert!(result.is_some(), "with direction should return resolve log");
        let log = result.unwrap();
        assert_eq!(log.name, super::super::Lens::Momentum);
        assert!((log.conviction - 0.5).abs() < 1e-10);
        assert!(log.correct); // predicted buy, outcome is buy
    }
}
