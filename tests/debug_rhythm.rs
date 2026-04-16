/// debug_rhythm.rs — introspect the indicator rhythm encoding with thermometer.

use holon::kernel::primitives::Primitives;
use holon::kernel::scalar::{ScalarEncoder, ScalarMode};
use holon::kernel::similarity::Similarity;
use holon::kernel::vector::Vector;
use holon::kernel::vector_manager::VectorManager;

const DIMS: usize = 10_000;

fn encode_fact(
    vm: &VectorManager,
    scalar: &ScalarEncoder,
    name: &str,
    value: f64,
    prev: Option<f64>,
) -> Vector {
    let atom = vm.get_vector(name);
    let value_vec = scalar.encode(value, ScalarMode::Thermometer { min: 0.0, max: 1.0 });
    let fact = Primitives::bind(&atom, &value_vec);

    match prev {
        None => fact,
        Some(prev_val) => {
            let delta_atom = vm.get_vector(&format!("{}-delta", name));
            let delta_vec = scalar.encode(
                value - prev_val,
                ScalarMode::Thermometer { min: -0.2, max: 0.2 },
            );
            let delta_fact = Primitives::bind(&delta_atom, &delta_vec);
            let refs = vec![&fact, &delta_fact];
            Primitives::bundle(&refs)
        }
    }
}

