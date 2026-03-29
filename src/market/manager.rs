//! Manager encoding — observer opinions become the manager's thought.
//!
//! Spec: wat/manager.wat
//!
//! The manager thinks in observer opinions, not candle data.
//! Each expert contributes: opinion (direction + magnitude) + credibility (proven/tentative)
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
    pub observer_vecs: &'a [Vector],        // expert thought vectors (for coherence)
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

    // Per-expert: opinion + credibility + reliability + tenure
    for (ei, ep) in ctx.observer_preds.iter().enumerate() {
        let abs_cos = ep.raw_cos.abs();
        if abs_cos < min_opinion { continue; }

        // Opinion: bind(expert, bind(action, magnitude))
        let magnitude = scalar.encode(abs_cos, ScalarMode::Linear { scale: 1.0 });
        let action = if ep.raw_cos >= 0.0 { &atoms.buy } else { &atoms.sell };
        let opinion = Primitives::bind(action, &magnitude);
        facts.push(Primitives::bind(&ctx.observer_atoms[ei], &opinion));

        // Credibility: bind(expert, proven|tentative)
        let status = if ctx.observer_curve_valid[ei] { &atoms.proven } else { &atoms.tentative };
        facts.push(Primitives::bind(&ctx.observer_atoms[ei], status));

        // Reliability: bind(bind(expert, reliability), accuracy)
        if ctx.observer_resolved_lens[ei] >= 20 {
            let acc = ctx.observer_resolved_accs[ei];
            let rel = scalar.encode((acc - 0.4).max(0.0), ScalarMode::Linear { scale: 1.0 });
            facts.push(Primitives::bind(
                &Primitives::bind(&ctx.observer_atoms[ei], &atoms.reliability), &rel));
        }

        // Tenure: bind(bind(expert, tenure), count)
        let tenure = ctx.observer_resolved_lens[ei] as f64;
        if tenure >= 50.0 {
            let ten = scalar.encode_log(tenure);
            facts.push(Primitives::bind(
                &Primitives::bind(&ctx.observer_atoms[ei], &atoms.tenure), &ten));
        }
    }

    // Generalist
    if ctx.generalist_curve_valid && ctx.generalist_pred.raw_cos.abs() >= min_opinion {
        let gen_mag = scalar.encode(ctx.generalist_pred.raw_cos.abs(), ScalarMode::Linear { scale: 1.0 });
        let gen_action = if ctx.generalist_pred.raw_cos >= 0.0 { &atoms.buy } else { &atoms.sell };
        let gen_opinion = Primitives::bind(gen_action, &gen_mag);
        facts.push(Primitives::bind(ctx.generalist_atom, &gen_opinion));

        let gen_status = if ctx.generalist_curve_valid { &atoms.proven } else { &atoms.tentative };
        facts.push(Primitives::bind(ctx.generalist_atom, gen_status));
    }

    // Panel shape (needs 2+ proven experts)
    let proven_preds: Vec<&Prediction> = ctx.observer_preds.iter().enumerate()
        .filter(|(ei, _)| ctx.observer_curve_valid[*ei])
        .map(|(_, ep)| ep)
        .collect();

    if proven_preds.len() >= 2 {
        let buys = proven_preds.iter().filter(|p| p.raw_cos > 0.0).count();
        let total = proven_preds.len();
        let agreement = (buys.max(total - buys) as f64) / total as f64;
        facts.push(Primitives::bind(&atoms.agreement,
            &scalar.encode(agreement, ScalarMode::Linear { scale: 1.0 })));

        let mean_conv = proven_preds.iter().map(|p| p.conviction).sum::<f64>() / total as f64;
        facts.push(Primitives::bind(&atoms.energy,
            &scalar.encode(mean_conv, ScalarMode::Linear { scale: 1.0 })));

        let variance = proven_preds.iter()
            .map(|p| (p.conviction - mean_conv).powi(2))
            .sum::<f64>() / total as f64;
        facts.push(Primitives::bind(&atoms.divergence,
            &scalar.encode(variance.sqrt(), ScalarMode::Linear { scale: 1.0 })));

        // Coherence: pairwise cosine between proven expert thought vectors
        let proven_vecs: Vec<&Vector> = ctx.observer_vecs.iter().enumerate()
            .filter(|(ei, _)| ctx.observer_curve_valid[*ei])
            .map(|(_, v)| v)
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
    }

    // Context
    facts.push(Primitives::bind(&atoms.volatility,
        &scalar.encode_log(ctx.candle_atr.max(1e-10))));
    facts.push(Primitives::bind(&atoms.disc_strength,
        &scalar.encode_log(ctx.disc_strength.max(1e-10))));
    facts.push(Primitives::bind(&atoms.hour,
        &scalar.encode(ctx.candle_hour, ScalarMode::Circular { period: 24.0 })));
    facts.push(Primitives::bind(&atoms.day,
        &scalar.encode(ctx.candle_day, ScalarMode::Circular { period: 7.0 })));

    facts
}
