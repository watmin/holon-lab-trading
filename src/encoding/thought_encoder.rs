/// thought_encoder.rs — the AST that vocabulary modules produce,
/// and the evaluator that walks it into vectors. Compiled from wat/thought-encoder.wat.
///
/// The ThoughtEncoder is stateless — no cache. Production encoding goes
/// through encoding::encode::encode() which checks the LRU. This struct
/// exists for tests and IncrementalBundle.

use std::collections::HashMap;

use holon::kernel::primitives::Primitives;
use holon::kernel::scalar::{ScalarEncoder, ScalarMode};
use holon::kernel::similarity::Similarity;
use holon::kernel::vector::Vector;
use holon::kernel::vector_manager::VectorManager;

#[derive(Clone, Debug, PartialEq)]
pub enum ThoughtAST {
    Atom(String),
    Linear { value: f64, scale: f64 },
    Log { value: f64 },
    Circular { value: f64, period: f64 },
    Bind(Box<ThoughtAST>, Box<ThoughtAST>),
    Bundle(Vec<ThoughtAST>),
    /// Ordered sequence — each item is permuted by its index before bundling.
    /// Position-sensitive: [A, B] != [B, A]. Used for pivot biography.
    Sequential(Vec<ThoughtAST>),
}

impl ThoughtAST {
    /// Extract the human-readable name of this AST node.
    /// Atoms have explicit names. Scalars describe their encoding.
    /// Bind returns "bind(<left>:<right>)".
    /// Bundle returns "bundle(<n>)" where n is the child count.
    pub fn name(&self) -> String {
        match self {
            ThoughtAST::Atom(name) => name.clone(),
            ThoughtAST::Linear { value, scale } => format!("linear({},{})", value, scale),
            ThoughtAST::Log { value } => format!("log({})", value),
            ThoughtAST::Circular { value, period } => format!("circular({},{})", value, period),
            ThoughtAST::Bind(left, right) => format!("bind({}:{})", left.name(), right.name()),
            ThoughtAST::Bundle(children) => format!("bundle({})", children.len()),
            ThoughtAST::Sequential(items) => format!("sequential({})", items.len()),
        }
    }

    /// Render as EDN (extensible data notation) — the thought AS lisp.
    /// Depth-aware indentation. Readable.
    pub fn to_edn(&self) -> String {
        self.to_edn_depth(0)
    }

    fn to_edn_depth(&self, depth: usize) -> String {
        let child_indent = "  ".repeat(depth + 1);
        match self {
            ThoughtAST::Atom(name) =>
                format!("(atom \"{}\")", name),
            ThoughtAST::Linear { value, scale } =>
                format!("(linear {} {})", value, scale),
            ThoughtAST::Log { value } =>
                format!("(log {})", value),
            ThoughtAST::Circular { value, period } =>
                format!("(circular {} {})", value, period),
            ThoughtAST::Bind(left, right) =>
                format!("(bind\n{}{}\n{}{})",
                    child_indent, left.to_edn_depth(depth + 1),
                    child_indent, right.to_edn_depth(depth + 1)),
            ThoughtAST::Bundle(children) => {
                let inner: Vec<String> = children.iter()
                    .map(|c| format!("{}{}", child_indent, c.to_edn_depth(depth + 1)))
                    .collect();
                format!("(bundle\n{})", inner.join("\n"))
            }
            ThoughtAST::Sequential(items) => {
                let inner: Vec<String> = items.iter()
                    .map(|c| format!("{}{}", child_indent, c.to_edn_depth(depth + 1)))
                    .collect();
                format!("(sequential\n{})", inner.join("\n"))
            }
        }
    }
}

// Eq/Hash via f64::to_bits() so ThoughtAST can be a HashMap key.
impl Eq for ThoughtAST {}

