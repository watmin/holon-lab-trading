/// Prove whether bundle(A, B, A) == bundle(A, B) in MAP algebra.
use holon::kernel::vector_manager::VectorManager;
use holon::kernel::primitives::Primitives;

#[test]
fn test_bundle_duplicate_is_not_idempotent() {
    let vm = VectorManager::new(10000);
    let a = vm.get_vector("rsi");
    let b = vm.get_vector("atr");

    let ab = Primitives::bundle(&[&a, &b]);
    let aba = Primitives::bundle(&[&a, &b, &a]);

    let cos = holon::kernel::similarity::Similarity::cosine(&ab, &aba);
    let identical = ab.data() == aba.data();

    let mut diffs = 0;
    let mut zeros_ab = 0;
    let mut zeros_aba = 0;
    for (x, y) in ab.data().iter().zip(aba.data().iter()) {
        if x != y { diffs += 1; }
        if *x == 0 { zeros_ab += 1; }
        if *y == 0 { zeros_aba += 1; }
    }

    eprintln!("bundle(A,B) vs bundle(A,B,A):");
    eprintln!("  cosine: {:.4}", cos);
    eprintln!("  bit-identical: {}", identical);
    eprintln!("  dimensions that differ: {} / 10000", diffs);
    eprintln!("  zeros in bundle(A,B): {}", zeros_ab);
    eprintln!("  zeros in bundle(A,B,A): {}", zeros_aba);

    // The assertion: they are NOT the same
    assert!(!identical, "bundle with duplicate should differ from without");
    assert!(diffs > 0, "some dimensions must differ");
}

#[test]
fn test_bundle_three_unique_vs_four_with_one_dupe() {
    let vm = VectorManager::new(10000);
    let a = vm.get_vector("rsi");
    let b = vm.get_vector("atr");
    let c = vm.get_vector("hurst");

    let abc = Primitives::bundle(&[&a, &b, &c]);
    let abca = Primitives::bundle(&[&a, &b, &c, &a]);

    let cos = holon::kernel::similarity::Similarity::cosine(&abc, &abca);
    let identical = abc.data() == abca.data();

    let mut diffs = 0;
    for (x, y) in abc.data().iter().zip(abca.data().iter()) {
        if x != y { diffs += 1; }
    }

    eprintln!("bundle(A,B,C) vs bundle(A,B,C,A):");
    eprintln!("  cosine: {:.4}", cos);
    eprintln!("  bit-identical: {}", identical);
    eprintln!("  dimensions that differ: {} / 10000", diffs);
}
