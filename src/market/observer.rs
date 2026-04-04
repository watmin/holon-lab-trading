//! Observer — a leaf node in the enterprise tree.
//!
//! Each observer thinks different thoughts at their own time scale.
//! The manager aggregates their predictions — it does not encode candle data.
//! Observers perceive, they don't decide.

use std::collections::VecDeque;

use holon::Vector;
use holon::memory::OnlineSubspace;

use crate::journal::{Journal, Label, Prediction};
use crate::position::Outcome;
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
/// Minimum noise observations before the noise subspace activates.
/// Below this, thoughts pass through unfiltered (monotonic warmup).
const NOISE_MIN_SAMPLES: usize = 50;

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
    /// Template 2: learns boring thought patterns from Noise outcomes.
    /// Operates on thought vectors. Different from good_state_subspace
    /// which operates on discriminant vectors.
    pub noise_subspace: OnlineSubspace,
    pub resolved: VecDeque<(f64, bool)>,  // (conviction, correct)
    pub good_state_subspace: OnlineSubspace,
    pub recalib_wins: u32,
    pub recalib_total: u32,
    pub last_recalib_count: usize,
    pub window_sampler: WindowSampler,
    pub conviction_history: VecDeque<f64>,
    pub conviction_threshold: f64,
    /// The primary label for discriminant access (first registered label = Win).
    pub primary_label: Label,
    /// The loss label (second registered label = Loss). Stored, not fetched by index.
    pub loss_label: Label,
    /// Proof gate: the observer must prove direction accuracy before
    /// its opinion flows upstream. Silence, not noise.
    pub curve_valid: bool,
    /// Cached rolling accuracy of resolved predictions. Updated when resolved changes.
    pub cached_acc: f64,
}

