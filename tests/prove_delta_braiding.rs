/// prove_delta_braiding.rs — does separating sequential and structural
/// deltas improve subspace separation?
///
/// Braided: both delta types in one phase record bundle.
/// Separated: sequential deltas on the phase record, structural
/// momentum as its own indicator-rhythm stream.
///
/// Train subspace on uptrend phase rhythms. Test against downtrend.
/// Compare separation ratio: which approach lets the subspace
/// distinguish regimes better?

use holon::kernel::primitives::Primitives;
use holon::kernel::scalar::{ScalarEncoder, ScalarMode};
use holon::kernel::similarity::Similarity;
use holon::kernel::vector::Vector;
use holon::kernel::vector_manager::VectorManager;
use holon::memory::OnlineSubspace;

const DIMS: usize = 10_000;

fn therm(scalar: &ScalarEncoder, value: f64, min: f64, max: f64) -> Vector {
    scalar.encode(value, ScalarMode::Thermometer { min, max })
}

fn to_f64(v: &Vector) -> Vec<f64> {
    v.data().iter().map(|&x| x as f64).collect()
}

/// A simplified phase record for testing.
struct PhaseRecord {
    label: &'static str,    // "valley", "transition-up", "peak", "transition-down"
    duration: f64,
    move_pct: f64,
    volume: f64,
}

/// Generate a sequence of phases for an uptrend.
/// Rising valleys, strong rallies, shallow pullbacks.
fn uptrend_phases(seed: u64, count: usize) -> Vec<PhaseRecord> {
    let mut rng = seed;
    let mut phases = Vec::new();
    let mut valley_level: f64 = 0.0;
    let labels = ["valley", "transition-up", "peak", "transition-down"];

    for i in 0..count {
        rng = rng.wrapping_mul(6364136223846793005).wrapping_add(1);
        let noise = ((rng >> 33) as f64 / u32::MAX as f64) * 0.01 - 0.005;

        let label = labels[i % 4];
        let (duration, move_pct, volume) = match label {
            "valley" => {
                valley_level += 0.005 + noise; // rising valleys
                (15.0 + noise * 200.0, -0.002 + noise, 0.8)
            }
            "transition-up" => (12.0 + noise * 100.0, 0.04 + noise, 1.5),
            "peak" => (10.0 + noise * 100.0, 0.001, 1.1),
            "transition-down" => (8.0 + noise * 100.0, -0.015 + noise, 0.7),
            _ => unreachable!(),
        };
        phases.push(PhaseRecord { label, duration, move_pct, volume });
    }
    phases
}

/// Generate phases for a downtrend.
/// Falling peaks, weak rallies, strong selloffs.
fn downtrend_phases(seed: u64, count: usize) -> Vec<PhaseRecord> {
    let mut rng = seed;
    let mut phases = Vec::new();
    let mut peak_level: f64 = 0.0;
    let labels = ["peak", "transition-down", "valley", "transition-up"];

    for i in 0..count {
        rng = rng.wrapping_mul(6364136223846793005).wrapping_add(1);
        let noise = ((rng >> 33) as f64 / u32::MAX as f64) * 0.01 - 0.005;

        let label = labels[i % 4];
        let (duration, move_pct, volume) = match label {
            "peak" => {
                peak_level -= 0.005 + noise.abs(); // falling peaks
                (10.0 + noise * 100.0, 0.001, 0.9)
            }
            "transition-down" => (14.0 + noise * 100.0, -0.04 + noise, 1.6),
            "valley" => (12.0 + noise * 100.0, -0.002 + noise, 1.0),
            "transition-up" => (8.0 + noise * 100.0, 0.015 + noise, 0.6),
            _ => unreachable!(),
        };
        phases.push(PhaseRecord { label, duration, move_pct, volume });
    }
    phases
}