impl std::hash::Hash for ThoughtAST {
    fn hash<H: std::hash::Hasher>(&self, state: &mut H) {
        std::mem::discriminant(self).hash(state);
        match self {
            ThoughtAST::Atom(name) => name.hash(state),
            ThoughtAST::Linear { value, scale } => {
                value.to_bits().hash(state);
                scale.to_bits().hash(state);
            }
            ThoughtAST::Log { value } => {
                value.to_bits().hash(state);
            }
            ThoughtAST::Circular { value, period } => {
                value.to_bits().hash(state);
                period.to_bits().hash(state);
            }
            ThoughtAST::Bind(left, right) => {
                left.hash(state);
                right.hash(state);
            }
            ThoughtAST::Bundle(children) => {
                children.hash(state);
            }
            ThoughtAST::Sequential(items) => {
                items.hash(state);
            }
        }
    }
}

/// Round a value to N decimal places. Used by vocabulary modules
/// at emission time — the ThoughtAST carries the rounded value.
/// The cache key IS the exact AST. The rounding happens at emission.
pub fn round_to(v: f64, digits: u32) -> f64 {
    let factor = 10f64.powi(digits as i32);
    (v * factor).round() / factor
}

/// The evaluator. Walks ThoughtAST into vectors. Stateless — no cache.
/// Production encoding goes through encoding::encode::encode() which
/// checks the LRU cache. This struct exists for tests and IncrementalBundle.
#[derive(Clone)]
pub struct ThoughtEncoder {
    /// Scalar encoder for Linear/Log/Circular nodes.
    scalar_encoder: ScalarEncoder,
    /// VectorManager for atom allocation.
    vm: VectorManager,
}

impl ThoughtEncoder {
    /// Construct a new ThoughtEncoder.
    pub fn new(vm: VectorManager) -> Self {
        let dims = vm.dimensions();
        Self {
            scalar_encoder: ScalarEncoder::new(dims),
            vm,
        }
    }

    /// Recursive encode. Returns the vector.
    /// Used by tests and IncrementalBundle. Production uses encoding::encode::encode().
    pub fn encode(&self, ast: &ThoughtAST) -> Vector {
        match ast {
            ThoughtAST::Atom(name) => {
                self.vm.get_vector(name)
            }
            ThoughtAST::Linear { value, scale } => {
                self.scalar_encoder.encode(
                    *value,
                    ScalarMode::Linear { scale: *scale },
                )
            }
            ThoughtAST::Log { value } => {
                self.scalar_encoder.encode_log(*value)
            }
            ThoughtAST::Circular { value, period } => {
                self.scalar_encoder.encode(
                    *value,
                    ScalarMode::Circular { period: *period },
                )
            }
            ThoughtAST::Bind(left, right) => {
                let l_vec = self.encode(left);
                let r_vec = self.encode(right);
                Primitives::bind(&l_vec, &r_vec)
            }
            ThoughtAST::Bundle(children) => {
                let all_vecs: Vec<Vector> = children.iter()
                    .map(|child| self.encode(child))
                    .collect();
                let refs: Vec<&Vector> = all_vecs.iter().collect();
                if refs.is_empty() {
                    Vector::zeros(self.vm.dimensions())
                } else {
                    Primitives::bundle(&refs)
                }
            }
            ThoughtAST::Sequential(items) => {
                let all_vecs: Vec<Vector> = items.iter().enumerate()
                    .map(|(i, item)| {
                        let v = self.encode(item);
                        Primitives::permute(&v, i as i32)
                    })
                    .collect();
                let refs: Vec<&Vector> = all_vecs.iter().collect();
                if refs.is_empty() {
                    Vector::zeros(self.vm.dimensions())
                } else {
                    Primitives::bundle(&refs)
                }
            }
        }
    }

}

/// Incremental bundling — maintains sums across candles.
/// Optimization, not cognition. Can be reconstructed from one full encode.
///
/// The algebra: bundle = threshold(Σ vectors). If fact k changes from old to new,
/// sums_new = sums - old + new. threshold(sums_new) == bundle(all current facts).
/// Proven bit-identical. Integer addition is commutative and associative.
///
/// Invariant: round_to at vocab emission is load-bearing for the AST diff.
/// Quantized floats compare reliably. Remove round_to and this degrades to
/// full recompute (correct, but no savings).
pub struct IncrementalBundle {
    /// Running element-wise sums (i32). threshold(sums) == bundle(all facts).
    sums: Vec<i32>,
    /// Previous candle's facts: AST → its evaluated vector.
    last_facts: HashMap<ThoughtAST, Vector>,
    /// Dimensions.
    dims: usize,
    /// Whether we've done at least one full encode.
    initialized: bool,
}

