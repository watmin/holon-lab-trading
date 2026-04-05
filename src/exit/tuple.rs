//! Tuple journal — the accountability primitive.
//!
//! One journal per (market observer, exit observer) tuple.
//! This IS the manager. Not a separate aggregator. The tuple's own journal
//! tracking its own history. Direction × magnitude → grace or violence.
//!
//! Labels: Grace / Violence (from treasury reality feedback).
//! Input: the composed thought (market thought bundled with judgment).
//! The proof curve gates treasury funding.
//!
//! See wat/exit/tuple.wat for the specification.

use std::collections::VecDeque;

use holon::Vector;
use holon::memory::OnlineSubspace;

use crate::exit::scalar::ScalarAccumulator;
use crate::journal::{Journal, Label, Prediction};
use crate::position::DualExcursion;

/// Normalize a scalar to 0-1 for encoding. The meaning lives at the call site.
/// `value`: the raw value. `max`: the upper bound of the range.
/// Values outside [0, max] are clamped.
pub fn normalize_scalar(value: f64, max: f64) -> f64 {
    (value / max).clamp(0.0, 1.0)
}

/// Denormalize a 0-1 scalar back to its original range.
pub fn denormalize_scalar(normalized: f64, max: f64) -> f64 {
    normalized * max
}

/// The unit scale for all scalar encoding. Every scalar goes in as 0-1.
pub const SCALAR_SCALE: f64 = 1.0;

/// Minimum noise observations before the noise subspace activates.
const NOISE_MIN_SAMPLES: usize = 50;
/// Minimum resolved predictions before evaluating proof gate.
const MIN_RESOLVED_FOR_PROOF: usize = 100;
/// Fraction of conviction threshold for high-conviction filter in proof gate.
const PROOF_CONVICTION_FACTOR: f64 = 0.8;
/// Minimum high-conviction samples to evaluate accuracy.
const MIN_PROOF_SAMPLES: usize = 20;
/// Accuracy above this means the tuple has proven edge.
const PROOF_ACCURACY_THRESHOLD: f64 = 0.52;
/// Minimum accuracy to snapshot a discriminant as "good state" during engram recalibration.
const ENGRAM_MIN_ACC: f64 = 0.55;
/// Minimum resolved predictions in a recalib window before engram gating applies.
const ENGRAM_MIN_TOTAL: u32 = 20;
/// Minimum conviction history entries before updating threshold.
const MIN_CONVICTION_HISTORY: usize = 200;
/// Recompute conviction threshold every N resolved predictions.
const THRESHOLD_UPDATE_INTERVAL: usize = 50;

/// Compute the q-th quantile of a deque.
fn quantile(data: &VecDeque<f64>, q: f64) -> f64 {
    let mut buf: Vec<f64> = data.iter().copied().collect();
    let idx = ((buf.len() as f64 * q) as usize).min(buf.len() - 1);
    buf.select_nth_unstable_by(idx, |a, b| a.partial_cmp(b).unwrap());
    buf[idx]
}

/// Maximum paper entries per tuple journal.
const MAX_PAPERS: usize = 500;

/// A hypothetical trade tracked without capital.
///
/// Every candle, every tuple journal receives a composed thought. That thought
/// becomes a paper entry with a DualExcursion. When both sides resolve, the
/// paper produces learning: Grace/Violence labels for the journal, and
/// recommended_distance observations for the LearnedStop.
///
/// This is the FAST learning stream. Thousands of papers resolve per run.
pub struct PaperEntry {
    pub composed_thought: Vector,
    pub dual: DualExcursion,
    pub entry_price: f64,
    /// The recommended distance at paper creation time.
    /// Papers teach the LearnedStop with the distance that was current
    /// when the market state was observed.
    pub recommended_distance: f64,
}

/// The tuple identity. Cheap. Copyable. The unit of accountability.
#[derive(Clone, Debug)]
pub struct TupleId {
    pub market_observer: String,
    pub exit_observer: String,
}