/// BRAIDED: encode a phase record with both sequential and structural deltas
/// in one bundle.
fn encode_braided(
    vm: &VectorManager,
    scalar: &ScalarEncoder,
    phase: &PhaseRecord,
    prev: Option<&PhaseRecord>,
    prev_same: Option<&PhaseRecord>,
) -> Vector {
    let mut parts: Vec<Vector> = vec![
        vm.get_vector(phase.label),
        Primitives::bind(&vm.get_vector("rec-duration"), &therm(scalar, phase.duration, 0.0, 50.0)),
        Primitives::bind(&vm.get_vector("rec-move"), &therm(scalar, phase.move_pct, -0.1, 0.1)),
        Primitives::bind(&vm.get_vector("rec-volume"), &therm(scalar, phase.volume, 0.0, 3.0)),
    ];

    if let Some(p) = prev {
        parts.push(Primitives::bind(
            &vm.get_vector("prior-move-delta"),
            &therm(scalar, phase.move_pct - p.move_pct, -0.1, 0.1),
        ));
        parts.push(Primitives::bind(
            &vm.get_vector("prior-duration-delta"),
            &therm(scalar, phase.duration - p.duration, -30.0, 30.0),
        ));
    }

    if let Some(s) = prev_same {
        parts.push(Primitives::bind(
            &vm.get_vector("same-move-delta"),
            &therm(scalar, phase.move_pct - s.move_pct, -0.1, 0.1),
        ));
        parts.push(Primitives::bind(
            &vm.get_vector("same-duration-delta"),
            &therm(scalar, phase.duration - s.duration, -30.0, 30.0),
        ));
    }

    let refs: Vec<&Vector> = parts.iter().collect();
    Primitives::bundle(&refs)
}

/// SEPARATED: encode a phase record with sequential deltas only.
/// Structural momentum is a separate stream.
fn encode_separated(
    vm: &VectorManager,
    scalar: &ScalarEncoder,
    phase: &PhaseRecord,
    prev: Option<&PhaseRecord>,
) -> Vector {
    let mut parts: Vec<Vector> = vec![
        vm.get_vector(phase.label),
        Primitives::bind(&vm.get_vector("rec-duration"), &therm(scalar, phase.duration, 0.0, 50.0)),
        Primitives::bind(&vm.get_vector("rec-move"), &therm(scalar, phase.move_pct, -0.1, 0.1)),
        Primitives::bind(&vm.get_vector("rec-volume"), &therm(scalar, phase.volume, 0.0, 3.0)),
    ];

    if let Some(p) = prev {
        parts.push(Primitives::bind(
            &vm.get_vector("prior-move-delta"),
            &therm(scalar, phase.move_pct - p.move_pct, -0.1, 0.1),
        ));
        parts.push(Primitives::bind(
            &vm.get_vector("prior-duration-delta"),
            &therm(scalar, phase.duration - p.duration, -30.0, 30.0),
        ));
    }

    let refs: Vec<&Vector> = parts.iter().collect();
    Primitives::bundle(&refs)
}

/// Build a phase rhythm from encoded phase records (trigrams → pairs → bundle).
fn phase_rhythm(encoded: &[Vector], dims: usize) -> Vector {
    let trigrams: Vec<Vector> = encoded.windows(3).map(|w| {
        let ab = Primitives::bind(&w[0], &Primitives::permute(&w[1], 1));
        Primitives::bind(&ab, &Primitives::permute(&w[2], 2))
    }).collect();

    let pairs: Vec<Vector> = trigrams.windows(2)
        .map(|w| Primitives::bind(&w[0], &w[1])).collect();

    if pairs.is_empty() {
        return Vector::zeros(dims);
    }
    let budget = (dims as f64).sqrt() as usize;
    let start = if pairs.len() > budget { pairs.len() - budget } else { 0 };
    let trimmed: Vec<&Vector> = pairs[start..].iter().collect();
    Primitives::bundle(&trimmed)
}