#[test]
fn introspect_all_layers() {
    let vm = VectorManager::new(DIMS);
    let scalar = ScalarEncoder::new(DIMS);

    let rising = vec![0.30, 0.35, 0.42, 0.50, 0.58, 0.65, 0.72];
    let falling = vec![0.72, 0.65, 0.58, 0.50, 0.42, 0.35, 0.30];

    // Layer 0: raw scalar vectors
    println!("\n=== RAW SCALARS (thermometer) ===");
    for &(a, b) in &[(0.30, 0.72), (0.42, 0.58), (0.50, 0.50), (0.35, 0.65)] {
        let va = scalar.encode(a, ScalarMode::Thermometer { min: 0.0, max: 1.0 });
        let vb = scalar.encode(b, ScalarMode::Thermometer { min: 0.0, max: 1.0 });
        println!("  {:.2} vs {:.2} → cosine={:.4}", a, b, Similarity::cosine(&va, &vb));
    }

    println!("\n=== RAW DELTAS (thermometer) ===");
    for &(a, b) in &[(0.05, -0.05), (0.07, -0.07), (0.10, -0.10), (0.05, 0.07)] {
        let va = scalar.encode(a, ScalarMode::Thermometer { min: -0.2, max: 0.2 });
        let vb = scalar.encode(b, ScalarMode::Thermometer { min: -0.2, max: 0.2 });
        println!("  {:+.2} vs {:+.2} → cosine={:.4}", a, b, Similarity::cosine(&va, &vb));
    }

    // Layer 1: facts (value + delta bound to atoms)
    println!("\n=== FACTS ===");
    let r_facts: Vec<Vector> = rising.iter().enumerate()
        .map(|(i, &v)| encode_fact(&vm, &scalar, "rsi", v, if i > 0 { Some(rising[i-1]) } else { None }))
        .collect();
    let f_facts: Vec<Vector> = falling.iter().enumerate()
        .map(|(i, &v)| encode_fact(&vm, &scalar, "rsi", v, if i > 0 { Some(falling[i-1]) } else { None }))
        .collect();

    for i in 0..rising.len() {
        let cos = Similarity::cosine(&r_facts[i], &f_facts[i]);
        println!("  fact[{}]: rising={:.2}(d={:+.2}) falling={:.2}(d={:+.2}) cosine={:.4}",
            i, rising[i],
            if i > 0 { rising[i] - rising[i-1] } else { 0.0 },
            falling[i],
            if i > 0 { falling[i] - falling[i-1] } else { 0.0 },
            cos);
    }

    // Layer 2: trigrams
    println!("\n=== TRIGRAMS (rising vs falling) ===");
    let r_trigrams: Vec<Vector> = r_facts.windows(3).map(|w| {
        let ab = Primitives::bind(&w[0], &Primitives::permute(&w[1], 1));
        Primitives::bind(&ab, &Primitives::permute(&w[2], 2))
    }).collect();
    let f_trigrams: Vec<Vector> = f_facts.windows(3).map(|w| {
        let ab = Primitives::bind(&w[0], &Primitives::permute(&w[1], 1));
        Primitives::bind(&ab, &Primitives::permute(&w[2], 2))
    }).collect();

    for i in 0..r_trigrams.len() {
        println!("  trigram[{}]: rising vs falling cosine={:.4}", i, Similarity::cosine(&r_trigrams[i], &f_trigrams[i]));
    }

    println!("\n=== TRIGRAM SELF-SIMILARITY (within rising) ===");
    for i in 0..r_trigrams.len() {
        for j in (i+1)..r_trigrams.len() {
            println!("  rising tri[{}] vs tri[{}]: cosine={:.4}", i, j, Similarity::cosine(&r_trigrams[i], &r_trigrams[j]));
        }
    }

    // Layer 3: pairs
    println!("\n=== PAIRS (rising vs falling) ===");
    let r_pairs: Vec<Vector> = r_trigrams.windows(2)
        .map(|w| Primitives::bind(&w[0], &w[1])).collect();
    let f_pairs: Vec<Vector> = f_trigrams.windows(2)
        .map(|w| Primitives::bind(&w[0], &w[1])).collect();

    for i in 0..r_pairs.len() {
        println!("  pair[{}]: rising vs falling cosine={:.4}", i, Similarity::cosine(&r_pairs[i], &f_pairs[i]));
    }

    println!("\n=== PAIR SELF-SIMILARITY (within rising) ===");
    for i in 0..r_pairs.len() {
        for j in (i+1)..r_pairs.len() {
            println!("  rising pair[{}] vs pair[{}]: cosine={:.4}", i, j, Similarity::cosine(&r_pairs[i], &r_pairs[j]));
        }
    }

    // Layer 4: rhythm
    println!("\n=== RHYTHM ===");
    let r_refs: Vec<&Vector> = r_pairs.iter().collect();
    let f_refs: Vec<&Vector> = f_pairs.iter().collect();
    let r_rhythm = Primitives::bundle(&r_refs);
    let f_rhythm = Primitives::bundle(&f_refs);
    println!("  rising vs falling rhythm cosine={:.4}", Similarity::cosine(&r_rhythm, &f_rhythm));

    // What if we DON'T overlap — non-overlapping trigrams?
    println!("\n=== NON-OVERLAPPING TRIGRAMS ===");
    // rising has 7 facts. Take [0,1,2] and [3,4,5] (skip fact 6)
    let r_tri_a = {
        let ab = Primitives::bind(&r_facts[0], &Primitives::permute(&r_facts[1], 1));
        Primitives::bind(&ab, &Primitives::permute(&r_facts[2], 2))
    };
    let r_tri_b = {
        let ab = Primitives::bind(&r_facts[3], &Primitives::permute(&r_facts[4], 1));
        Primitives::bind(&ab, &Primitives::permute(&r_facts[5], 2))
    };
    let f_tri_a = {
        let ab = Primitives::bind(&f_facts[0], &Primitives::permute(&f_facts[1], 1));
        Primitives::bind(&ab, &Primitives::permute(&f_facts[2], 2))
    };
    let f_tri_b = {
        let ab = Primitives::bind(&f_facts[3], &Primitives::permute(&f_facts[4], 1));
        Primitives::bind(&ab, &Primitives::permute(&f_facts[5], 2))
    };
    println!("  non-overlap rising tri_a vs tri_b: cosine={:.4}", Similarity::cosine(&r_tri_a, &r_tri_b));
    println!("  non-overlap rising tri_a vs falling tri_a: cosine={:.4}", Similarity::cosine(&r_tri_a, &f_tri_a));
    let r_pair_no = Primitives::bind(&r_tri_a, &r_tri_b);
    let f_pair_no = Primitives::bind(&f_tri_a, &f_tri_b);
    println!("  non-overlap rising pair vs falling pair: cosine={:.4}", Similarity::cosine(&r_pair_no, &f_pair_no));
}