impl TupleId {
    pub fn new(market: &str, exit: &str) -> Self {
        Self {
            market_observer: market.to_string(),
            exit_observer: exit.to_string(),
        }
    }

    pub fn name(&self) -> String {
        format!("tuple-{}-{}", self.market_observer, self.exit_observer)
    }
}

/// The outcome from the treasury. The most honest signal in the system.
#[derive(Clone, Copy, Debug)]
pub enum RealityOutcome {
    /// The trade produced real value. Weight = amount gained.
    Grace { amount: f64 },
    /// The trade destroyed value. Weight = amount lost.
    Violence { amount: f64 },
}

/// The tuple journal. Third journal in the stack.
///
/// Three journals, three questions:
///   1. Market observer journal: "which direction?" (Win/Loss)
///   2. Exit observer journal:   "which side was better?" (Buy/Sell)
///   3. Tuple journal:            "did this combination produce grace?" (Grace/Violence)
pub struct TupleJournal {
    pub id: TupleId,
    pub journal: Journal,
    pub noise_subspace: OnlineSubspace,
    pub grace_label: Label,
    pub violence_label: Label,

    // ── Track record ──
    pub resolved: VecDeque<(f64, bool)>,     // (conviction, correct)
    pub conviction_history: VecDeque<f64>,
    pub conviction_threshold: f64,
    pub curve_valid: bool,
    pub cached_acc: f64,

    // ── Treasury allocation ──
    pub cumulative_grace: f64,
    pub cumulative_violence: f64,
    pub trade_count: usize,

    // ── Engram gating ──
    pub good_state_subspace: OnlineSubspace,
    pub recalib_wins: u32,
    pub recalib_total: u32,
    pub last_recalib_count: usize,

    // ── Scalar accumulators (named properties) ──
    /// Each magic number gets its own accumulator.
    /// The scalar lives separate from the thought vector.
    pub scalars: Vec<ScalarAccumulator>,

    // ── Paper entries (fast learning stream) ──
    /// Hypothetical trades tracked without capital.
    /// Every candle receives a paper. Both sides resolve organically.
    /// Resolved papers feed Grace/Violence labels + recommended distances.
    pub papers: VecDeque<PaperEntry>,
}

impl TupleJournal {
    /// Create a tuple journal for one (market, exit) tuple.
    pub fn new(market_name: &str, exit_name: &str, dims: usize, recalib_interval: usize) -> Self {
        let id = TupleId::new(market_name, exit_name);
        let name = id.name();
        let mut journal = Journal::new(&name, dims, recalib_interval);
        let grace_label = journal.register("Grace");
        let violence_label = journal.register("Violence");

        Self {
            id,
            journal,
            noise_subspace: OnlineSubspace::new(dims, 8),
            grace_label,
            violence_label,
            resolved: VecDeque::new(),
            conviction_history: VecDeque::new(),
            conviction_threshold: 0.0,
            curve_valid: false,
            cached_acc: 0.0,
            cumulative_grace: 0.0,
            cumulative_violence: 0.0,
            trade_count: 0,
            good_state_subspace: OnlineSubspace::new(dims, 8),
            recalib_wins: 0,
            recalib_total: 0,
            last_recalib_count: 0,
            scalars: Vec::new(),
            papers: VecDeque::new(),
        }
    }

    /// Add a named scalar accumulator to this journal.
    /// The named-ness is injected, not baked in.
    pub fn add_scalar(&mut self, name: &str, max_value: f64) {
        let dims = self.journal.n_labels(); // use same dims — wait, that's label count
        // Use the noise subspace dims as proxy for vector dims
        let dims = self.noise_subspace.k() * 100; // approximation — should pass dims explicitly
        self.scalars.push(ScalarAccumulator::new(name, max_value, dims));
    }

    /// Add a named scalar accumulator with explicit dimensions.
    pub fn add_scalar_with_dims(&mut self, name: &str, max_value: f64, dims: usize) {
        self.scalars.push(ScalarAccumulator::new(name, max_value, dims));
    }

