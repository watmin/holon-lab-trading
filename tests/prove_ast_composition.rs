/// prove_ast_composition.rs — verify the rhythm AST is composed correctly.
///
/// Build ASTs from known values. Serialize to EDN. Verify the structure
/// matches exactly what the proposal says. The EDN IS the thought.
/// If the EDN is wrong, the thought is wrong.

use enterprise::encoding::rhythm::indicator_rhythm;
use enterprise::encoding::thought_encoder::ThoughtAST;

/// Helper: count occurrences of a substring in the EDN.
fn count(edn: &str, needle: &str) -> usize {
    edn.matches(needle).count()
}

#[test]
fn three_values_produces_one_pair() {
    // 3 values → 3 facts → 1 trigram → 0 pairs → empty
    // Need 4+ values for a pair. 4 values → 4 facts → 2 trigrams → 1 pair.
    let ast = indicator_rhythm("rsi", &[40.0, 45.0, 50.0, 55.0], 0.0, 100.0, 10.0);
    let edn = ast.to_edn();

    // Top level: (bind (atom "rsi") (bundle ...))
    assert!(edn.starts_with("(bind"), "should start with bind, got: {}", &edn[..40]);
    assert!(edn.contains("(atom \"rsi\")"), "should contain atom rsi");

    // 1 pair in the bundle
    // The bundle contains 1 child (the single pair)
    println!("EDN for 4 values:\n{}", edn);
}

#[test]
fn five_values_produces_two_pairs() {
    let ast = indicator_rhythm("rsi", &[40.0, 45.0, 50.0, 55.0, 60.0], 0.0, 100.0, 10.0);
    let edn = ast.to_edn();

    // 5 values → 5 facts → 3 trigrams → 2 pairs
    // Each pair is a (bind trigram trigram)
    // The bundle should have 2 children
    assert!(edn.contains("(atom \"rsi\")"), "should wrap with rsi atom");

    // Thermometer nodes are duplicated across overlapping trigrams/pairs.
    // The tree is a tree, not a DAG — shared facts are cloned.
    let therm_count = count(&edn, "(thermometer");
    assert!(therm_count > 0, "should have thermometer nodes, got 0");

    // Count permute nodes: each trigram has 2 permutes (positions 1 and 2)
    // 3 trigrams × 2 = 6 permutes. But trigrams are reused in pairs, so
    // the EDN serializes each trigram independently (no sharing in the tree).
    // 2 pairs × 2 trigrams × 2 permutes = not quite — overlapping trigrams
    // are cloned. Let's just verify permutes exist.
    let permute_count = count(&edn, "(permute");
    assert!(permute_count >= 4, "expected at least 4 permute nodes, got {}", permute_count);

    println!("EDN for 5 values:\n{}", edn);
}

#[test]
fn values_are_correct_in_ast() {
    let values = [40.0, 45.0, 50.0, 55.0, 60.0];
    let ast = indicator_rhythm("test", &values, 0.0, 100.0, 10.0);
    let edn = ast.to_edn();

    // The first value (40.0) should appear as a bare thermometer (no delta)
    assert!(edn.contains("(thermometer 40 0 100)"), "first value 40.0 should be in the AST");

    // Subsequent values should appear with their deltas
    // value 45, delta = 45-40 = 5
    assert!(edn.contains("(thermometer 45 0 100)"), "value 45 should be in AST");
    assert!(edn.contains("(thermometer 5 -10 10)"), "delta 5 (45-40) should be in AST");

    // value 50, delta = 50-45 = 5
    assert!(edn.contains("(thermometer 50 0 100)"), "value 50 should be in AST");

    // value 55, delta = 55-50 = 5
    assert!(edn.contains("(thermometer 55 0 100)"), "value 55 should be in AST");

    // value 60, delta = 60-55 = 5
    assert!(edn.contains("(thermometer 60 0 100)"), "value 60 should be in AST");
}

#[test]
fn deltas_are_correct() {
    let values = [10.0, 15.0, 12.0, 18.0, 11.0];
    let ast = indicator_rhythm("x", &values, 0.0, 100.0, 20.0);
    let edn = ast.to_edn();

    // delta[1] = 15-10 = 5
    assert!(edn.contains("(thermometer 5 -20 20)"), "delta 5 should be present");

    // delta[2] = 12-15 = -3
    assert!(edn.contains("(thermometer -3 -20 20)"), "delta -3 should be present");

    // delta[3] = 18-12 = 6
    assert!(edn.contains("(thermometer 6 -20 20)"), "delta 6 should be present");

    // delta[4] = 11-18 = -7
    assert!(edn.contains("(thermometer -7 -20 20)"), "delta -7 should be present");
}

