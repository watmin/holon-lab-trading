/// debug_scalar.rs — understand how ScalarMode::Linear behaves
/// at different scales and with signed values.

use holon::kernel::scalar::{ScalarEncoder, ScalarMode};
use holon::kernel::similarity::Similarity;

const DIMS: usize = 10_000;

#[test]
fn explore_linear_encoding() {
    let scalar = ScalarEncoder::new(DIMS);

    println!("\n=== Scale 1.0 (current) ===");
    println!("Maps [0, 1.0] to one full rotation (2π)");
    for &(a, b) in &[
        (0.0, 0.1), (0.0, 0.5), (0.0, 1.0),
        (0.3, 0.7), (0.42, 0.58),
        (0.07, -0.07), (0.1, -0.1), (0.5, -0.5),
    ] {
        let va = scalar.encode(a, ScalarMode::Linear { scale: 1.0 });
        let vb = scalar.encode(b, ScalarMode::Linear { scale: 1.0 });
        println!("  {:.2} vs {:.2} → cosine={:.4}", a, b, Similarity::cosine(&va, &vb));
    }

    println!("\n=== Scale 0.2 (delta-sized) ===");
    println!("Maps [0, 0.2] to one full rotation");
    for &(a, b) in &[
        (0.0, 0.05), (0.0, 0.1), (0.0, 0.2),
        (0.07, -0.07), (0.1, -0.1), (0.05, -0.05),
    ] {
        let va = scalar.encode(a, ScalarMode::Linear { scale: 0.2 });
        let vb = scalar.encode(b, ScalarMode::Linear { scale: 0.2 });
        println!("  {:.2} vs {:.2} → cosine={:.4}", a, b, Similarity::cosine(&va, &vb));
    }

    println!("\n=== Scale 0.1 ===");
    println!("Maps [0, 0.1] to one full rotation");
    for &(a, b) in &[
        (0.07, -0.07), (0.05, -0.05), (0.03, -0.03),
        (0.0, 0.05), (0.0, 0.1),
    ] {
        let va = scalar.encode(a, ScalarMode::Linear { scale: 0.1 });
        let vb = scalar.encode(b, ScalarMode::Linear { scale: 0.1 });
        println!("  {:.2} vs {:.2} → cosine={:.4}", a, b, Similarity::cosine(&va, &vb));
    }

    // The circular wrapping problem: does -x wrap to the same as +x?
    println!("\n=== Wrapping test ===");
    for &scale in &[0.1, 0.2, 0.5, 1.0] {
        let pos = scalar.encode(0.07, ScalarMode::Linear { scale });
        let neg = scalar.encode(-0.07, ScalarMode::Linear { scale });
        let zero = scalar.encode(0.0, ScalarMode::Linear { scale });
        println!(
            "  scale={:.1}: +0.07 vs -0.07 cos={:.4}, +0.07 vs 0.0 cos={:.4}, -0.07 vs 0.0 cos={:.4}",
            scale,
            Similarity::cosine(&pos, &neg),
            Similarity::cosine(&pos, &zero),
            Similarity::cosine(&neg, &zero),
        );
    }

    // What if we offset to make deltas always positive?
    // delta in [-0.1, +0.1] → shifted to [0.0, 0.2]
    println!("\n=== Offset approach: delta + 0.1 with scale=0.2 ===");
    for &(a, b) in &[
        (0.07, -0.07), (0.05, -0.05), (0.1, -0.1), (0.0, 0.0),
    ] {
        let va = scalar.encode(a + 0.1, ScalarMode::Linear { scale: 0.2 });
        let vb = scalar.encode(b + 0.1, ScalarMode::Linear { scale: 0.2 });
        let v_zero = scalar.encode(0.0 + 0.1, ScalarMode::Linear { scale: 0.2 });
        println!(
            "  delta {:.2} vs {:.2} → cosine={:.4}, {:.2} vs 0.0 → cos={:.4}",
            a, b, Similarity::cosine(&va, &vb),
            a, Similarity::cosine(&va, &v_zero),
        );
    }

    // What about Circular mode — does it handle sign?
    println!("\n=== Circular mode (period=0.2, offset by 0.1) ===");
    for &(a, b) in &[
        (0.07, -0.07), (0.05, -0.05), (0.1, -0.1),
    ] {
        let va = scalar.encode(a + 0.1, ScalarMode::Circular { period: 0.2 });
        let vb = scalar.encode(b + 0.1, ScalarMode::Circular { period: 0.2 });
        println!("  {:.2} vs {:.2} → cosine={:.4}", a, b, Similarity::cosine(&va, &vb));
    }
}