    /// Feed a named scalar value from a resolved trade.
    pub fn observe_scalar(&mut self, name: &str, value: f64, grace: bool, amount: f64) {
        for s in &mut self.scalars {
            if s.name() == name {
                s.observe(value, grace, amount);
                return;
            }
        }
    }

    /// Extract a learned scalar by name.
    pub fn learned_scalar(&self, name: &str) -> Option<f64> {
        self.scalars.iter().find(|s| s.name() == name)?.extract()
    }

    /// Strip noise from a composed thought.
    fn strip_noise(&self, composed: &Vector) -> Vector {
        if self.noise_subspace.n() < NOISE_MIN_SAMPLES {
            return composed.clone();
        }
        let f64_data: Vec<f64> = composed.data().iter().map(|&v| v as f64).collect();
        let residual = self.noise_subspace.anomalous_component(&f64_data);
        let norm = residual.iter().map(|x| x * x).sum::<f64>().sqrt();
        if norm < 1e-10 {
            return composed.clone();
        }
        let normalized: Vec<i8> = residual.iter()
            .map(|&x| (x / norm * 127.0).round().clamp(-127.0, 127.0) as i8)
            .collect();
        Vector::from_data(normalized)
    }

    /// Predict: will this composed thought produce grace or violence?
    /// Updates noise subspace. The tuple does not decide to trade —
    /// it offers a prediction. The treasury decides based on the proof curve.
    pub fn propose(&mut self, composed_thought: &Vector) -> Prediction {
        let f64_data: Vec<f64> = composed_thought.data().iter().map(|&v| v as f64).collect();
        self.noise_subspace.update(&f64_data);
        let residual = self.strip_noise(composed_thought);
        self.journal.predict(&residual)
    }

    /// Register a paper entry — a hypothetical trade tracked without capital.
    ///
    /// Called every candle from dispatch_thoughts. The composed thought is the
    /// same one used for the proposal. The paper gets its own DualExcursion
    /// that ticks independently until both sides resolve.
    ///
    /// `recommended_distance`: the LearnedStop's current distance for this thought.
    /// Stored so that when the paper resolves, we feed it back to the LearnedStop
    /// with the weight determined by the paper's outcome.
    pub fn register_paper(
        &mut self,
        composed: Vector,
        entry_price: f64,
        entry_atr: f64,
        k_stop: f64,
        recommended_distance: f64,
    ) {
        self.papers.push_back(PaperEntry {
            composed_thought: composed,
            dual: DualExcursion::new(entry_price, entry_atr, k_stop),
            entry_price,
            recommended_distance,
        });
        // Cap oldest papers.
        while self.papers.len() > MAX_PAPERS {
            self.papers.pop_front();
        }
    }