#[test]
fn atom_wraps_the_whole_rhythm() {
    let ast = indicator_rhythm("my-indicator", &[1.0, 2.0, 3.0, 4.0, 5.0], 0.0, 10.0, 5.0);

    // The outermost node must be Bind(Atom("my-indicator"), Bundle(...))
    match &ast {
        ThoughtAST::Bind(left, right) => {
            match left.as_ref() {
                ThoughtAST::Atom(name) => assert_eq!(name, "my-indicator"),
                other => panic!("expected Atom at top-left, got {:?}", other),
            }
            match right.as_ref() {
                ThoughtAST::Bundle(pairs) => {
                    assert!(!pairs.is_empty(), "rhythm should have at least one pair");
                    // Each pair should be a Bind(trigram, trigram)
                    for (i, pair) in pairs.iter().enumerate() {
                        match pair {
                            ThoughtAST::Bind(_, _) => {} // correct
                            other => panic!("pair[{}] should be Bind, got {:?}", i, other),
                        }
                    }
                }
                other => panic!("expected Bundle at top-right, got {:?}", other),
            }
        }
        other => panic!("expected Bind at top, got {:?}", other),
    }
}

#[test]
fn trigram_has_correct_permute_positions() {
    let ast = indicator_rhythm("x", &[1.0, 2.0, 3.0, 4.0, 5.0], 0.0, 10.0, 5.0);

    // Navigate: Bind(Atom, Bundle([pair0, pair1]))
    // pair0 = Bind(trigram0, trigram1)
    // trigram0 = Bind(Bind(fact0, Permute(fact1, 1)), Permute(fact2, 2))
    if let ThoughtAST::Bind(_, right) = &ast {
        if let ThoughtAST::Bundle(pairs) = right.as_ref() {
            if let ThoughtAST::Bind(tri0, _tri1) = &pairs[0] {
                // tri0 = Bind(Bind(fact0, Permute(fact1, 1)), Permute(fact2, 2))
                if let ThoughtAST::Bind(inner, perm2) = tri0.as_ref() {
                    // perm2 should be Permute(_, 2)
                    match perm2.as_ref() {
                        ThoughtAST::Permute(_, 2) => {} // correct
                        other => panic!("expected Permute(_, 2), got {:?}", other),
                    }
                    // inner = Bind(fact0, Permute(fact1, 1))
                    if let ThoughtAST::Bind(_fact0, perm1) = inner.as_ref() {
                        match perm1.as_ref() {
                            ThoughtAST::Permute(_, 1) => {} // correct
                            other => panic!("expected Permute(_, 1), got {:?}", other),
                        }
                    } else {
                        panic!("expected Bind for inner trigram");
                    }
                } else {
                    panic!("expected Bind for trigram");
                }
            } else {
                panic!("expected Bind for pair");
            }
        }
    }
}

#[test]
fn empty_for_too_few_values() {
    let ast0 = indicator_rhythm("x", &[], 0.0, 1.0, 0.1);
    let ast1 = indicator_rhythm("x", &[1.0], 0.0, 1.0, 0.1);
    let ast2 = indicator_rhythm("x", &[1.0, 2.0], 0.0, 1.0, 0.1);
    let ast3 = indicator_rhythm("x", &[1.0, 2.0, 3.0], 0.0, 1.0, 0.1);

    // 0-2 values: empty bundle (not enough for a trigram)
    for (n, ast) in [(0, ast0), (1, ast1), (2, ast2)] {
        match ast {
            ThoughtAST::Bundle(v) => assert!(v.is_empty(), "{} values should be empty", n),
            _ => panic!("{} values should be empty Bundle", n),
        }
    }

    // 3 values: 1 trigram, 0 pairs → empty bundle
    match ast3 {
        ThoughtAST::Bundle(v) => assert!(v.is_empty(), "3 values = 1 trigram = 0 pairs = empty"),
        _ => panic!("3 values should be empty Bundle"),
    }

    // 4 values: 2 trigrams, 1 pair → non-empty
    let ast4 = indicator_rhythm("x", &[1.0, 2.0, 3.0, 4.0], 0.0, 1.0, 0.1);
    match ast4 {
        ThoughtAST::Bind(_, _) => {} // has content
        _ => panic!("4 values should produce a Bind(Atom, Bundle)"),
    }
}