/// Build a structural momentum rhythm for one phase type.
/// Extracts the move_pct of each occurrence of `target_label` and
/// builds an indicator-rhythm from it.
fn structural_rhythm(
    vm: &VectorManager,
    scalar: &ScalarEncoder,
    phases: &[PhaseRecord],
    target_label: &str,
    atom_name: &str,
    dims: usize,
) -> Vector {
    let values: Vec<f64> = phases.iter()
        .filter(|p| p.label == target_label)
        .map(|p| p.move_pct)
        .collect();

    if values.len() < 3 {
        return Vector::zeros(dims);
    }

    let facts: Vec<Vector> = values.iter().enumerate().map(|(i, &val)| {
        let v = therm(scalar, val, -0.1, 0.1);
        if i == 0 {
            v
        } else {
            let delta = therm(scalar, val - values[i - 1], -0.05, 0.05);
            let delta_bound = Primitives::bind(&vm.get_vector("delta"), &delta);
            let refs = vec![&v, &delta_bound];
            Primitives::bundle(&refs)
        }
    }).collect();

    let trigrams: Vec<Vector> = facts.windows(3).map(|w| {
        let ab = Primitives::bind(&w[0], &Primitives::permute(&w[1], 1));
        Primitives::bind(&ab, &Primitives::permute(&w[2], 2))
    }).collect();

    let pairs: Vec<Vector> = trigrams.windows(2)
        .map(|w| Primitives::bind(&w[0], &w[1])).collect();

    if pairs.is_empty() {
        return Vector::zeros(dims);
    }
    let refs: Vec<&Vector> = pairs.iter().collect();
    let raw = Primitives::bundle(&refs);
    Primitives::bind(&vm.get_vector(atom_name), &raw)
}