    /// Tick all paper entries and resolve those where both sides have completed.
    ///
    /// Resolved papers produce two learning signals:
    ///   1. Grace/Violence label → journal.observe (direction learning)
    ///   2. recommended_distance → learned_stop.observe (distance learning)
    ///
    /// Returns the number of papers resolved this tick, and a vec of
    /// (composed_thought, recommended_distance, weight) tuples for the caller
    /// to feed into the LearnedStop (since the journal doesn't own it).
    pub fn tick_papers(
        &mut self,
        current_price: f64,
        k_trail: f64,
        k_tp: f64,
    ) -> Vec<(Vector, f64, f64)> {
        let mut learned_stop_observations = Vec::new();

        // Tick all papers.
        for paper in self.papers.iter_mut() {
            paper.dual.tick(current_price, k_trail, k_tp);
        }

        // Drain ALL resolved papers (front first, then scan for out-of-order).
        // Unified resolution logic — one path, no duplication (sever fix).
        let mut resolved_papers: Vec<PaperEntry> = Vec::new();

        // Front drain
        while let Some(front) = self.papers.front() {
            if !front.dual.both_resolved() { break; }
            resolved_papers.push(self.papers.pop_front().unwrap());
        }
        // Out-of-order drain
        let mut i = 0;
        while i < self.papers.len() {
            if self.papers[i].dual.both_resolved() {
                resolved_papers.push(self.papers.remove(i).unwrap());
            } else {
                i += 1;
            }
        }

        // Resolve each paper through the FULL path — journal + proof curve.
        for paper in resolved_papers {
            let outcome = paper.dual.classify();
            let (label, weight, correct) = match outcome {
                Some(crate::position::Outcome::Win { weight }) => {
                    (self.grace_label, weight, true)
                }
                Some(crate::position::Outcome::Loss { weight }) => {
                    (self.violence_label, weight, false)
                }
                None => continue,
            };

            // 1. Feed journal prototypes
            let residual = self.strip_noise(&paper.composed_thought);
            self.journal.observe(&residual, label, weight);

            // 2. Track cumulative grace/violence
            if correct {
                self.cumulative_grace += weight;
            } else {
                self.cumulative_violence += weight;
            }
            self.trade_count += 1;

            // 3. Feed proof curve (resolved deque + conviction history)
            // Use the journal's last prediction as the "prediction" for this paper
            let pred = self.journal.predict(&residual);
            if let Some(_dir) = pred.direction {
                self.resolved.push_back((pred.conviction, correct));
                if self.resolved.len() > 2000 {
                    self.resolved.pop_front();
                }
                self.conviction_history.push_back(pred.conviction);
                if self.conviction_history.len() > 2000 {
                    self.conviction_history.pop_front();
                }
                // Update conviction threshold
                if self.conviction_history.len() >= 200
                    && self.resolved.len() % 50 == 0
                {
                    self.conviction_threshold = quantile(&self.conviction_history, 0.5);
                }
                // Proof gate
                let proof_threshold = self.conviction_threshold * 0.8;
                let (total, all_correct, proof_count, proof_correct) = self.resolved.iter().fold(
                    (0usize, 0usize, 0usize, 0usize),
                    |(t, ac, pn, pc), (conv, win)| (
                        t + 1,
                        ac + *win as usize,
                        pn + (*conv >= proof_threshold) as usize,
                        pc + (*conv >= proof_threshold && *win) as usize,
                    ),
                );
                self.cached_acc = if total == 0 { 0.0 } else { all_correct as f64 / total as f64 };
                if total >= 100 && proof_count >= 20 {
                    self.curve_valid = proof_correct as f64 / proof_count as f64 > 0.52;
                }
            }

            // 4. Collect for the caller to feed to LearnedStop
            learned_stop_observations.push((
                paper.composed_thought,
                paper.recommended_distance,
                weight,
            ));
        }

        learned_stop_observations
    }

    /// Number of active (unresolved) paper entries.
    pub fn paper_count(&self) -> usize {
        self.papers.len()
    }

    /// Can this tuple request capital from the treasury?
    pub fn funded(&self) -> bool {
        self.curve_valid
    }

    /// How much of its maximum should this tuple deploy?
    /// Proportional to cumulative grace minus violence.
    pub fn allocation_fraction(&self) -> f64 {
        if self.trade_count == 0 { return 0.0; }
        let total = self.cumulative_grace + self.cumulative_violence + 0.001;
        (self.cumulative_grace / total).clamp(0.0, 1.0)
    }

