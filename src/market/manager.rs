//! Manager encoding — observer opinions become the manager's thought.
//!
//! Spec: wat/manager.wat
//!
//! The manager thinks in observer opinions, not candle data.
//! Each observer contributes: opinion (direction + magnitude) + credibility (proven/tentative)
//! Plus: panel shape, market context, time, motion.

use std::collections::VecDeque;

use holon::{Primitives, ScalarMode, Similarity, VectorManager, Vector};

use crate::journal::Prediction;

// ── Constants ──────────────────────────────────────────────────────
const BAND_MIN_RESOLVED: usize = 500;
const BAND_MIN_PER_BAND: usize = 200;
const BAND_MIN_ACCURACY: f64 = 0.51;
const MIN_RESOLVED_FOR_RELIABILITY: usize = 20;
const MIN_RESOLVED_FOR_TENURE: f64 = 50.0;

/// Everything the manager needs to encode one candle's thought.
pub struct ManagerContext<'a> {
    pub observer_preds: &'a [Prediction],
    pub observer_atoms: &'a [Vector],
    pub observer_curve_valid: &'a [bool],
    pub observer_resolved_lens: &'a [usize],
    pub observer_resolved_accs: &'a [f64],  // rolling accuracy per observer
    pub observer_vecs: &'a [Vector],        // observer thought vectors (for coherence)
    pub generalist_pred: &'a Prediction,
    pub generalist_atom: &'a Vector,
    pub generalist_curve_valid: bool,
    pub candle_atr: f64,
    pub candle_hour: f64,
    pub candle_day: f64,
    pub disc_strength: f64,
}

/// Atoms the manager uses. Created once at startup.
pub struct ManagerAtoms {
    pub buy: Vector,
    pub sell: Vector,
    pub proven: Vector,
    pub tentative: Vector,
    pub reliability: Vector,
    pub tenure: Vector,
    pub agreement: Vector,
    pub energy: Vector,
    pub divergence: Vector,
    pub coherence: Vector,
    pub volatility: Vector,
    pub disc_strength: Vector,
    pub hour: Vector,
    pub day: Vector,
    pub delta: Vector,
}

impl ManagerAtoms {
    pub fn new(vm: &VectorManager) -> Self {
        Self {
            buy: vm.get_vector("buy"),
            sell: vm.get_vector("sell"),
            proven: vm.get_vector("proven"),
            tentative: vm.get_vector("tentative"),
            reliability: vm.get_vector("observer-reliability"),
            tenure: vm.get_vector("observer-tenure"),
            agreement: vm.get_vector("panel-agreement"),
            energy: vm.get_vector("panel-energy"),
            divergence: vm.get_vector("panel-divergence"),
            coherence: vm.get_vector("panel-coherence"),
            volatility: vm.get_vector("market-volatility"),
            disc_strength: vm.get_vector("disc-strength"),
            hour: vm.get_vector("hour-of-day"),
            day: vm.get_vector("day-of-week"),
            delta: vm.get_vector("panel-delta"),
        }
    }
}

/// 3sigma — below this, cosine is random noise in the hyperspace.
pub fn noise_floor(dims: usize) -> f64 {
    3.0 / (dims as f64).sqrt()
}

/// Find the manager's proven conviction band via sigma-band scan.
///
/// Iterates bands `[k*σ, (k+4)*σ]` for k in 3..18, requiring 200+ samples
/// and accuracy > 0.51. Returns the band with best accuracy, or None.
pub fn find_proven_band(
    resolved: &VecDeque<(f64, bool)>,
    dims: usize,
) -> Option<(f64, f64, f64)> {
    if resolved.len() < BAND_MIN_RESOLVED {
        return None;
    }
    let sigma = 1.0 / (dims as f64).sqrt();
    let mut best_acc = 0.5_f64;
    let mut best_band = (0.0_f64, 0.0_f64);
    for k in 3..18 {
        let lo = k as f64 * sigma;
        let hi = (k + 4) as f64 * sigma;
        let (n, correct) = resolved.iter()
            .filter(|(c, _)| *c >= lo && *c < hi)
            .fold((0usize, 0usize), |(n, correct), (_, w)| (n + 1, correct + *w as usize));
        if n >= BAND_MIN_PER_BAND {
            let acc = correct as f64 / n as f64;
            if acc > best_acc {
                best_acc = acc;
                best_band = (lo, hi);
            }
        }
    }
    if best_acc > BAND_MIN_ACCURACY {
        Some((best_band.0, best_band.1, best_acc))
    } else {
        None
    }
}


