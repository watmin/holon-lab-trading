/// Proof: incremental bundling produces identical results to full bundling.
///
/// The claim: given sums = Σ facts[i] (element-wise i32),
///   threshold(sums) == bundle(facts)
///
/// And: if fact[k] changes from old to new,
///   sums_new = sums - old + new
///   threshold(sums_new) == bundle(facts_with_replacement)
///
/// This holds because:
///   1. Integer addition is commutative: a + b == b + a
///   2. Integer addition is associative: (a + b) + c == a + (b + c)
///   3. Subtraction is addition of negation: a - b == a + (-b)
///   4. threshold is applied identically in both paths — same sums, same output.
///
/// The equality is EXACT, not approximate. No floating point. No epsilon.
/// The sums are i32. The threshold is sign(). Bit-identical results.

use holon::kernel::primitives::Primitives;
use holon::kernel::vector::Vector;
use holon::kernel::vector_manager::VectorManager;

const DIMS: usize = 4096;

fn make_vm() -> VectorManager {
    VectorManager::with_seed(DIMS, 42)
}

fn random_vectors(vm: &VectorManager, count: usize) -> Vec<Vector> {
    (0..count)
        .map(|i| vm.get_vector(&format!("fact_{}", i)))
        .collect()
}

fn compute_sums(vectors: &[&Vector], dims: usize) -> Vec<i32> {
    let mut sums = vec![0i32; dims];
    for v in vectors {
        for (s, &val) in sums.iter_mut().zip(v.data()) {
            *s += val as i32;
        }
    }
    sums
}

fn threshold(sums: &[i32], dims: usize) -> Vector {
    let mut out = Vector::zeros(dims);
    for (o, &s) in out.data_mut().iter_mut().zip(sums.iter()) {
        *o = if s > 0 { 1 } else if s < 0 { -1 } else { 0 };
    }
    out
}

/// Proof 1: sums-then-threshold == bundle (same operation, different bookkeeping)
#[test]
fn sums_then_threshold_equals_bundle() {
    let vm = make_vm();
    let facts = random_vectors(&vm, 20);
    let refs: Vec<&Vector> = facts.iter().collect();

    let bundled = Primitives::bundle(&refs);

    let sums = compute_sums(&refs, DIMS);
    let from_sums = threshold(&sums, DIMS);

    assert_eq!(bundled.data(), from_sums.data(), "sums-then-threshold must equal bundle");
}

/// Proof 2: incremental update (subtract old, add new) equals full recompute
#[test]
fn incremental_update_equals_full_recompute() {
    let vm = make_vm();
    let mut facts = random_vectors(&vm, 20);
    let refs: Vec<&Vector> = facts.iter().collect();

    // Initial sums
    let mut sums = compute_sums(&refs, DIMS);

    // Replace fact[5] with a new vector
    let old = facts[5].clone();
    let new_vec = vm.get_vector("replacement_fact");

    // Incremental: subtract old, add new
    for (s, &val) in sums.iter_mut().zip(old.data()) {
        *s -= val as i32;
    }
    for (s, &val) in sums.iter_mut().zip(new_vec.data()) {
        *s += val as i32;
    }
    let incremental = threshold(&sums, DIMS);

    // Full recompute with the replacement
    facts[5] = new_vec;
    let refs2: Vec<&Vector> = facts.iter().collect();
    let recomputed = Primitives::bundle(&refs2);

    assert_eq!(
        incremental.data(),
        recomputed.data(),
        "incremental update must equal full recompute"
    );
}