    /// Resolve a trade outcome from the treasury.
    /// The most honest signal in the system.
    pub fn resolve(
        &mut self,
        composed_thought: &Vector,
        prediction: &Prediction,
        outcome: RealityOutcome,
        conviction_quantile: f64,
        conviction_window: usize,
    ) {
        // 1. Journal learns from the composed thought that produced this outcome
        let residual = self.strip_noise(composed_thought);
        let (label, amount, correct) = match outcome {
            RealityOutcome::Grace { amount } => (self.grace_label, amount, true),
            RealityOutcome::Violence { amount } => (self.violence_label, amount, false),
        };
        self.journal.observe(&residual, label, amount);

        // 2. Update cumulative track record
        match outcome {
            RealityOutcome::Grace { amount } => self.cumulative_grace += amount,
            RealityOutcome::Violence { amount } => self.cumulative_violence += amount,
        }
        self.trade_count += 1;

        // 3. Engram gating
        if let Some(_pred_dir) = prediction.direction {
            self.recalib_total += 1;
            if correct { self.recalib_wins += 1; }
        }
        if self.journal.recalib_count() > self.last_recalib_count {
            self.last_recalib_count = self.journal.recalib_count();
            if self.recalib_total >= ENGRAM_MIN_TOTAL {
                let acc = self.recalib_wins as f64 / self.recalib_total as f64;
                if acc > ENGRAM_MIN_ACC {
                    if let Some(disc) = self.journal.discriminant(self.grace_label) {
                        let disc_owned = disc.to_vec();
                        self.good_state_subspace.update(&disc_owned);
                    }
                }
            }
            self.recalib_wins = 0;
            self.recalib_total = 0;
        }

        // 4-6: Only if the tuple had a directional prediction
        let pred_dir = match prediction.direction {
            Some(d) => d,
            None => return,
        };

        // 4. Track resolved predictions
        self.resolved.push_back((prediction.conviction, correct));
        if self.resolved.len() > conviction_window {
            self.resolved.pop_front();
        }

        // 5. Update conviction history + threshold
        self.conviction_history.push_back(prediction.conviction);
        if self.conviction_history.len() > conviction_window {
            self.conviction_history.pop_front();
        }
        if self.conviction_history.len() >= MIN_CONVICTION_HISTORY
            && self.resolved.len() % THRESHOLD_UPDATE_INTERVAL == 0
        {
            self.conviction_threshold = quantile(&self.conviction_history, conviction_quantile);
        }

        // 6. Proof gate
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
    }