impl IncrementalBundle {
    pub fn new(dims: usize) -> Self {
        Self {
            sums: vec![0i32; dims],
            last_facts: HashMap::new(),
            dims,
            initialized: false,
        }
    }

    /// Encode facts incrementally. Returns the thought vector.
    ///
    /// First candle: full encode, populate sums and last_facts.
    /// Subsequent candles: diff against last_facts, patch sums, threshold.
    ///
    /// Uses the ThoughtEncoder to evaluate individual changed facts.
    /// The sums buffer avoids re-summing unchanged facts.
    pub fn encode(
        &mut self,
        new_facts: &[ThoughtAST],
        encoder: &ThoughtEncoder,
    ) -> Vector {
        if !self.initialized {
            return self.full_encode(new_facts, encoder);
        }

        let mut new_last_facts = HashMap::with_capacity(new_facts.len());

        // Build set of new facts for O(1) lookup
        let new_set: std::collections::HashSet<&ThoughtAST> = new_facts.iter().collect();

        // REMOVED: in last_facts but not in new_facts — subtract from sums
        for (old_ast, old_vec) in &self.last_facts {
            if !new_set.contains(old_ast) {
                for (s, &val) in self.sums.iter_mut().zip(old_vec.data()) {
                    *s -= val as i32;
                }
            }
        }

        // For each new fact: check if it existed last candle
        for fact in new_facts {
            if let Some(old_vec) = self.last_facts.get(fact) {
                // UNCHANGED — zero work. sums already has this contribution.
                new_last_facts.insert(fact.clone(), old_vec.clone());
            } else {
                // CHANGED or ADDED — encode, add to sums
                let new_vec = encoder.encode(fact);
                // Add new contribution
                for (s, &val) in self.sums.iter_mut().zip(new_vec.data()) {
                    *s += val as i32;
                }
                new_last_facts.insert(fact.clone(), new_vec);
            }
        }

        self.last_facts = new_last_facts;

        // Threshold the sums
        self.threshold()
    }

    /// First candle: full encode from scratch.
    fn full_encode(
        &mut self,
        facts: &[ThoughtAST],
        encoder: &ThoughtEncoder,
    ) -> Vector {
        self.sums.iter_mut().for_each(|s| *s = 0);
        self.last_facts.clear();

        for fact in facts {
            let vec = encoder.encode(fact);
            for (s, &val) in self.sums.iter_mut().zip(vec.data()) {
                *s += val as i32;
            }
            self.last_facts.insert(fact.clone(), vec);
        }

        self.initialized = true;
        self.threshold()
    }

    /// Apply sign threshold to sums, producing the bundled vector.
    fn threshold(&self) -> Vector {
        let mut out = Vector::zeros(self.dims);
        for (o, &s) in out.data_mut().iter_mut().zip(self.sums.iter()) {
            *o = if s > 0 { 1 } else if s < 0 { -1 } else { 0 };
        }
        out
    }
}

/// Flat extraction — query each form's presence in a thought vector.
/// No hierarchy. No threshold. The consumer filters.
///
/// Accepts a closure that encodes a ThoughtAST into a Vector.
/// On hot paths, pass encoding::encode::encode (which checks the LRU).
/// At startup or in tests, pass ThoughtEncoder::encode directly.
// rune:reap(scaffolding) — awaiting Phase 6 discriminant decode. Not dead, ahead of its consumer.
pub fn extract<F>(thought_vec: &Vector, forms: &[ThoughtAST], encode_fn: F) -> Vec<(ThoughtAST, f64)>
where
    F: Fn(&ThoughtAST) -> Vector,
{
    forms.iter().map(|form| {
        let form_vec = encode_fn(form);
        let presence = Similarity::cosine(&form_vec, thought_vec);
        (form.clone(), presence)
    }).collect()
}