#[test]
fn braided_vs_separated() {
    let vm = VectorManager::new(DIMS);
    let scalar = ScalarEncoder::new(DIMS);
    let phase_count = 40; // 10 full cycles

    // ═══ BRAIDED approach ═══════════════════════════════════════════
    let mut braided_subspace = OnlineSubspace::new(DIMS, 32);

    println!("\n=== Training BRAIDED on 100 uptrend phase sequences ===");
    for seed in 0..100u64 {
        let phases = uptrend_phases(seed * 7, phase_count);
        let mut last_by_type: std::collections::HashMap<&str, usize> = std::collections::HashMap::new();

        let encoded: Vec<Vector> = phases.iter().enumerate().map(|(i, phase)| {
            let prev = if i > 0 { Some(&phases[i - 1]) } else { None };
            let prev_same = last_by_type.get(phase.label).map(|&idx| &phases[idx]);
            let v = encode_braided(&vm, &scalar, phase, prev, prev_same);
            last_by_type.insert(phase.label, i);
            v
        }).collect();

        let rhythm = phase_rhythm(&encoded, DIMS);
        braided_subspace.update(&to_f64(&rhythm));
    }

    let mut braided_up_residuals = Vec::new();
    let mut braided_dn_residuals = Vec::new();

    for seed in 500..550u64 {
        let phases = uptrend_phases(seed * 7, phase_count);
        let mut last_by_type: std::collections::HashMap<&str, usize> = std::collections::HashMap::new();
        let encoded: Vec<Vector> = phases.iter().enumerate().map(|(i, phase)| {
            let prev = if i > 0 { Some(&phases[i - 1]) } else { None };
            let prev_same = last_by_type.get(phase.label).map(|&idx| &phases[idx]);
            let v = encode_braided(&vm, &scalar, phase, prev, prev_same);
            last_by_type.insert(phase.label, i);
            v
        }).collect();
        braided_up_residuals.push(braided_subspace.residual(&to_f64(&phase_rhythm(&encoded, DIMS))));
    }

    for seed in 500..550u64 {
        let phases = downtrend_phases(seed * 7, phase_count);
        let mut last_by_type: std::collections::HashMap<&str, usize> = std::collections::HashMap::new();
        let encoded: Vec<Vector> = phases.iter().enumerate().map(|(i, phase)| {
            let prev = if i > 0 { Some(&phases[i - 1]) } else { None };
            let prev_same = last_by_type.get(phase.label).map(|&idx| &phases[idx]);
            let v = encode_braided(&vm, &scalar, phase, prev, prev_same);
            last_by_type.insert(phase.label, i);
            v
        }).collect();
        braided_dn_residuals.push(braided_subspace.residual(&to_f64(&phase_rhythm(&encoded, DIMS))));
    }

    let braided_up = braided_up_residuals.iter().sum::<f64>() / braided_up_residuals.len() as f64;
    let braided_dn = braided_dn_residuals.iter().sum::<f64>() / braided_dn_residuals.len() as f64;
    let braided_ratio = braided_dn / braided_up;

    // ═══ SEPARATED approach ═════════════════════════════════════════
    let mut separated_subspace = OnlineSubspace::new(DIMS, 32);

    println!("\n=== Training SEPARATED on 100 uptrend phase sequences ===");
    for seed in 0..100u64 {
        let phases = uptrend_phases(seed * 7, phase_count);

        let encoded: Vec<Vector> = phases.iter().enumerate().map(|(i, phase)| {
            let prev = if i > 0 { Some(&phases[i - 1]) } else { None };
            encode_separated(&vm, &scalar, phase, prev)
        }).collect();

        let seq_rhythm = phase_rhythm(&encoded, DIMS);
        let valley_rhythm = structural_rhythm(&vm, &scalar, &phases, "valley", "valley-momentum", DIMS);
        let peak_rhythm = structural_rhythm(&vm, &scalar, &phases, "peak", "peak-momentum", DIMS);

        let parts = vec![&seq_rhythm, &valley_rhythm, &peak_rhythm];
        let thought = Primitives::bundle(&parts);
        separated_subspace.update(&to_f64(&thought));
    }

    let mut separated_up_residuals = Vec::new();
    let mut separated_dn_residuals = Vec::new();

    for seed in 500..550u64 {
        let phases = uptrend_phases(seed * 7, phase_count);
        let encoded: Vec<Vector> = phases.iter().enumerate().map(|(i, phase)| {
            let prev = if i > 0 { Some(&phases[i - 1]) } else { None };
            encode_separated(&vm, &scalar, phase, prev)
        }).collect();
        let seq_rhythm = phase_rhythm(&encoded, DIMS);
        let valley_rhythm = structural_rhythm(&vm, &scalar, &phases, "valley", "valley-momentum", DIMS);
        let peak_rhythm = structural_rhythm(&vm, &scalar, &phases, "peak", "peak-momentum", DIMS);
        let parts = vec![&seq_rhythm, &valley_rhythm, &peak_rhythm];
        let thought = Primitives::bundle(&parts);
        separated_up_residuals.push(separated_subspace.residual(&to_f64(&thought)));
    }

    for seed in 500..550u64 {
        let phases = downtrend_phases(seed * 7, phase_count);
        let encoded: Vec<Vector> = phases.iter().enumerate().map(|(i, phase)| {
            let prev = if i > 0 { Some(&phases[i - 1]) } else { None };
            encode_separated(&vm, &scalar, phase, prev)
        }).collect();
        let seq_rhythm = phase_rhythm(&encoded, DIMS);
        let valley_rhythm = structural_rhythm(&vm, &scalar, &phases, "valley", "valley-momentum", DIMS);
        let peak_rhythm = structural_rhythm(&vm, &scalar, &phases, "peak", "peak-momentum", DIMS);
        let parts = vec![&seq_rhythm, &valley_rhythm, &peak_rhythm];
        let thought = Primitives::bundle(&parts);
        separated_dn_residuals.push(separated_subspace.residual(&to_f64(&thought)));
    }

    let separated_up = separated_up_residuals.iter().sum::<f64>() / separated_up_residuals.len() as f64;
    let separated_dn = separated_dn_residuals.iter().sum::<f64>() / separated_dn_residuals.len() as f64;
    let separated_ratio = separated_dn / separated_up;

    // ═══ RESULTS ════════════════════════════════════════════════════
    println!("\n=== RESULTS ===");
    println!("  BRAIDED:   up={:.4} down={:.4} ratio={:.2}x", braided_up, braided_dn, braided_ratio);
    println!("  SEPARATED: up={:.4} down={:.4} ratio={:.2}x", separated_up, separated_dn, separated_ratio);
    println!("  Winner: {}", if separated_ratio > braided_ratio { "SEPARATED" } else { "BRAIDED" });
    println!("  Margin: {:.2}x vs {:.2}x", separated_ratio, braided_ratio);
}