impl Observer {
    pub fn new(lens: super::Lens, dims: usize, recalib_interval: usize, seed: u64) -> Self {
        let mut journal = Journal::new(lens.as_str(), dims, recalib_interval);
        let primary_label = journal.register("Win");
        let loss_label = journal.register("Loss");
        Self {
            lens,
            journal,
            primary_label,
            loss_label,
            noise_subspace: OnlineSubspace::new(dims, 8),
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

    /// Strip noise from a thought vector via the noise subspace.
    /// Monotonic warmup: passes through unfiltered until NOISE_MIN_SAMPLES.
    /// Returns the L2-normalized residual after noise projection is subtracted.
    pub fn strip_noise(&self, thought: &Vector) -> Vector {
        if self.noise_subspace.n() < NOISE_MIN_SAMPLES {
            return thought.clone(); // warmup: unfiltered
        }
        let thought_f64: Vec<f64> = thought.data().iter().map(|&v| v as f64).collect();
        // anomalous_component = x - reconstruct(x): the part the noise subspace CAN'T explain.
        // Returns D-dimensional vector (same as input), not k coefficients.
        let residual = self.noise_subspace.anomalous_component(&thought_f64);
        // L2-normalize: the subtraction changes the norm. Normalize before journal sees it.
        let norm = residual.iter().map(|x| x * x).sum::<f64>().sqrt();
        if norm < 1e-10 {
            return thought.clone(); // degenerate: noise ate everything, pass through
        }
        let normalized: Vec<i8> = residual.iter()
            .map(|&x| (x / norm * 127.0).round().clamp(-127.0, 127.0) as i8)
            .collect();
        Vector::from_data(normalized)
    }

    /// Measure how much signal remains after noise subtraction.
    /// High norm = unusual thought. Low norm = boring thought.
    /// Used by classify_outcome to gate Win/Loss vs Noise.
    pub fn residual_norm(&self, thought: &Vector) -> f64 {
        if self.noise_subspace.n() < NOISE_MIN_SAMPLES {
            return 1.0; // warmup: treat all thoughts as unusual
        }
        let thought_f64: Vec<f64> = thought.data().iter().map(|&v| v as f64).collect();
        let residual = self.noise_subspace.anomalous_component(&thought_f64);
        residual.iter().map(|x| x * x).sum::<f64>().sqrt()
    }

    /// Update the noise subspace with a raw thought. Called every candle.
    /// The noise subspace is the background model — it sees everything.
    pub fn learn_noise(&mut self, thought_vec: &Vector) {
        let thought_f64: Vec<f64> = thought_vec.data().iter().map(|&v| v as f64).collect();
        self.noise_subspace.update(&thought_f64);
    }

    /// Resolve a prediction against an observed outcome (Win or Loss).
    /// Called when a simulated position resolves — not every candle.
    /// Weight = residual_norm × grace/violence (already computed by caller).
    /// Also handles: accuracy tracking, engram gating, curve validation,
    /// conviction threshold update, and resolved prediction tracking.
    /// Returns a log record if the observer had a directional prediction.
    pub fn resolve(
        &mut self,
        thought_vec: &Vector,
        prediction: &Prediction,
        outcome: Outcome,
        conviction_quantile: f64,
        conviction_window: usize,
    ) -> Option<ResolveLog> {
        // 1. Learn: journal sees the residual, weighted by outcome magnitude
        let win_label = self.primary_label;
        let loss_label = self.loss_label;
        let correct = match outcome {
            Outcome::Win { weight } => {
                let residual = self.strip_noise(thought_vec);
                self.journal.observe(&residual, win_label, weight);
                true
            }
            Outcome::Loss { weight } => {
                let residual = self.strip_noise(thought_vec);
                self.journal.observe(&residual, loss_label, weight);
                false
            }
        };

        // 2. Track accuracy since last recalib (for engram gating)
        if let Some(_pred_dir) = prediction.direction {
            self.recalib_total += 1;
            if correct { self.recalib_wins += 1; }
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
            let obs = Observer::new(*lens, TEST_DIMS, 500, 1);
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
        );

        let thought = holon::Vector::zeros(TEST_DIMS);
        // Prediction with no direction
        let pred = Prediction {
            scores: Vec::new(),
            direction: None,
            conviction: 0.0,
            raw_cos: 0.0,
        };

        let result = obs.resolve(&thought, &pred, Outcome::Win { weight: 1.0 }, 0.5, 1000);
        assert!(result.is_none(), "no direction means no resolve log");
    }

    #[test]
    fn observer_resolve_with_direction_returns_some() {
        let mut obs = Observer::new(
            super::super::Lens::Momentum,
            TEST_DIMS,
            500,
            42,
        );

        let thought = holon::Vector::zeros(TEST_DIMS);
        let buy_label = obs.primary_label;
        let pred = Prediction {
            scores: Vec::new(),
            direction: Some(buy_label),
            conviction: 0.5,
            raw_cos: 0.5,
        };

        let result = obs.resolve(&thought, &pred, Outcome::Win { weight: 1.0 }, 0.5, 1000);
        assert!(result.is_some(), "with direction should return resolve log");
        let log = result.unwrap();
        assert_eq!(log.name, super::super::Lens::Momentum);
        assert!((log.conviction - 0.5).abs() < 1e-10);
        assert!(log.correct); // predicted buy, outcome is Win
    }

    #[test]
    fn quantile_computes_median() {
        let data: VecDeque<f64> = (0..100).map(|i| i as f64).collect();
        let med = quantile(&data, 0.5);
        assert!((med - 50.0).abs() < 1.0);
    }

    #[test]
    fn quantile_computes_extremes() {
        let data: VecDeque<f64> = (0..100).map(|i| i as f64).collect();
        let low = quantile(&data, 0.0);
        assert_eq!(low, 0.0);
        let high = quantile(&data, 0.99);
        assert!(high >= 98.0);
    }

    #[test]
    fn observer_resolve_tracks_conviction_history() {
        let mut obs = Observer::new(
            super::super::Lens::Momentum,
            TEST_DIMS,
            500,
            42,
        );
        let thought = holon::Vector::zeros(TEST_DIMS);
        let buy = obs.primary_label;

        for i in 0..10 {
            let pred = Prediction {
                scores: Vec::new(),
                direction: Some(buy),
                conviction: 0.1 * i as f64,
                raw_cos: 0.5,
            };
            obs.resolve(&thought, &pred, Outcome::Win { weight: 1.0 }, 0.5, 1000);
        }

        assert_eq!(obs.conviction_history.len(), 10);
        assert_eq!(obs.resolved.len(), 10);
    }

    #[test]
    fn observer_resolve_caps_conviction_window() {
        let mut obs = Observer::new(
            super::super::Lens::Structure,
            TEST_DIMS,
            500,
            7,
        );
        let thought = holon::Vector::zeros(TEST_DIMS);
        let buy = obs.primary_label;
        let window = 20;

        for _ in 0..50 {
            let pred = Prediction {
                scores: Vec::new(),
                direction: Some(buy),
                conviction: 0.5,
                raw_cos: 0.5,
            };
            obs.resolve(&thought, &pred, Outcome::Win { weight: 1.0 }, 0.5, window);
        }

        assert_eq!(obs.conviction_history.len(), window);
        assert_eq!(obs.resolved.len(), window);
    }

    #[test]
    fn observer_resolve_updates_cached_acc() {
        let mut obs = Observer::new(
            super::super::Lens::Volume,
            TEST_DIMS,
            500,
            99,
        );
        let thought = holon::Vector::zeros(TEST_DIMS);
        let buy = obs.primary_label;

        // 10 correct predictions (Win outcome)
        for _ in 0..10 {
            let pred = Prediction {
                scores: Vec::new(),
                direction: Some(buy),
                conviction: 0.5,
                raw_cos: 0.5,
            };
            obs.resolve(&thought, &pred, Outcome::Win { weight: 1.0 }, 0.5, 1000);
        }
        assert!((obs.cached_acc - 1.0).abs() < 1e-10, "all correct → acc=1.0");

        // Now add 10 wrong predictions (Loss outcome)
        for _ in 0..10 {
            let pred = Prediction {
                scores: Vec::new(),
                direction: Some(buy),
                conviction: 0.5,
                raw_cos: 0.5,
            };
            obs.resolve(&thought, &pred, Outcome::Loss { weight: 1.0 }, 0.5, 1000);
        }
        assert!((obs.cached_acc - 0.5).abs() < 1e-10, "half correct → acc=0.5");
    }

    #[test]
    fn observer_resolve_updates_conviction_threshold_after_min_history() {
        let mut obs = Observer::new(
            super::super::Lens::Regime,
            TEST_DIMS,
            500,
            42,
        );
        let thought = holon::Vector::zeros(TEST_DIMS);
        let buy = obs.primary_label;

        // Need MIN_CONVICTION_HISTORY (200) entries and hit THRESHOLD_UPDATE_INTERVAL (50)
        for i in 0..250 {
            let pred = Prediction {
                scores: Vec::new(),
                direction: Some(buy),
                conviction: (i as f64) / 250.0,
                raw_cos: 0.5,
            };
            obs.resolve(&thought, &pred, Outcome::Win { weight: 1.0 }, 0.5, 1000);
        }
        // After 250 resolved with min_conviction_history=200, threshold should be updated
        assert!(obs.conviction_threshold > 0.0, "threshold should be updated after enough history");
    }

    #[test]
    fn observer_resolve_incorrect_prediction_tracked() {
        let mut obs = Observer::new(
            super::super::Lens::Momentum,
            TEST_DIMS,
            500,
            42,
        );
        let thought = holon::Vector::zeros(TEST_DIMS);
        let buy = obs.primary_label;

        // Predict buy, but outcome is Loss → incorrect
        let pred = Prediction {
            scores: Vec::new(),
            direction: Some(buy),
            conviction: 0.8,
            raw_cos: 0.8,
        };
        let result = obs.resolve(&thought, &pred, Outcome::Loss { weight: 1.0 }, 0.5, 1000);
        assert!(result.is_some());
        let log = result.unwrap();
        assert!(!log.correct);
    }

    #[test]
    fn strip_noise_returns_same_dimension() {
        let mut obs = Observer::new(
            super::super::Lens::Momentum,
            TEST_DIMS,
            500,
            42,
        );

        let thought = holon::VectorManager::new(TEST_DIMS).get_vector("test-thought");

        // Before warmup: passthrough, same dims
        let result = obs.strip_noise(&thought);
        assert_eq!(result.data().len(), TEST_DIMS, "passthrough should preserve dims");

        // Train noise subspace past warmup
        for i in 0..60 {
            let v: Vec<f64> = (0..TEST_DIMS).map(|d| ((i * d) as f64).sin()).collect();
            obs.noise_subspace.update(&v);
        }

        // After warmup: residual should still be same dims
        let result = obs.strip_noise(&thought);
        assert_eq!(result.data().len(), TEST_DIMS,
            "noise-stripped residual must be same dimension as input");
        assert!(result.data().iter().any(|&x| x != 0),
            "residual should be non-zero");
    }

    #[test]
    fn strip_noise_produces_valid_residual_after_training() {
        // Train noise subspace on varied vectors, then strip noise from a new thought.
        // The residual should be D-dimensional and non-zero.
        let dims = 256;
        let mut obs = Observer::new(
            super::super::Lens::Generalist,
            dims,
            500,
            42,
        );

        let vm = holon::VectorManager::new(dims);

        // Train on varied vectors (different atoms = different random directions)
        for i in 0..100 {
            let v: Vec<f64> = vm.get_vector(&format!("train-{}", i))
                .data().iter().map(|&x| x as f64).collect();
            obs.noise_subspace.update(&v);
        }

        // Strip noise from a new thought
        let thought = vm.get_vector("unseen-thought");
        let result = obs.strip_noise(&thought);
        assert_eq!(result.data().len(), dims, "residual must be D-dimensional");
        assert!(result.data().iter().any(|&x| x != 0), "residual should be non-zero");
    }

    #[test]
    fn resolve_after_noise_warmup_does_not_crash() {
        // Integration test: the exact scenario that caused the production crash.
        // 1. Train noise subspace past NOISE_MIN_SAMPLES via learn_noise
        // 2. Resolve a Win/Loss outcome → strip_noise feeds residual into journal.observe
        // If strip_noise returns wrong dimensions (k coefficients instead of D-vector),
        // the journal's accumulator panics on dimension mismatch.
        let dims = 256; // larger than k=8 so mismatch is detectable
        let mut obs = Observer::new(
            super::super::Lens::Momentum,
            dims,
            500,
            42,
        );

        let vm = holon::VectorManager::new(dims);
        let buy = obs.primary_label;
        let loss_label = obs.journal.labels()[1];

        // Phase 1: feed 60 thoughts to learn_noise to warm up the noise subspace
        for i in 0..60 {
            let thought = vm.get_vector(&format!("noise-thought-{}", i));
            obs.learn_noise(&thought);
        }
        assert!(obs.noise_subspace.n() >= 50,
            "noise subspace should be past warmup: n={}", obs.noise_subspace.n());

        // Phase 2: resolve a directional outcome — strip_noise activates,
        // residual goes into journal.observe. This is the crash site.
        let thought = vm.get_vector("signal-thought");
        let pred = Prediction {
            scores: Vec::new(),
            direction: Some(buy),
            conviction: 0.5,
            raw_cos: 0.5,
        };
        // This panicked before the fix: "Dimension mismatch in accumulator: left: D, right: 8"
        let result = obs.resolve(&thought, &pred, Outcome::Win { weight: 1.0 }, 0.5, 1000);
        assert!(result.is_some(), "directional resolve should return log");

        // Also test with Loss outcome
        let thought2 = vm.get_vector("signal-thought-2");
        let pred2 = Prediction {
            scores: Vec::new(),
            direction: Some(loss_label),
            conviction: 0.4,
            raw_cos: -0.4,
        };
        let result2 = obs.resolve(&thought2, &pred2, Outcome::Loss { weight: 1.0 }, 0.5, 1000);
        assert!(result2.is_some());
    }
}