/// Proof 3: multiple replacements in sequence — each step exact
#[test]
fn sequential_replacements_all_exact() {
    let vm = make_vm();
    let mut facts = random_vectors(&vm, 30);
    let refs: Vec<&Vector> = facts.iter().collect();
    let mut sums = compute_sums(&refs, DIMS);

    // Replace 10 different facts one at a time
    for round in 0..10 {
        let idx = round * 3; // replace facts 0, 3, 6, 9, ...
        let old = facts[idx].clone();
        let new_vec = vm.get_vector(&format!("round_{}_replacement", round));

        // Incremental
        for (s, &val) in sums.iter_mut().zip(old.data()) {
            *s -= val as i32;
        }
        for (s, &val) in sums.iter_mut().zip(new_vec.data()) {
            *s += val as i32;
        }

        facts[idx] = new_vec;

        // Full recompute
        let refs2: Vec<&Vector> = facts.iter().collect();
        let full = Primitives::bundle(&refs2);
        let incr = threshold(&sums, DIMS);

        assert_eq!(
            incr.data(),
            full.data(),
            "round {} incremental must equal full recompute",
            round
        );
    }
}

/// Proof 4: order of operations doesn't matter (commutativity)
/// Apply the same set of replacements in different orders — same final sums
#[test]
fn replacement_order_irrelevant() {
    let vm = make_vm();
    let facts = random_vectors(&vm, 15);
    let refs: Vec<&Vector> = facts.iter().collect();
    let base_sums = compute_sums(&refs, DIMS);

    let replacements: Vec<(usize, Vector)> = vec![
        (2, vm.get_vector("repl_a")),
        (7, vm.get_vector("repl_b")),
        (11, vm.get_vector("repl_c")),
    ];

    // Forward order
    let mut sums_fwd = base_sums.clone();
    let mut facts_fwd = facts.clone();
    for (idx, new_vec) in &replacements {
        let old = &facts_fwd[*idx];
        for (s, &val) in sums_fwd.iter_mut().zip(old.data()) {
            *s -= val as i32;
        }
        for (s, &val) in sums_fwd.iter_mut().zip(new_vec.data()) {
            *s += val as i32;
        }
        facts_fwd[*idx] = new_vec.clone();
    }

    // Reverse order
    let mut sums_rev = base_sums.clone();
    let mut facts_rev = facts.clone();
    for (idx, new_vec) in replacements.iter().rev() {
        let old = &facts_rev[*idx];
        for (s, &val) in sums_rev.iter_mut().zip(old.data()) {
            *s -= val as i32;
        }
        for (s, &val) in sums_rev.iter_mut().zip(new_vec.data()) {
            *s += val as i32;
        }
        facts_rev[*idx] = new_vec.clone();
    }

    assert_eq!(sums_fwd, sums_rev, "order of replacement must not affect sums");
    assert_eq!(
        threshold(&sums_fwd, DIMS).data(),
        threshold(&sums_rev, DIMS).data(),
        "order of replacement must not affect threshold"
    );
}

/// Proof 5: the candle-to-candle scenario
/// Simulate 5 candles where 4 of 20 facts change each candle.
/// Incremental matches full recompute every single candle.
#[test]
fn candle_simulation_incremental_exact() {
    let vm = make_vm();
    let mut facts = random_vectors(&vm, 20);
    let refs: Vec<&Vector> = facts.iter().collect();
    let mut sums = compute_sums(&refs, DIMS);

    for candle in 0..5 {
        // 4 facts change per candle (simulating price-dependent indicators)
        for j in 0..4 {
            let idx = (candle * 4 + j) % 20;
            let old = facts[idx].clone();
            let new_vec = vm.get_vector(&format!("candle_{}_fact_{}", candle, j));

            for (s, &val) in sums.iter_mut().zip(old.data()) {
                *s -= val as i32;
            }
            for (s, &val) in sums.iter_mut().zip(new_vec.data()) {
                *s += val as i32;
            }
            facts[idx] = new_vec;
        }

        let refs2: Vec<&Vector> = facts.iter().collect();
        let full = Primitives::bundle(&refs2);
        let incr = threshold(&sums, DIMS);

        assert_eq!(
            incr.data(),
            full.data(),
            "candle {} incremental must equal full recompute",
            candle
        );
    }
}