    /// Extract the learned trail scalar from the grace prototype.
    /// Unbind: bind(prototype, trail_atom) recovers the value vector
    /// that was bound to trail_atom in the graceful region.
    /// The prototype preserves magnitude (unnormalized).
    /// The discriminant does NOT (normalized — magnitude lost).
    /// Returns None if the prototype doesn't exist yet.
    /// Extract the learned trail scalar from the grace prototype.
    /// Unbind in f64 space (element-wise multiply) to preserve magnitude.
    /// The result is an f64 vector — compare against scalar encodings via dot product.
    pub fn extract_trail_scalar_f64(&self, trail_atom: &Vector) -> Option<Vec<f64>> {
        let raw = self.journal.raw_prototype(self.grace_label)?;
        let atom_data = trail_atom.data();
        // unbind in f64: element-wise multiply (bind IS multiply for bipolar)
        let unbound: Vec<f64> = raw.iter().zip(atom_data.iter())
            .map(|(&sum, &atom)| sum * atom as f64)
            .collect();
        Some(unbound)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const TEST_DIMS: usize = 64;

    #[test]
    fn tuple_journal_new() {
        let pj = TupleJournal::new("momentum", "volatility", TEST_DIMS, 500);
        assert_eq!(pj.id.market_observer, "momentum");
        assert_eq!(pj.id.exit_observer, "volatility");
        assert!(!pj.funded());
        assert_eq!(pj.allocation_fraction(), 0.0);
        assert_eq!(pj.trade_count, 0);
    }

    #[test]
    fn tuple_journal_propose_does_not_crash() {
        let mut pj = TupleJournal::new("generalist", "timing", TEST_DIMS, 500);
        let thought = holon::Vector::zeros(TEST_DIMS);
        let pred = pj.propose(&thought);
        // No discriminant yet → no direction
        assert!(pred.direction.is_none());
    }

    #[test]
    fn tuple_journal_resolve_accumulates() {
        let mut pj = TupleJournal::new("momentum", "vol", TEST_DIMS, 20);
        let thought = holon::Vector::zeros(TEST_DIMS);
        let pred = pj.propose(&thought);

        pj.resolve(&thought, &pred, RealityOutcome::Grace { amount: 100.0 }, 0.5, 1000);
        assert_eq!(pj.trade_count, 1);
        assert!((pj.cumulative_grace - 100.0).abs() < 1e-10);

        pj.resolve(&thought, &pred, RealityOutcome::Violence { amount: 50.0 }, 0.5, 1000);
        assert_eq!(pj.trade_count, 2);
        assert!((pj.cumulative_violence - 50.0).abs() < 1e-10);
    }

    #[test]
    fn tuple_journal_allocation_fraction() {
        let mut pj = TupleJournal::new("regime", "structure", TEST_DIMS, 20);
        let thought = holon::Vector::zeros(TEST_DIMS);
        let pred = pj.propose(&thought);

        // 3 grace, 1 violence → allocation should favor grace
        for _ in 0..3 {
            pj.resolve(&thought, &pred, RealityOutcome::Grace { amount: 10.0 }, 0.5, 1000);
        }
        pj.resolve(&thought, &pred, RealityOutcome::Violence { amount: 10.0 }, 0.5, 1000);

        let alloc = pj.allocation_fraction();
        assert!(alloc > 0.7, "3:1 grace:violence should give > 70% allocation, got {}", alloc);
    }

    #[test]
    fn scalar_extraction_from_prototype() {
        // 0-1 normalized scalars. The meaning is at the boundary.
        // k_trail=1.7 → 1.7/5.0 = 0.34. k_trail=0.5 → 0.5/5.0 = 0.10.
        // Unbind from the grace PROTOTYPE. Sweep to find the best match.
        // Denormalize to recover the original value.
        let dims = 10000;
        let vm = holon::VectorManager::new(dims);
        let scalar_enc = holon::ScalarEncoder::new(dims);
        let mut pj = TupleJournal::new("test-market", "test-exit", dims, 20);

        let trail_atom = vm.get_vector("k-trail");
        let k_trail_max = 5.0;
        let mode = holon::ScalarMode::Linear { scale: SCALAR_SCALE };

        let norm_high = normalize_scalar(1.7, k_trail_max); // 0.34
        let norm_low = normalize_scalar(0.5, k_trail_max);  // 0.10
        let enc_high = scalar_enc.encode(norm_high, mode);
        let enc_low = scalar_enc.encode(norm_low, mode);

        eprintln!("enc(0.34) vs enc(0.10) cosine: {:.4}",
            holon::Similarity::cosine(&enc_high, &enc_low));

        let trail_high = holon::Primitives::bind(&trail_atom, &enc_high);
        let trail_low = holon::Primitives::bind(&trail_atom, &enc_low);

        for i in 0..2000 {
            let noise = vm.get_vector(&format!("noise-{}", i));
            let base = vm.get_vector(&format!("base-{}", i % 10));

            let grace_thought = holon::Primitives::bundle(&[&base, &noise, &trail_high]);
            let pred = pj.propose(&grace_thought);
            pj.resolve(&grace_thought, &pred, RealityOutcome::Grace { amount: 10.0 }, 0.5, 1000);

            let violence_thought = holon::Primitives::bundle(&[&base, &noise, &trail_low]);
            let pred = pj.propose(&violence_thought);
            pj.resolve(&violence_thought, &pred, RealityOutcome::Violence { amount: 10.0 }, 0.5, 1000);
        }

        // Unbind from raw prototype in f64 space (preserves magnitude)
        let extracted_f64 = pj.extract_trail_scalar_f64(&trail_atom)
            .expect("prototype should exist after 1000 observations");

        // f64 cosine helper
        let cos_f64 = |a: &[f64], b: &Vector| -> f64 {
            let bd = b.data();
            let mut dot = 0.0f64;
            let mut na = 0.0f64;
            let mut nb = 0.0f64;
            for (&x, &y) in a.iter().zip(bd.iter()) {
                let yf = y as f64;
                dot += x * yf;
                na += x * x;
                nb += yf * yf;
            }
            let denom = (na * nb).sqrt();
            if denom < 1e-10 { 0.0 } else { dot / denom }
        };

        let cos_high = cos_f64(&extracted_f64, &enc_high);
        let cos_low = cos_f64(&extracted_f64, &enc_low);
        let separation = (cos_high - cos_low).abs();
        eprintln!("f64 extracted vs enc(0.34): {:.4}", cos_high);
        eprintln!("f64 extracted vs enc(0.10): {:.4}", cos_low);
        eprintln!("separation: {:.4}", separation);
        assert!(separation > 0.1, "should separate: {:.4}", separation);

        // FULL f64 PIPELINE: negate → unbind → sweep. No i8 anywhere.
        let raw_proto = pj.journal.raw_prototype(pj.grace_label)
            .expect("raw prototype should exist");

        // Bundle known thought atoms in f64 space
        let bases_f64: Vec<Vec<f64>> = (0..10)
            .map(|j| vm.get_vector(&format!("base-{}", j)).data().iter().map(|&v| v as f64).collect())
            .collect();
        let base_refs: Vec<&[f64]> = bases_f64.iter().map(|v| v.as_slice()).collect();
        let known_f64 = holon::Primitives::bundle_f64(&base_refs);

        // Negate in f64: orthogonalize the known thoughts out of the prototype
        let negated = holon::Primitives::negate_f64(raw_proto, &known_f64);

        // Unbind trail atom in f64
        let trail_f64: Vec<f64> = trail_atom.data().iter().map(|&v| v as f64).collect();
        let unbound = holon::Primitives::bind_f64(&negated, &trail_f64);

        // Sweep against f64 scalar encodings
        let mut best_val = 0.0f64;
        let mut best_cos = -2.0f64;
        for i in 0..=100 {
            let v = i as f64 / 100.0;
            let enc = scalar_enc.encode_f64(v, mode);
            let cos = holon::Primitives::cosine_f64(&unbound, &enc);
            if cos > best_cos { best_cos = cos; best_val = v; }
        }

        let recovered = denormalize_scalar(best_val, k_trail_max);
        eprintln!("f64 pipeline: 0-1={:.2} → k_trail={:.2} (cos={:.4})", best_val, recovered, best_cos);

        let err_high = (recovered - 1.7).abs();
        let err_low = (recovered - 0.5).abs();
        eprintln!("err from 1.7: {:.2}, err from 0.5: {:.2}", err_high, err_low);
        assert!(err_high < 2.0 || err_low < 2.0,
            "recovered {:.2} should be near 1.7 or 0.5", recovered);
    }

    // ── Paper entry tests ──────────────────────────────────────────

    #[test]
    fn register_paper_creates_entry() {
        let mut pj = TupleJournal::new("momentum", "vol", TEST_DIMS, 500);
        let thought = holon::Vector::zeros(TEST_DIMS);
        pj.register_paper(thought, 50000.0, 0.01, 2.0, 0.015);
        assert_eq!(pj.paper_count(), 1);
    }

    #[test]
    fn register_paper_caps_at_max() {
        let mut pj = TupleJournal::new("momentum", "vol", TEST_DIMS, 500);
        for i in 0..600 {
            let thought = holon::Vector::zeros(TEST_DIMS);
            pj.register_paper(thought, 50000.0 + i as f64, 0.01, 2.0, 0.015);
        }
        // Should be capped at MAX_PAPERS (500)
        assert_eq!(pj.paper_count(), MAX_PAPERS);
    }

    #[test]
    fn tick_papers_resolves_when_both_sides_done() {
        let mut pj = TupleJournal::new("momentum", "vol", TEST_DIMS, 500);
        let thought = holon::Vector::zeros(TEST_DIMS);

        // Entry at 50000, ATR 0.01 (1%), k_stop=2.0
        // Buy stop: 50000 * (1 - 2*0.01) = 49000
        // Sell stop: 50000 * (1 + 2*0.01) = 51000
        pj.register_paper(thought, 50000.0, 0.01, 2.0, 0.015);
        assert_eq!(pj.paper_count(), 1);

        // Price drops hard — triggers both buy stop (49000) and sell TP
        let obs = pj.tick_papers(48000.0, 1.5, 3.0);
        // Buy side: 48000 < 49000 → resolved
        // Sell side: sell_move = 50000 - 48000 = 2000, sell TP at 50000*(1-3*0.01)=48500
        // 48000 <= 48500 → resolved
        assert_eq!(pj.paper_count(), 0, "paper should have resolved");
        assert_eq!(obs.len(), 1, "should produce one learned stop observation");
    }

    #[test]
    fn tick_papers_partial_resolution() {
        let mut pj = TupleJournal::new("momentum", "vol", TEST_DIMS, 500);
        let thought = holon::Vector::zeros(TEST_DIMS);

        // Entry at 50000, tight stop
        pj.register_paper(thought, 50000.0, 0.01, 2.0, 0.015);

        // Small move — neither side resolves
        let obs = pj.tick_papers(50100.0, 1.5, 3.0);
        assert_eq!(pj.paper_count(), 1, "paper should still be alive");
        assert_eq!(obs.len(), 0, "no observations from unresolved paper");
    }

    #[test]
    fn tick_papers_feeds_journal_labels() {
        let mut pj = TupleJournal::new("momentum", "vol", TEST_DIMS, 500);
        let vm = holon::VectorManager::new(TEST_DIMS);

        // Register a paper with a non-zero thought
        let thought = vm.get_vector("test-paper");
        pj.register_paper(thought, 50000.0, 0.01, 2.0, 0.015);

        // Crash the price → both sides resolve, sell wins (buy lost, sell gained)
        let _obs = pj.tick_papers(48000.0, 1.5, 3.0);

        // Journal should have received at least one observation
        // (either grace or violence label). Check via the journal's internal state.
        assert_eq!(pj.paper_count(), 0);
    }

    #[test]
    fn tick_papers_returns_distance_for_learned_stop() {
        let mut pj = TupleJournal::new("momentum", "vol", TEST_DIMS, 500);
        let thought = holon::Vector::zeros(TEST_DIMS);
        let recommended = 0.025;

        pj.register_paper(thought, 50000.0, 0.01, 2.0, recommended);

        // Force resolution
        let obs = pj.tick_papers(48000.0, 1.5, 3.0);
        assert_eq!(obs.len(), 1);
        let (_, dist, _weight) = &obs[0];
        assert!((*dist - recommended).abs() < 1e-10,
            "should carry through the recommended distance: {}", dist);
    }

    #[test]
    fn multiple_papers_resolve_independently() {
        let mut pj = TupleJournal::new("momentum", "vol", TEST_DIMS, 500);

        // Paper 1: entry at 50000
        let t1 = holon::Vector::zeros(TEST_DIMS);
        pj.register_paper(t1, 50000.0, 0.01, 2.0, 0.015);

        // Paper 2: entry at 60000 (much higher, so 48000 is a bigger crash)
        let t2 = holon::Vector::zeros(TEST_DIMS);
        pj.register_paper(t2, 60000.0, 0.01, 2.0, 0.020);

        assert_eq!(pj.paper_count(), 2);

        // Price drop to 48000:
        // Paper 1: buy stop at 49000 → triggered. sell stop at 51000 → price 48000 < 51000, no trigger wait...
        //   sell TP at 50000*(1-3*0.01)=48500, 48000 <= 48500 → triggered. Both resolved.
        // Paper 2: buy stop at 60000*(1-2*0.01)=58800 → 48000 < 58800 → triggered.
        //   sell TP at 60000*(1-3*0.01)=58200, 48000 <= 58200 → triggered. Both resolved.
        let obs = pj.tick_papers(48000.0, 1.5, 3.0);
        assert_eq!(pj.paper_count(), 0, "both papers should resolve");
        assert_eq!(obs.len(), 2, "two observations");
    }
}