/// Encode one observer's contribution to the manager's thought.
/// Returns facts (may be empty if below noise floor).
fn encode_observer_opinion(
    atoms: &ManagerAtoms,
    scalar: &holon::ScalarEncoder,
    observer_atom: &Vector,
    pred: &Prediction,
    curve_valid: bool,
    resolved_len: usize,
    resolved_acc: f64,
    min_opinion: f64,
) -> Vec<Vector> {
    let abs_cos = pred.raw_cos.abs();
    if abs_cos < min_opinion {
        return Vec::new();
    }

    let mut facts = Vec::with_capacity(4);

    // Fact 1: opinion — direction + magnitude
    let magnitude = scalar.encode(abs_cos, ScalarMode::Linear { scale: 1.0 });
    let action = if pred.raw_cos >= 0.0 { &atoms.buy } else { &atoms.sell };
    let opinion = Primitives::bind(action, &magnitude);
    facts.push(Primitives::bind(observer_atom, &opinion));

    // Fact 2: credibility — proven or tentative
    let status = if curve_valid { &atoms.proven } else { &atoms.tentative };
    facts.push(Primitives::bind(observer_atom, status));

    // Fact 3: reliability — accuracy above baseline (if enough data)
    if resolved_len >= MIN_RESOLVED_FOR_RELIABILITY {
        let reliability_vec = scalar.encode((resolved_acc - 0.4).max(0.0), ScalarMode::Linear { scale: 1.0 });
        facts.push(Primitives::bind(
            &Primitives::bind(observer_atom, &atoms.reliability), &reliability_vec));
    }

    // Fact 4: tenure — how long has this observer been resolving?
    let tenure = resolved_len as f64;
    if tenure >= MIN_RESOLVED_FOR_TENURE {
        let tenure_vec = scalar.encode_log(tenure);
        facts.push(Primitives::bind(
            &Primitives::bind(observer_atom, &atoms.tenure), &tenure_vec));
    }

    facts
}

/// Panel-level facts from proven observer predictions.
/// Needs 2+ proven observers.
fn panel_shape(
    atoms: &ManagerAtoms,
    scalar: &holon::ScalarEncoder,
    ctx: &ManagerContext,
) -> Vec<Vector> {
    let proven_indices: Vec<usize> = ctx.observer_curve_valid.iter().enumerate()
        .filter(|(_, &valid)| valid)
        .map(|(i, _)| i)
        .collect();

    if proven_indices.len() < 2 {
        return Vec::new();
    }

    let total = proven_indices.len();

    // Single fold: buys, total conviction, sum of squared convictions
    let (buys, sum_conv, sum_sq_conv) = proven_indices.iter().fold(
        (0usize, 0.0_f64, 0.0_f64),
        |(b, sc, ssq), &i| {
            let p = &ctx.observer_preds[i];
            (
                b + (p.raw_cos > 0.0) as usize,
                sc + p.conviction,
                ssq + p.conviction * p.conviction,
            )
        },
    );
    let mean_conv = sum_conv / total as f64;
    let spread = (sum_sq_conv / total as f64 - mean_conv * mean_conv).max(0.0).sqrt();

    let mut facts = Vec::with_capacity(4);

    // Agreement
    let agreement = (buys.max(total - buys) as f64) / total as f64;
    facts.push(Primitives::bind(&atoms.agreement,
        &scalar.encode(agreement, ScalarMode::Linear { scale: 1.0 })));

    // Energy — mean conviction
    facts.push(Primitives::bind(&atoms.energy,
        &scalar.encode(mean_conv, ScalarMode::Linear { scale: 1.0 })));

    // Divergence — spread of convictions
    facts.push(Primitives::bind(&atoms.divergence,
        &scalar.encode(spread, ScalarMode::Linear { scale: 1.0 })));

    // Coherence — mean pairwise cosine between proven thought vectors
    let proven_vecs: Vec<&Vector> = proven_indices.iter()
        .map(|&i| &ctx.observer_vecs[i])
        .collect();
    if proven_vecs.len() >= 2 {
        let mut pair_sum = 0.0_f64;
        let mut pair_count = 0usize;
        for a in 0..proven_vecs.len() {
            for b in (a + 1)..proven_vecs.len() {
                pair_sum += Similarity::cosine(proven_vecs[a], proven_vecs[b]);
                pair_count += 1;
            }
        }
        let coherence = if pair_count > 0 { pair_sum / pair_count as f64 } else { 0.0 };
        facts.push(Primitives::bind(&atoms.coherence,
            &scalar.encode(coherence.abs(), ScalarMode::Linear { scale: 1.0 })));
    }

    facts
}