/// Recursively collect all non-Bundle leaf nodes from an AST tree.
/// Bundle nodes are expanded; all other nodes (Atom, Linear, Log, Circular, Bind)
/// are returned as-is.
/// Collect all factual statements (Linear, Log, Circular) from an AST tree.
/// These are the "binds" — named scalar facts: "rsi is 0.73", "atr-ratio is 0.02".
/// Bundles are recursed into. Bare Atoms are skipped — they are names without values.
/// Bind nodes are returned as-is — they are compound factual statements.
pub fn collect_facts(ast: &ThoughtAST) -> Vec<ThoughtAST> {
    match ast {
        ThoughtAST::Bundle(children) => {
            children.iter().flat_map(collect_facts).collect()
        }
        ThoughtAST::Sequential(items) => {
            items.iter().flat_map(collect_facts).collect()
        }
        ThoughtAST::Atom(_) => vec![], // name without value — not a fact
        _ => vec![ast.clone()], // Linear, Log, Circular, Bind — factual statements
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const DIMS: usize = 4096;

    fn make_encoder() -> ThoughtEncoder {
        let vm = VectorManager::new(DIMS);
        ThoughtEncoder::new(vm)
    }

    #[test]
    fn test_thought_ast_variants() {
        let a = ThoughtAST::Atom("rsi".into());
        let l = ThoughtAST::Bind(
            Box::new(ThoughtAST::Atom("rsi".into())),
            Box::new(ThoughtAST::Linear { value: 0.5, scale: 1.0 }),
        );
        let g = ThoughtAST::Bind(
            Box::new(ThoughtAST::Atom("vol".into())),
            Box::new(ThoughtAST::Log { value: 2.0 }),
        );
        let c = ThoughtAST::Bind(
            Box::new(ThoughtAST::Atom("hour".into())),
            Box::new(ThoughtAST::Circular { value: 14.0, period: 24.0 }),
        );
        let b = ThoughtAST::Bind(Box::new(a.clone()), Box::new(l.clone()));
        let u = ThoughtAST::Bundle(vec![a, l, g, c]);
        assert!(matches!(b, ThoughtAST::Bind(_, _)));
        assert!(matches!(u, ThoughtAST::Bundle(_)));
    }

    #[test]
    fn test_encode_atom_returns_vector() {
        let enc = make_encoder();
        let v = enc.encode(&ThoughtAST::Atom("rsi".into()));
        assert_eq!(v.dimensions(), DIMS);
        assert!(v.nnz() > 0);
    }

    #[test]
    fn test_encode_atom_deterministic() {
        let enc = make_encoder();
        let v1 = enc.encode(&ThoughtAST::Atom("rsi".into()));
        let v2 = enc.encode(&ThoughtAST::Atom("rsi".into()));
        assert_eq!(v1, v2);
    }

    #[test]
    fn test_encode_bind_atom_log_produces_bound_vector() {
        let enc = make_encoder();
        let ast = ThoughtAST::Bind(
            Box::new(ThoughtAST::Atom("vol".into())),
            Box::new(ThoughtAST::Log { value: 100.0 }),
        );
        let v = enc.encode(&ast);
        assert_eq!(v.dimensions(), DIMS);
        assert!(v.nnz() > 0);
    }

    #[test]
    fn test_encode_bundle() {
        let enc = make_encoder();
        let ast = ThoughtAST::Bundle(vec![
            ThoughtAST::Atom("rsi".into()),
            ThoughtAST::Atom("vol".into()),
        ]);
        let v = enc.encode(&ast);
        assert_eq!(v.dimensions(), DIMS);
        assert!(v.nnz() > 0);
    }

    #[test]
    fn test_encode_bind() {
        let enc = make_encoder();
        let ast = ThoughtAST::Bind(
            Box::new(ThoughtAST::Atom("rsi".into())),
            Box::new(ThoughtAST::Atom("vol".into())),
        );
        let v = enc.encode(&ast);
        assert_eq!(v.dimensions(), DIMS);
        assert!(v.nnz() > 0);
    }

    #[test]
    fn test_encode_deterministic_across_calls() {
        let enc = make_encoder();
        let ast = ThoughtAST::Bind(
            Box::new(ThoughtAST::Atom("vol".into())),
            Box::new(ThoughtAST::Log { value: 50.0 }),
        );

        let v1 = enc.encode(&ast);
        let v2 = enc.encode(&ast);
        assert_eq!(v1, v2);
    }

    #[test]
    fn test_thought_ast_name() {
        assert_eq!(ThoughtAST::Atom("rsi".into()).name(), "rsi");
        assert_eq!((ThoughtAST::Linear { value: 1.0, scale: 1.0 }).name(), "linear(1,1)");
        assert_eq!((ThoughtAST::Log { value: 2.0 }).name(), "log(2)");
        assert_eq!((ThoughtAST::Circular { value: 14.0, period: 24.0 }).name(), "circular(14,24)");
        // Bind(Atom, Linear) — name is bind(vol:linear(1,1))
        assert_eq!(ThoughtAST::Bind(
            Box::new(ThoughtAST::Atom("vol".into())),
            Box::new(ThoughtAST::Linear { value: 1.0, scale: 1.0 }),
        ).name(), "bind(vol:linear(1,1))");
        let bind = ThoughtAST::Bind(
            Box::new(ThoughtAST::Atom("a".into())),
            Box::new(ThoughtAST::Atom("b".into())),
        );
        assert_eq!(bind.name(), "bind(a:b)");
        let bundle = ThoughtAST::Bundle(vec![
            ThoughtAST::Atom("x".into()),
            ThoughtAST::Atom("y".into()),
        ]);
        assert_eq!(bundle.name(), "bundle(2)");
    }

    #[test]
    fn test_extract_flat_self_cosine() {
        let enc = make_encoder();
        let leaf = ThoughtAST::Bind(
                Box::new(ThoughtAST::Atom("rsi".into())),
                Box::new(ThoughtAST::Linear { value: 0.7, scale: 1.0 }),
            );
        // Encode the leaf to get a vector, use it as the thought
        let leaf_vec = enc.encode(&leaf);
        let results = extract(&leaf_vec, &[leaf.clone()], |ast| enc.encode(ast));
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].0, leaf);
        // Self-cosine should be high (close to 1.0)
        assert!(results[0].1 > 0.9, "self-cosine should be high, got {}", results[0].1);
    }

    #[test]
    fn test_extract_flat_multiple_forms() {
        let enc = make_encoder();
        let forms = vec![
            ThoughtAST::Bind(
                Box::new(ThoughtAST::Atom("rsi".into())),
                Box::new(ThoughtAST::Linear { value: 0.7, scale: 1.0 }),
            ),
            ThoughtAST::Bind(
                Box::new(ThoughtAST::Atom("vol".into())),
                Box::new(ThoughtAST::Linear { value: 1.5, scale: 1.0 }),
            ),
            ThoughtAST::Bind(
                Box::new(ThoughtAST::Atom("trend".into())),
                Box::new(ThoughtAST::Linear { value: 0.3, scale: 1.0 }),
            ),
        ];
        // Bundle all forms, then extract — each form should have non-trivial presence
        let bundle = ThoughtAST::Bundle(forms.clone());
        let thought_vec = enc.encode(&bundle);
        let results = extract(&thought_vec, &forms, |ast| enc.encode(ast));
        assert_eq!(results.len(), 3);
        // Each bundled form should have positive cosine with the bundle
        for (_ast, cos) in &results {
            assert!(*cos > 0.0, "bundled form should have positive cosine, got {}", cos);
        }
    }

    #[test]
    fn test_extract_flat_unrelated_low_cosine() {
        let enc = make_encoder();
        let forms = vec![
            ThoughtAST::Bind(
                Box::new(ThoughtAST::Atom("rsi".into())),
                Box::new(ThoughtAST::Linear { value: 0.7, scale: 1.0 }),
            ),
        ];
        // Use an unrelated vector
        let unrelated = ThoughtAST::Bind(
            Box::new(ThoughtAST::Atom("hour".into())),
            Box::new(ThoughtAST::Linear { value: 12.0, scale: 24.0 }),
        );
        let unrelated_vec = enc.encode(&unrelated);
        let results = extract(&unrelated_vec, &forms, |ast| enc.encode(ast));
        assert_eq!(results.len(), 1);
        // Cosine between unrelated vectors should be near zero
        assert!(results[0].1.abs() < 0.2, "unrelated cosine should be near zero, got {}", results[0].1);
    }

    #[test]
    fn test_extract_flat_no_threshold() {
        let enc = make_encoder();
        // Extract always returns ALL forms, no filtering
        let forms = vec![
            ThoughtAST::Bind(
                Box::new(ThoughtAST::Atom("rsi".into())),
                Box::new(ThoughtAST::Linear { value: 0.7, scale: 1.0 }),
            ),
            ThoughtAST::Bind(
                Box::new(ThoughtAST::Atom("vol".into())),
                Box::new(ThoughtAST::Linear { value: 1.5, scale: 1.0 }),
            ),
        ];
        let unrelated = ThoughtAST::Bind(
            Box::new(ThoughtAST::Atom("hour".into())),
            Box::new(ThoughtAST::Linear { value: 12.0, scale: 24.0 }),
        );
        let unrelated_vec = enc.encode(&unrelated);
        let results = extract(&unrelated_vec, &forms, |ast| enc.encode(ast));
        // Both forms returned regardless of cosine value
        assert_eq!(results.len(), 2);
    }

    #[test]
    fn test_extract_flat_bind_form() {
        let enc = make_encoder();
        let bind = ThoughtAST::Bind(
            Box::new(ThoughtAST::Atom("rsi".into())),
            Box::new(ThoughtAST::Atom("vol".into())),
        );
        let bind_vec = enc.encode(&bind);
        let results = extract(&bind_vec, &[bind.clone()], |ast| enc.encode(ast));
        assert_eq!(results.len(), 1);
        assert!(matches!(results[0].0, ThoughtAST::Bind(_, _)));
        assert!(results[0].1 > 0.9);
    }

    #[test]
    fn test_collect_facts_atom_skipped() {
        let ast = ThoughtAST::Atom("rsi".into());
        let facts = collect_facts(&ast);
        assert_eq!(facts.len(), 0); // bare atom is not a fact
    }

    #[test]
    fn test_collect_facts_bundle() {
        let ast = ThoughtAST::Bundle(vec![
            ThoughtAST::Bind(
                Box::new(ThoughtAST::Atom("rsi".into())),
                Box::new(ThoughtAST::Linear { value: 0.7, scale: 1.0 }),
            ),
            ThoughtAST::Bind(
                Box::new(ThoughtAST::Atom("vol".into())),
                Box::new(ThoughtAST::Log { value: 2.0 }),
            ),
            ThoughtAST::Atom("trend".into()), // skipped
        ]);
        let facts = collect_facts(&ast);
        assert_eq!(facts.len(), 2); // named scalars (Bind nodes), not bare Atom
    }

    #[test]
    fn test_collect_facts_nested_bundles() {
        let ast = ThoughtAST::Bundle(vec![
            ThoughtAST::Bundle(vec![
                ThoughtAST::Bind(
                Box::new(ThoughtAST::Atom("rsi".into())),
                Box::new(ThoughtAST::Linear { value: 0.7, scale: 1.0 }),
            ),
                ThoughtAST::Bind(
                Box::new(ThoughtAST::Atom("vol".into())),
                Box::new(ThoughtAST::Linear { value: 1.5, scale: 1.0 }),
            ),
            ]),
            ThoughtAST::Bind(
            Box::new(ThoughtAST::Atom("trend".into())),
            Box::new(ThoughtAST::Log { value: 0.03 }),
        ),
        ]);
        let facts = collect_facts(&ast);
        assert_eq!(facts.len(), 3);
        for fact in &facts {
            assert!(!matches!(fact, ThoughtAST::Bundle(_)));
            assert!(!matches!(fact, ThoughtAST::Atom(_)));
        }
    }

    #[test]
    fn test_collect_facts_bind_is_fact() {
        let bind = ThoughtAST::Bind(
            Box::new(ThoughtAST::Atom("a".into())),
            Box::new(ThoughtAST::Atom("b".into())),
        );
        let ast = ThoughtAST::Bundle(vec![bind.clone(), ThoughtAST::Atom("c".into())]);
        let facts = collect_facts(&ast);
        assert_eq!(facts.len(), 1); // Bind is a fact, Atom is not
        assert!(matches!(&facts[0], ThoughtAST::Bind(_, _)));
    }
}
