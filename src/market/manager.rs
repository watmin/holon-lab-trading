//! Manager encoding — observer opinions become the manager's thought.
//!
//! Spec: wat/manager.wat
//!
//! The manager thinks in observer opinions, not candle data.
//! Each observer contributes: opinion (direction + magnitude) + credibility (proven/tentative)
//! Plus: panel shape, market context, time, motion.

use holon::{Primitives, ScalarMode, Similarity, VectorManager, Vector};

use crate::journal::Prediction;

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
            reliability: vm.get_vector("expert-reliability"),
            tenure: vm.get_vector("expert-tenure"),
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

/// 5sigma — conviction level where signal typically emerges.
pub fn sweet_spot(dims: usize) -> f64 {
    5.0 / (dims as f64).sqrt()
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
    if resolved_len >= 20 {
        let rel = scalar.encode((resolved_acc - 0.4).max(0.0), ScalarMode::Linear { scale: 1.0 });
        facts.push(Primitives::bind(
            &Primitives::bind(observer_atom, &atoms.reliability), &rel));
    }

    // Fact 4: tenure — how long has this observer been resolving?
    let tenure = resolved_len as f64;
    if tenure >= 50.0 {
        let ten = scalar.encode_log(tenure);
        facts.push(Primitives::bind(
            &Primitives::bind(observer_atom, &atoms.tenure), &ten));
    }

    facts
}

/// Panel-level facts from proven observer predictions.
/// Needs 2+ proven observers. Takes only what it reads.
fn panel_shape(
    atoms: &ManagerAtoms,
    scalar: &holon::ScalarEncoder,
    curve_valid: &[bool],
    preds: &[Prediction],
    vecs: &[Vector],
) -> Vec<Vector> {
    let proven_indices: Vec<usize> = curve_valid.iter().enumerate()
        .filter(|(_, &valid)| valid)
        .map(|(i, _)| i)
        .collect();

    if proven_indices.len() < 2 {
        return Vec::new();
    }

    let proven_preds: Vec<&Prediction> = proven_indices.iter()
        .map(|&i| &preds[i])
        .collect();
    let total = proven_preds.len();
    let buys = proven_preds.iter().filter(|p| p.raw_cos > 0.0).count();

    let mut facts = Vec::with_capacity(4);

    // Agreement
    let agreement = (buys.max(total - buys) as f64) / total as f64;
    facts.push(Primitives::bind(&atoms.agreement,
        &scalar.encode(agreement, ScalarMode::Linear { scale: 1.0 })));

    // Energy — mean conviction
    let mean_conv = proven_preds.iter().map(|p| p.conviction).sum::<f64>() / total as f64;
    facts.push(Primitives::bind(&atoms.energy,
        &scalar.encode(mean_conv, ScalarMode::Linear { scale: 1.0 })));

    // Divergence — spread of convictions
    let variance = proven_preds.iter()
        .map(|p| (p.conviction - mean_conv).powi(2))
        .sum::<f64>() / total as f64;
    facts.push(Primitives::bind(&atoms.divergence,
        &scalar.encode(variance.sqrt(), ScalarMode::Linear { scale: 1.0 })));

    // Coherence — mean pairwise cosine between proven thought vectors
    let proven_vecs: Vec<&Vector> = proven_indices.iter()
        .map(|&i| &vecs[i])
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
/// Takes only the 4 scalars it needs — testable without ManagerContext.
fn market_context(
    atoms: &ManagerAtoms,
    scalar: &holon::ScalarEncoder,
    atr: f64,
    disc_strength: f64,
    hour: f64,
    day: f64,
) -> Vec<Vector> {
    vec![
        Primitives::bind(&atoms.volatility,
            &scalar.encode_log(atr.max(1e-10))),
        Primitives::bind(&atoms.disc_strength,
            &scalar.encode_log(disc_strength.max(1e-10))),
        Primitives::bind(&atoms.hour,
            &scalar.encode(hour, ScalarMode::Circular { period: 24.0 })),
        Primitives::bind(&atoms.day,
            &scalar.encode(day, ScalarMode::Circular { period: 7.0 })),
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
    let mut facts: Vec<Vector> = Vec::new();

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
    facts.extend(panel_shape(atoms, scalar,
        ctx.observer_curve_valid, ctx.observer_preds, ctx.observer_vecs));

    // Market context
    facts.extend(market_context(atoms, scalar,
        ctx.candle_atr, ctx.disc_strength, ctx.candle_hour, ctx.candle_day));

    facts
}