/// Market-level context facts: volatility, discriminant quality, time.
fn market_context(
    atoms: &ManagerAtoms,
    scalar: &holon::ScalarEncoder,
    ctx: &ManagerContext,
) -> Vec<Vector> {
    vec![
        Primitives::bind(&atoms.volatility,
            &scalar.encode_log(ctx.candle_atr.max(1e-10))),
        Primitives::bind(&atoms.disc_strength,
            &scalar.encode_log(ctx.disc_strength.max(1e-10))),
        Primitives::bind(&atoms.hour,
            &scalar.encode(ctx.candle_hour, ScalarMode::Circular { period: 24.0 })),
        Primitives::bind(&atoms.day,
            &scalar.encode(ctx.candle_day, ScalarMode::Circular { period: 7.0 })),
    ]
}

/// Encode the manager's thought from observer opinions.
/// This is Layer 2 from enterprise.wat — called once per candle at prediction time,
/// and reconstructed at resolution time.
pub fn encode_manager_thought(
    ctx: &ManagerContext,
    atoms: &ManagerAtoms,
    scalar: &holon::ScalarEncoder,
    min_opinion: f64,
) -> Vec<Vector> {
    let mut facts: Vec<Vector> = Vec::with_capacity(30);

    // Per-observer opinions
    for i in 0..ctx.observer_preds.len() {
        facts.extend(encode_observer_opinion(
            atoms, scalar,
            &ctx.observer_atoms[i],
            &ctx.observer_preds[i],
            ctx.observer_curve_valid[i],
            ctx.observer_resolved_lens[i],
            ctx.observer_resolved_accs[i],
            min_opinion,
        ));
    }

    // Generalist — same encoding, just from generalist fields
    facts.extend(encode_observer_opinion(
        atoms, scalar,
        ctx.generalist_atom,
        ctx.generalist_pred,
        ctx.generalist_curve_valid,
        0, 0.0,  // generalist doesn't track per-observer reliability/tenure
        min_opinion,
    ));

    // Panel shape
    facts.extend(panel_shape(atoms, scalar, ctx));

    // Market context
    facts.extend(market_context(atoms, scalar, ctx));

    facts
}

/// Bundle manager facts into a single thought, enriched with motion (delta from previous).
/// Returns (final_thought, raw_thought_for_next_delta).
/// The raw thought is stored by the caller for next candle's delta computation.
pub fn bundle_manager_thought(
    facts: Vec<Vector>,
    prev_thought: Option<&Vector>,
    atoms: &ManagerAtoms,
) -> Option<(Vector, Vector)> {
    if facts.is_empty() { return None; }
    let refs: Vec<&Vector> = facts.iter().collect();
    let raw = Primitives::bundle(&refs);
    let final_thought = if let Some(prev) = prev_thought {
        let delta = Primitives::difference(prev, &raw);
        let delta_bound = Primitives::bind(&atoms.delta, &delta);
        Primitives::bundle(&[&raw, &delta_bound])
    } else {
        raw.clone()
    };
    Some((final_thought, raw))
}

