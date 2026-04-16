/// debug_thermometer.rs — test thermometer encoding for continuous scalars.
///
/// Thermometer: value v on [min, max] sets the first v_frac * D dimensions
/// to +1 and the rest to -1. Two nearby values share most dimensions.
/// The cosine IS the overlap fraction. Linear gradient. No rotation.
/// No thresholding problem.

use holon::kernel::similarity::Similarity;
use holon::kernel::vector::Vector;

const DIMS: usize = 10_000;

/// Encode a scalar as a thermometer vector.
/// value in [min, max] → first frac*D dims = +1, rest = -1.
fn thermometer(value: f64, min: f64, max: f64, dims: usize) -> Vector {
    let frac = ((value - min) / (max - min)).clamp(0.0, 1.0);
    let threshold = (frac * dims as f64) as usize;
    let data: Vec<i8> = (0..dims)
        .map(|i| if i < threshold { 1 } else { -1 })
        .collect();
    Vector::from_data(data)
}

/// Encode a signed scalar as a thermometer vector.
/// Centered: 0.0 maps to the midpoint. Positive fills right. Negative fills left.
fn signed_thermometer(value: f64, range: f64, dims: usize) -> Vector {
    thermometer(value, -range, range, dims)
}

#[test]
fn gradient_test() {
    println!("\n=== Thermometer gradient [0.0, 1.0] ===");
    let base = thermometer(0.5, 0.0, 1.0, DIMS);
    for &v in &[0.50, 0.51, 0.52, 0.55, 0.60, 0.70, 0.80, 0.90, 1.00, 0.40, 0.30, 0.10, 0.00] {
        let other = thermometer(v, 0.0, 1.0, DIMS);
        println!("  0.50 vs {:.2} → cosine={:.4}", v, Similarity::cosine(&base, &other));
    }
}

#[test]
fn signed_gradient_test() {
    println!("\n=== Signed thermometer: deltas in [-0.1, +0.1] ===");
    let zero = signed_thermometer(0.0, 0.1, DIMS);
    for &v in &[0.0, 0.01, 0.03, 0.05, 0.07, 0.10, -0.01, -0.03, -0.05, -0.07, -0.10] {
        let other = signed_thermometer(v, 0.1, DIMS);
        println!("  0.00 vs {:+.2} → cosine={:.4}", v, Similarity::cosine(&zero, &other));
    }

    println!("\n=== Positive vs negative deltas ===");
    for &v in &[0.01, 0.03, 0.05, 0.07, 0.10] {
        let pos = signed_thermometer(v, 0.1, DIMS);
        let neg = signed_thermometer(-v, 0.1, DIMS);
        println!("  +{:.2} vs -{:.2} → cosine={:.4}", v, v, Similarity::cosine(&pos, &neg));
    }

    println!("\n=== Nearby deltas ===");
    for &(a, b) in &[(0.05, 0.06), (0.05, 0.07), (0.05, 0.08), (-0.03, -0.04), (-0.03, -0.07)] {
        let va = signed_thermometer(a, 0.1, DIMS);
        let vb = signed_thermometer(b, 0.1, DIMS);
        println!("  {:+.2} vs {:+.2} → cosine={:.4}", a, b, Similarity::cosine(&va, &vb));
    }
}

#[test]
fn bindable_test() {
    use holon::kernel::primitives::Primitives;
    use holon::kernel::vector_manager::VectorManager;

    let vm = VectorManager::new(DIMS);

    println!("\n=== Thermometer bound to atom ===");
    let rsi_atom = vm.get_vector("rsi");

    // Bind thermometer-encoded values to the atom
    let rsi_050 = Primitives::bind(&rsi_atom, &thermometer(0.50, 0.0, 1.0, DIMS));
    let rsi_052 = Primitives::bind(&rsi_atom, &thermometer(0.52, 0.0, 1.0, DIMS));
    let rsi_070 = Primitives::bind(&rsi_atom, &thermometer(0.70, 0.0, 1.0, DIMS));

    println!("  rsi@0.50 vs rsi@0.52 → cosine={:.4}", Similarity::cosine(&rsi_050, &rsi_052));
    println!("  rsi@0.50 vs rsi@0.70 → cosine={:.4}", Similarity::cosine(&rsi_050, &rsi_070));
    println!("  rsi@0.52 vs rsi@0.70 → cosine={:.4}", Similarity::cosine(&rsi_052, &rsi_070));

    // Different atom, same value — should be orthogonal
    let macd_atom = vm.get_vector("macd");
    let macd_050 = Primitives::bind(&macd_atom, &thermometer(0.50, 0.0, 1.0, DIMS));
    println!("  rsi@0.50 vs macd@0.50 → cosine={:.4}", Similarity::cosine(&rsi_050, &macd_050));

    // Signed deltas bound to atom
    println!("\n=== Signed delta bound to atom ===");
    let delta_atom = vm.get_vector("rsi-delta");
    let d_pos = Primitives::bind(&delta_atom, &signed_thermometer(0.05, 0.1, DIMS));
    let d_neg = Primitives::bind(&delta_atom, &signed_thermometer(-0.05, 0.1, DIMS));
    let d_zero = Primitives::bind(&delta_atom, &signed_thermometer(0.0, 0.1, DIMS));
    println!("  delta@+0.05 vs delta@-0.05 → cosine={:.4}", Similarity::cosine(&d_pos, &d_neg));
    println!("  delta@+0.05 vs delta@0.00  → cosine={:.4}", Similarity::cosine(&d_pos, &d_zero));
    println!("  delta@-0.05 vs delta@0.00  → cosine={:.4}", Similarity::cosine(&d_neg, &d_zero));
}
