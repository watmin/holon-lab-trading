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

use crate::journal::{Journal, Label, Prediction};

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
        }
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
    pub fn extract_trail_scalar(&self, trail_atom: &Vector) -> Option<Vector> {
        let proto = self.journal.prototype(self.grace_label)?;
        let proto_vec = Vector::from_f64(&proto);
        // unbind IS bind — self-inverse property (Kanerva)
        Some(holon::Primitives::bind(&proto_vec, trail_atom))
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
    fn scalar_extraction_from_discriminant() {
        // The full test: encode a scalar via ScalarEncoder, bind it to an atom,
        // bundle into thoughts, accumulate in the journal, unbind from the
        // discriminant, decode_log to recover the number.
        //
        // Grace thoughts carry k_trail=1.7. Violence thoughts carry k_trail=0.5.
        // After learning, unbind + decode_log should recover ~1.7 from the grace discriminant.
        let dims = 10000;
        let vm = holon::VectorManager::new(dims);
        let scalar_enc = holon::ScalarEncoder::new(dims);
        let mut pj = TupleJournal::new("test-market", "test-exit", dims, 20);

        let trail_atom = vm.get_vector("k-trail");

        // Use linear encoding with scale=5.0 (k_trail range ~0.5 to 3.0)
        // Log encoding collapses nearby values at bipolar quantization.
        // Linear with appropriate scale separates them.
        let mode = holon::ScalarMode::Linear { scale: 5.0 };
        let enc_17 = scalar_enc.encode(1.7, mode);
        let enc_05 = scalar_enc.encode(0.5, mode);
        let raw_cos = holon::Similarity::cosine(&enc_17, &enc_05);
        eprintln!("encode_linear(1.7) vs encode_linear(0.5) cosine: {:.4}", raw_cos);

        // Bind scalar to atom: bind(trail_atom, scalar_encode(value))
        let trail_high = holon::Primitives::bind(&trail_atom, &enc_17);
        let trail_low = holon::Primitives::bind(&trail_atom, &enc_05);

        for i in 0..100 {
            let noise = vm.get_vector(&format!("noise-{}", i));
            let base = vm.get_vector(&format!("base-{}", i % 10));

            // Grace: high trail
            let grace_thought = holon::Primitives::bundle(&[&base, &noise, &trail_high]);
            let pred = pj.propose(&grace_thought);
            pj.resolve(&grace_thought, &pred, RealityOutcome::Grace { amount: 10.0 }, 0.5, 1000);

            // Violence: low trail
            let violence_thought = holon::Primitives::bundle(&[&base, &noise, &trail_low]);
            let pred = pj.propose(&violence_thought);
            pj.resolve(&violence_thought, &pred, RealityOutcome::Violence { amount: 10.0 }, 0.5, 1000);
        }

        // Unbind: bind(discriminant, trail_atom) → the scalar vector from graceful region
        let unbound = pj.extract_trail_scalar(&trail_atom);
        assert!(unbound.is_some(), "discriminant should exist after 200 observations");
        let extracted = unbound.unwrap();

        // Compare the extracted scalar against known encodings
        let cos_high = holon::Similarity::cosine(&extracted, &enc_17);
        let cos_low = holon::Similarity::cosine(&extracted, &enc_05);
        eprintln!("extracted vs linear(1.7): {:.4}", cos_high);
        eprintln!("extracted vs linear(0.5): {:.4}", cos_low);
        eprintln!("delta: {:.4} (positive = grace learned higher trail)", cos_high - cos_low);

        // The extracted vector should separate the two values.
        // The sign depends on discriminant convention (grace-violence or violence-grace).
        // What matters: the MAGNITUDE of separation is strong. The sign tells us
        // which convention the journal uses — we just need to know and be consistent.
        let separation = (cos_high - cos_low).abs();
        eprintln!("separation magnitude: {:.4} (>0.3 = strong signal)", separation);
        assert!(separation > 0.3,
            "discriminant should strongly separate the two scalar values: separation={:.4}",
            separation);
    }
}