#[cfg(test)]
mod tests {
    use super::*;
    use holon::{ScalarEncoder, VectorManager};

    const TEST_DIMS: usize = 64;

    fn make_vm() -> VectorManager {
        VectorManager::new(TEST_DIMS)
    }

    fn make_prediction(raw_cos: f64, conviction: f64) -> Prediction {
        Prediction {
            scores: Vec::new(),
            direction: None,
            conviction,
            raw_cos,
        }
    }

    fn make_ctx<'a>(
        observer_preds: &'a [Prediction],
        observer_atoms: &'a [Vector],
        observer_curve_valid: &'a [bool],
        observer_resolved_lens: &'a [usize],
        observer_resolved_accs: &'a [f64],
        observer_vecs: &'a [Vector],
        generalist_pred: &'a Prediction,
        generalist_atom: &'a Vector,
    ) -> ManagerContext<'a> {
        ManagerContext {
            observer_preds,
            observer_atoms,
            observer_curve_valid,
            observer_resolved_lens,
            observer_resolved_accs,
            observer_vecs,
            generalist_pred,
            generalist_atom,
            generalist_curve_valid: false,
            candle_atr: 0.02,
            candle_hour: 14.0,
            candle_day: 3.0,
            disc_strength: 0.5,
        }
    }

    #[test]
    fn manager_atoms_new_does_not_panic() {
        let vm = make_vm();
        let _atoms = ManagerAtoms::new(&vm);
    }

    #[test]
    fn encode_observer_opinion_returns_nonzero_vector() {
        let vm = make_vm();
        let atoms = ManagerAtoms::new(&vm);
        let scalar = ScalarEncoder::new(TEST_DIMS);
        let observer_atom = vm.get_vector("test-observer");
        let pred = make_prediction(0.3, 0.3);

        let facts = encode_observer_opinion(
            &atoms, &scalar, &observer_atom, &pred,
            true,  // curve_valid
            100,   // resolved_len (>= MIN_RESOLVED_FOR_RELIABILITY=20)
            0.55,  // resolved_acc
            0.01,  // min_opinion (below 0.3)
        );

        assert!(!facts.is_empty(), "should produce at least one fact");
        for fact in &facts {
            assert!(fact.data().iter().any(|&x| x != 0), "fact should be non-zero");
        }
    }

    #[test]
    fn encode_observer_opinion_below_noise_floor_returns_empty() {
        let vm = make_vm();
        let atoms = ManagerAtoms::new(&vm);
        let scalar = ScalarEncoder::new(TEST_DIMS);
        let observer_atom = vm.get_vector("test-observer");
        let pred = make_prediction(0.01, 0.01);

        let facts = encode_observer_opinion(
            &atoms, &scalar, &observer_atom, &pred,
            false, 0, 0.0,
            0.5,  // min_opinion higher than pred.raw_cos.abs()
        );

        assert!(facts.is_empty(), "should return empty below min_opinion");
    }

    #[test]
    fn encode_observer_opinion_includes_reliability_and_tenure() {
        let vm = make_vm();
        let atoms = ManagerAtoms::new(&vm);
        let scalar = ScalarEncoder::new(TEST_DIMS);
        let observer_atom = vm.get_vector("test-observer");
        let pred = make_prediction(0.5, 0.5);

        // With enough resolved (>= 20 for reliability, >= 50 for tenure)
        let facts = encode_observer_opinion(
            &atoms, &scalar, &observer_atom, &pred,
            true, 100, 0.6, 0.01,
        );
        // Should have: opinion, credibility, reliability, tenure = 4 facts
        assert_eq!(facts.len(), 4, "should have opinion + credibility + reliability + tenure");
    }

    #[test]
    fn encode_manager_thought_nonempty_with_observers() {
        let vm = make_vm();
        let atoms = ManagerAtoms::new(&vm);
        let scalar = ScalarEncoder::new(TEST_DIMS);

        let preds = vec![make_prediction(0.4, 0.4)];
        let obs_atoms = vec![vm.get_vector("obs-0")];
        let curve_valid = vec![true];
        let resolved_lens = vec![100_usize];
        let resolved_accs = vec![0.55_f64];
        let obs_vecs = vec![vm.get_vector("obs-vec-0")];
        let gen_pred = make_prediction(0.3, 0.3);
        let gen_atom = vm.get_vector("generalist");

        let ctx = make_ctx(
            &preds, &obs_atoms, &curve_valid,
            &resolved_lens, &resolved_accs, &obs_vecs,
            &gen_pred, &gen_atom,
        );

        let facts = encode_manager_thought(&ctx, &atoms, &scalar, 0.01);
        assert!(!facts.is_empty(), "should produce facts with active observers");
    }

    #[test]
    fn bundle_manager_thought_no_prev_returns_thought_eq_raw() {
        let vm = make_vm();
        let atoms = ManagerAtoms::new(&vm);
        let v1 = vm.get_vector("fact-1");
        let v2 = vm.get_vector("fact-2");

        let facts = vec![v1, v2];
        let result = bundle_manager_thought(facts, None, &atoms);
        assert!(result.is_some());
        let (thought, raw) = result.unwrap();
        // With no prev, thought == raw
        assert_eq!(thought.data(), raw.data());
    }

    #[test]
    fn bundle_manager_thought_with_prev_includes_delta() {
        let vm = make_vm();
        let atoms = ManagerAtoms::new(&vm);
        let v1 = vm.get_vector("fact-1");
        let v2 = vm.get_vector("fact-2");
        let prev = vm.get_vector("prev-thought");

        let facts = vec![v1, v2];
        let result = bundle_manager_thought(facts, Some(&prev), &atoms);
        assert!(result.is_some());
        let (thought, raw) = result.unwrap();
        // With prev, thought != raw (delta is folded in)
        assert_ne!(thought.data(), raw.data());
    }

    #[test]
    fn bundle_manager_thought_empty_returns_none() {
        let vm = make_vm();
        let atoms = ManagerAtoms::new(&vm);
        let result = bundle_manager_thought(Vec::new(), None, &atoms);
        assert!(result.is_none());
    }

    #[test]
    fn find_proven_band_empty_returns_none() {
        let data = VecDeque::new();
        assert!(find_proven_band(&data, TEST_DIMS).is_none());
    }

    #[test]
    fn find_proven_band_insufficient_data_returns_none() {
        let mut data = VecDeque::new();
        // Only 100 entries, need 500
        for _ in 0..100 {
            data.push_back((0.5, true));
        }
        assert!(find_proven_band(&data, TEST_DIMS).is_none());
    }

    #[test]
    fn find_proven_band_with_sufficient_accurate_data() {
        let sigma = 1.0 / (TEST_DIMS as f64).sqrt();
        let mut data = VecDeque::new();
        // Fill with 600 entries, conviction in band k=5: [5*sigma, 9*sigma]
        let target_conv = 6.0 * sigma;
        for _ in 0..300 {
            data.push_back((target_conv, true));   // 70% correct in this band
        }
        for _ in 0..100 {
            data.push_back((target_conv, false));
        }
        // Add some outside the band to reach 500+ total
        for _ in 0..200 {
            data.push_back((0.01 * sigma, true));  // outside all bands
        }
        let result = find_proven_band(&data, TEST_DIMS);
        assert!(result.is_some(), "should find a band with 75% accuracy and 400 samples");
        let (lo, hi, acc) = result.unwrap();
        assert!(lo > 0.0);
        assert!(hi > lo);
        assert!(acc > BAND_MIN_ACCURACY);
    }
}
