/// thought_encoder.rs — the AST that vocabulary modules produce.
///
/// This file defines the data: ThoughtASTKind (variants), ThoughtAST
/// (kind + precomputed hash), the Hash/Eq impls, the children() and
/// EDN-render helpers. Encoding into vectors lives in encoding::encode.
///
/// Compiled from wat/thought-encoder.wat.

use std::hash::Hash;
use std::sync::Arc;

use holon::kernel::similarity::Similarity;
use holon::kernel::vector::Vector;

/// The kind of AST node — variant only, no precomputed hash.
/// Arc on Bind/Permute children — shared nodes, not copied trees.
/// Clone is a pointer increment for shared subtrees.
#[derive(Clone, Debug, PartialEq)]
pub enum ThoughtASTKind {
    Atom(String),
    Linear { value: f64, scale: f64 },
    Log { value: f64 },
    Circular { value: f64, period: f64 },
    /// Thermometer — linear gradient that survives bipolar thresholding.
    /// cosine(a, b) = 1.0 - 2.0 * |a - b| / (max - min). Proposal 056.
    Thermometer { value: f64, min: f64, max: f64 },
    Bind(Arc<ThoughtAST>, Arc<ThoughtAST>),
    Bundle(Vec<ThoughtAST>),
    /// Positional shift — circular permutation of dimensions by `shift` positions.
    /// Encodes position within a composition. Proposal 056.
    Permute(Arc<ThoughtAST>, i32),
    /// Ordered sequence — each item is permuted by its index before bundling.
    /// Position-sensitive: [A, B] != [B, A]. Used for pivot biography.
    Sequential(Vec<ThoughtAST>),
}

impl Eq for ThoughtASTKind {}

impl std::hash::Hash for ThoughtASTKind {
    fn hash<H: std::hash::Hasher>(&self, state: &mut H) {
        std::mem::discriminant(self).hash(state);
        match self {
            ThoughtASTKind::Atom(name) => name.hash(state),
            ThoughtASTKind::Linear { value, scale } => {
                value.to_bits().hash(state);
                scale.to_bits().hash(state);
            }
            ThoughtASTKind::Log { value } => {
                value.to_bits().hash(state);
            }
            ThoughtASTKind::Circular { value, period } => {
                value.to_bits().hash(state);
                period.to_bits().hash(state);
            }
            ThoughtASTKind::Thermometer { value, min, max } => {
                value.to_bits().hash(state);
                min.to_bits().hash(state);
                max.to_bits().hash(state);
            }
            ThoughtASTKind::Permute(child, shift) => {
                child.hash(state);
                shift.hash(state);
            }
            ThoughtASTKind::Bind(left, right) => {
                left.hash(state);
                right.hash(state);
            }
            ThoughtASTKind::Bundle(children) => {
                children.hash(state);
            }
            ThoughtASTKind::Sequential(items) => {
                items.hash(state);
            }
        }
    }
}

/// The thought. The identity. The AST IS the thought.
/// Precomputes the hash at construction time so cache lookups
/// never walk the AST tree — O(1) instead of O(tree size).
#[derive(Clone, Debug)]
pub struct ThoughtAST {
    pub kind: ThoughtASTKind,
    hash: u64,
}

impl ThoughtAST {
    pub fn new(kind: ThoughtASTKind) -> Self {
        let mut hasher = std::collections::hash_map::DefaultHasher::new();
        kind.hash(&mut hasher);
        Self { kind, hash: std::hash::Hasher::finish(&hasher) }
    }

    /// The precomputed hash. Use as cache key directly.
    pub fn precomputed_hash(&self) -> u64 {
        self.hash
    }
}

impl std::hash::Hash for ThoughtAST {
    fn hash<H: std::hash::Hasher>(&self, state: &mut H) {
        self.hash.hash(state);
    }
}

impl PartialEq for ThoughtAST {
    fn eq(&self, other: &Self) -> bool {
        self.hash == other.hash && self.kind == other.kind
    }
}

impl Eq for ThoughtAST {}

impl ThoughtASTKind {
    /// Extract the human-readable name of this AST node kind.
    pub fn name(&self) -> String {
        match self {
            ThoughtASTKind::Atom(name) => name.clone(),
            ThoughtASTKind::Linear { value, scale } => format!("linear({},{})", value, scale),
            ThoughtASTKind::Log { value } => format!("log({})", value),
            ThoughtASTKind::Circular { value, period } => format!("circular({},{})", value, period),
            ThoughtASTKind::Thermometer { value, min, max } => format!("thermometer({},{},{})", value, min, max),
            ThoughtASTKind::Bind(left, right) => format!("bind({}:{})", left.name(), right.name()),
            ThoughtASTKind::Bundle(children) => format!("bundle({})", children.len()),
            ThoughtASTKind::Permute(child, shift) => format!("permute({},{})", child.name(), shift),
            ThoughtASTKind::Sequential(items) => format!("sequential({})", items.len()),
        }
    }

    /// Direct children of this node kind. Leaves return empty.
    pub fn children(&self) -> Vec<ThoughtAST> {
        match self {
            ThoughtASTKind::Bind(l, r) => vec![l.as_ref().clone(), r.as_ref().clone()],
            ThoughtASTKind::Permute(c, _) => vec![c.as_ref().clone()],
            ThoughtASTKind::Bundle(children) => children.clone(),
            ThoughtASTKind::Sequential(items) => items.clone(),
            _ => vec![], // Atom, Linear, Log, Circular, Thermometer — leaves
        }
    }

    /// Render as EDN (extensible data notation).
    pub fn to_edn(&self) -> String {
        self.to_edn_depth(0)
    }

    fn to_edn_depth(&self, depth: usize) -> String {
        let child_indent = "  ".repeat(depth + 1);
        match self {
            ThoughtASTKind::Atom(name) =>
                format!("(atom \"{}\")", name),
            ThoughtASTKind::Linear { value, scale } =>
                format!("(linear {} {})", value, scale),
            ThoughtASTKind::Log { value } =>
                format!("(log {})", value),
            ThoughtASTKind::Circular { value, period } =>
                format!("(circular {} {})", value, period),
            ThoughtASTKind::Thermometer { value, min, max } =>
                format!("(thermometer {} {} {})", value, min, max),
            ThoughtASTKind::Bind(left, right) =>
                format!("(bind\n{}{}\n{}{})",
                    child_indent, left.kind.to_edn_depth(depth + 1),
                    child_indent, right.kind.to_edn_depth(depth + 1)),
            ThoughtASTKind::Permute(child, shift) =>
                format!("(permute\n{}{}\n{}{})",
                    child_indent, child.kind.to_edn_depth(depth + 1),
                    child_indent, shift),
            ThoughtASTKind::Bundle(children) => {
                let inner: Vec<String> = children.iter()
                    .map(|c| format!("{}{}", child_indent, c.kind.to_edn_depth(depth + 1)))
                    .collect();
                format!("(bundle\n{})", inner.join("\n"))
            }
            ThoughtASTKind::Sequential(items) => {
                let inner: Vec<String> = items.iter()
                    .map(|c| format!("{}{}", child_indent, c.kind.to_edn_depth(depth + 1)))
                    .collect();
                format!("(sequential\n{})", inner.join("\n"))
            }
        }
    }
}

impl ThoughtAST {
    /// Extract the human-readable name of this AST node.
    pub fn name(&self) -> String { self.kind.name() }

    /// Direct children of this node. Leaves return empty.
    pub fn children(&self) -> Vec<ThoughtAST> { self.kind.children() }

    /// Render as EDN (extensible data notation) — the thought AS lisp.
    pub fn to_edn(&self) -> String { self.kind.to_edn() }
}


/// Round a value to N decimal places. Used by vocabulary modules
/// at emission time — the ThoughtAST carries the rounded value.
/// The cache key IS the exact AST. The rounding happens at emission.
pub fn round_to(v: f64, digits: u32) -> f64 {
    let factor = 10f64.powi(digits as i32);
    (v * factor).round() / factor
}

/// Flat extraction — query each form's presence in a thought vector.
/// No hierarchy. No threshold. The consumer filters.
///
/// Accepts a closure that encodes a ThoughtAST into a Vector.
/// Callers pass encoding::encode::encode (or test_support::TestEncodeEnv).
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
    match &ast.kind {
        ThoughtASTKind::Bundle(children) => {
            children.iter().flat_map(collect_facts).collect()
        }
        ThoughtASTKind::Sequential(items) => {
            items.iter().flat_map(collect_facts).collect()
        }
        ThoughtASTKind::Atom(_) => vec![],
        ThoughtASTKind::Linear { .. } => vec![ast.clone()],
        ThoughtASTKind::Log { .. } => vec![ast.clone()],
        ThoughtASTKind::Circular { .. } => vec![ast.clone()],
        ThoughtASTKind::Thermometer { .. } => vec![ast.clone()],
        ThoughtASTKind::Bind(_, _) => vec![ast.clone()],
        ThoughtASTKind::Permute(_, _) => vec![ast.clone()],
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::encoding::encode::test_support::TestEncodeEnv;

    const DIMS: usize = 4096;

    #[test]
    fn test_thought_ast_variants() {
        let a = ThoughtAST::new(ThoughtASTKind::Atom("rsi".into()));
        let l = ThoughtAST::new(ThoughtASTKind::Bind(
            Arc::new(ThoughtAST::new(ThoughtASTKind::Atom("rsi".into()))),
            Arc::new(ThoughtAST::new(ThoughtASTKind::Linear { value: 0.5, scale: 1.0 })),
        ));
        let g = ThoughtAST::new(ThoughtASTKind::Bind(
            Arc::new(ThoughtAST::new(ThoughtASTKind::Atom("vol".into()))),
            Arc::new(ThoughtAST::new(ThoughtASTKind::Log { value: 2.0 })),
        ));
        let c = ThoughtAST::new(ThoughtASTKind::Bind(
            Arc::new(ThoughtAST::new(ThoughtASTKind::Atom("hour".into()))),
            Arc::new(ThoughtAST::new(ThoughtASTKind::Circular { value: 14.0, period: 24.0 })),
        ));
        let b = ThoughtAST::new(ThoughtASTKind::Bind(Arc::new(a.clone()), Arc::new(l.clone())));
        let u = ThoughtAST::new(ThoughtASTKind::Bundle(vec![a, l, g, c]));
        assert!(matches!(b.kind, ThoughtASTKind::Bind(_, _)));
        assert!(matches!(u.kind, ThoughtASTKind::Bundle(_)));
    }

    #[test]
    fn test_encode_atom_returns_vector() {
        let mut env = TestEncodeEnv::new(DIMS);
        let v = env.encode(&ThoughtAST::new(ThoughtASTKind::Atom("rsi".into())));
        assert_eq!(v.dimensions(), DIMS);
        assert!(v.nnz() > 0);
    }

    #[test]
    fn test_encode_atom_deterministic() {
        let mut env = TestEncodeEnv::new(DIMS);
        let v1 = env.encode(&ThoughtAST::new(ThoughtASTKind::Atom("rsi".into())));
        let v2 = env.encode(&ThoughtAST::new(ThoughtASTKind::Atom("rsi".into())));
        assert_eq!(v1, v2);
    }

    #[test]
    fn test_encode_bind_atom_log_produces_bound_vector() {
        let mut env = TestEncodeEnv::new(DIMS);
        let ast = ThoughtAST::new(ThoughtASTKind::Bind(
            Arc::new(ThoughtAST::new(ThoughtASTKind::Atom("vol".into()))),
            Arc::new(ThoughtAST::new(ThoughtASTKind::Log { value: 100.0 })),
        ));
        let v = env.encode(&ast);
        assert_eq!(v.dimensions(), DIMS);
        assert!(v.nnz() > 0);
    }

    #[test]
    fn test_encode_bundle() {
        let mut env = TestEncodeEnv::new(DIMS);
        let ast = ThoughtAST::new(ThoughtASTKind::Bundle(vec![
            ThoughtAST::new(ThoughtASTKind::Atom("rsi".into())),
            ThoughtAST::new(ThoughtASTKind::Atom("vol".into())),
        ]));
        let v = env.encode(&ast);
        assert_eq!(v.dimensions(), DIMS);
        assert!(v.nnz() > 0);
    }

    #[test]
    fn test_encode_bind() {
        let mut env = TestEncodeEnv::new(DIMS);
        let ast = ThoughtAST::new(ThoughtASTKind::Bind(
            Arc::new(ThoughtAST::new(ThoughtASTKind::Atom("rsi".into()))),
            Arc::new(ThoughtAST::new(ThoughtASTKind::Atom("vol".into()))),
        ));
        let v = env.encode(&ast);
        assert_eq!(v.dimensions(), DIMS);
        assert!(v.nnz() > 0);
    }

    #[test]
    fn test_encode_deterministic_across_calls() {
        let mut env = TestEncodeEnv::new(DIMS);
        let ast = ThoughtAST::new(ThoughtASTKind::Bind(
            Arc::new(ThoughtAST::new(ThoughtASTKind::Atom("vol".into()))),
            Arc::new(ThoughtAST::new(ThoughtASTKind::Log { value: 50.0 })),
        ));

        let v1 = env.encode(&ast);
        let v2 = env.encode(&ast);
        assert_eq!(v1, v2);
    }

    #[test]
    fn test_thought_ast_name() {
        assert_eq!(ThoughtAST::new(ThoughtASTKind::Atom("rsi".into())).name(), "rsi");
        assert_eq!(ThoughtAST::new(ThoughtASTKind::Linear { value: 1.0, scale: 1.0 }).name(), "linear(1,1)");
        assert_eq!(ThoughtAST::new(ThoughtASTKind::Log { value: 2.0 }).name(), "log(2)");
        assert_eq!(ThoughtAST::new(ThoughtASTKind::Circular { value: 14.0, period: 24.0 }).name(), "circular(14,24)");
        // Bind(Atom, Linear) — name is bind(vol:linear(1,1))
        assert_eq!(ThoughtAST::new(ThoughtASTKind::Bind(
            Arc::new(ThoughtAST::new(ThoughtASTKind::Atom("vol".into()))),
            Arc::new(ThoughtAST::new(ThoughtASTKind::Linear { value: 1.0, scale: 1.0 })),
        )).name(), "bind(vol:linear(1,1))");
        let bind = ThoughtAST::new(ThoughtASTKind::Bind(
            Arc::new(ThoughtAST::new(ThoughtASTKind::Atom("a".into()))),
            Arc::new(ThoughtAST::new(ThoughtASTKind::Atom("b".into()))),
        ));
        assert_eq!(bind.name(), "bind(a:b)");
        let bundle = ThoughtAST::new(ThoughtASTKind::Bundle(vec![
            ThoughtAST::new(ThoughtASTKind::Atom("x".into())),
            ThoughtAST::new(ThoughtASTKind::Atom("y".into())),
        ]));
        assert_eq!(bundle.name(), "bundle(2)");
    }

    /// Helper: pre-encode a slice of forms into a HashMap for use with
    /// `extract`. `extract` takes `Fn(&ThoughtAST) -> Vector`; the closure
    /// looks up in the map instead of calling the mutable env encoder.
    fn prebuild(env: &mut TestEncodeEnv, forms: &[ThoughtAST]) -> std::collections::HashMap<ThoughtAST, Vector> {
        forms.iter().map(|f| (f.clone(), env.encode(f))).collect()
    }

    #[test]
    fn test_extract_flat_self_cosine() {
        let mut env = TestEncodeEnv::new(DIMS);
        let leaf = ThoughtAST::new(ThoughtASTKind::Bind(
                Arc::new(ThoughtAST::new(ThoughtASTKind::Atom("rsi".into()))),
                Arc::new(ThoughtAST::new(ThoughtASTKind::Linear { value: 0.7, scale: 1.0 })),
            ));
        let leaf_vec = env.encode(&leaf);
        let prebuilt = prebuild(&mut env, &[leaf.clone()]);
        let results = extract(&leaf_vec, &[leaf.clone()], |ast| prebuilt[ast].clone());
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].0, leaf);
        // Self-cosine should be high (close to 1.0)
        assert!(results[0].1 > 0.9, "self-cosine should be high, got {}", results[0].1);
    }

    #[test]
    fn test_extract_flat_multiple_forms() {
        let mut env = TestEncodeEnv::new(DIMS);
        let forms = vec![
            ThoughtAST::new(ThoughtASTKind::Bind(
                Arc::new(ThoughtAST::new(ThoughtASTKind::Atom("rsi".into()))),
                Arc::new(ThoughtAST::new(ThoughtASTKind::Linear { value: 0.7, scale: 1.0 })),
            )),
            ThoughtAST::new(ThoughtASTKind::Bind(
                Arc::new(ThoughtAST::new(ThoughtASTKind::Atom("vol".into()))),
                Arc::new(ThoughtAST::new(ThoughtASTKind::Linear { value: 1.5, scale: 1.0 })),
            )),
            ThoughtAST::new(ThoughtASTKind::Bind(
                Arc::new(ThoughtAST::new(ThoughtASTKind::Atom("trend".into()))),
                Arc::new(ThoughtAST::new(ThoughtASTKind::Linear { value: 0.3, scale: 1.0 })),
            )),
        ];
        let bundle = ThoughtAST::new(ThoughtASTKind::Bundle(forms.clone()));
        let thought_vec = env.encode(&bundle);
        let prebuilt = prebuild(&mut env, &forms);
        let results = extract(&thought_vec, &forms, |ast| prebuilt[ast].clone());
        assert_eq!(results.len(), 3);
        for (_ast, cos) in &results {
            assert!(*cos > 0.0, "bundled form should have positive cosine, got {}", cos);
        }
    }

    #[test]
    fn test_extract_flat_unrelated_low_cosine() {
        let mut env = TestEncodeEnv::new(DIMS);
        let forms = vec![
            ThoughtAST::new(ThoughtASTKind::Bind(
                Arc::new(ThoughtAST::new(ThoughtASTKind::Atom("rsi".into()))),
                Arc::new(ThoughtAST::new(ThoughtASTKind::Linear { value: 0.7, scale: 1.0 })),
            )),
        ];
        let unrelated = ThoughtAST::new(ThoughtASTKind::Bind(
            Arc::new(ThoughtAST::new(ThoughtASTKind::Atom("hour".into()))),
            Arc::new(ThoughtAST::new(ThoughtASTKind::Linear { value: 12.0, scale: 24.0 })),
        ));
        let unrelated_vec = env.encode(&unrelated);
        let prebuilt = prebuild(&mut env, &forms);
        let results = extract(&unrelated_vec, &forms, |ast| prebuilt[ast].clone());
        assert_eq!(results.len(), 1);
        assert!(results[0].1.abs() < 0.2, "unrelated cosine should be near zero, got {}", results[0].1);
    }

    #[test]
    fn test_extract_flat_no_threshold() {
        let mut env = TestEncodeEnv::new(DIMS);
        let forms = vec![
            ThoughtAST::new(ThoughtASTKind::Bind(
                Arc::new(ThoughtAST::new(ThoughtASTKind::Atom("rsi".into()))),
                Arc::new(ThoughtAST::new(ThoughtASTKind::Linear { value: 0.7, scale: 1.0 })),
            )),
            ThoughtAST::new(ThoughtASTKind::Bind(
                Arc::new(ThoughtAST::new(ThoughtASTKind::Atom("vol".into()))),
                Arc::new(ThoughtAST::new(ThoughtASTKind::Linear { value: 1.5, scale: 1.0 })),
            )),
        ];
        let unrelated = ThoughtAST::new(ThoughtASTKind::Bind(
            Arc::new(ThoughtAST::new(ThoughtASTKind::Atom("hour".into()))),
            Arc::new(ThoughtAST::new(ThoughtASTKind::Linear { value: 12.0, scale: 24.0 })),
        ));
        let unrelated_vec = env.encode(&unrelated);
        let prebuilt = prebuild(&mut env, &forms);
        let results = extract(&unrelated_vec, &forms, |ast| prebuilt[ast].clone());
        assert_eq!(results.len(), 2);
    }

    #[test]
    fn test_extract_flat_bind_form() {
        let mut env = TestEncodeEnv::new(DIMS);
        let bind = ThoughtAST::new(ThoughtASTKind::Bind(
            Arc::new(ThoughtAST::new(ThoughtASTKind::Atom("rsi".into()))),
            Arc::new(ThoughtAST::new(ThoughtASTKind::Atom("vol".into()))),
        ));
        let bind_vec = env.encode(&bind);
        let prebuilt = prebuild(&mut env, &[bind.clone()]);
        let results = extract(&bind_vec, &[bind.clone()], |ast| prebuilt[ast].clone());
        assert_eq!(results.len(), 1);
        assert!(matches!(results[0].0.kind, ThoughtASTKind::Bind(_, _)));
        assert!(results[0].1 > 0.9);
    }

    #[test]
    fn test_collect_facts_atom_skipped() {
        let ast = ThoughtAST::new(ThoughtASTKind::Atom("rsi".into()));
        let facts = collect_facts(&ast);
        assert_eq!(facts.len(), 0); // bare atom is not a fact
    }

    #[test]
    fn test_collect_facts_bundle() {
        let ast = ThoughtAST::new(ThoughtASTKind::Bundle(vec![
            ThoughtAST::new(ThoughtASTKind::Bind(
                Arc::new(ThoughtAST::new(ThoughtASTKind::Atom("rsi".into()))),
                Arc::new(ThoughtAST::new(ThoughtASTKind::Linear { value: 0.7, scale: 1.0 })),
            )),
            ThoughtAST::new(ThoughtASTKind::Bind(
                Arc::new(ThoughtAST::new(ThoughtASTKind::Atom("vol".into()))),
                Arc::new(ThoughtAST::new(ThoughtASTKind::Log { value: 2.0 })),
            )),
            ThoughtAST::new(ThoughtASTKind::Atom("trend".into())), // skipped
        ]));
        let facts = collect_facts(&ast);
        assert_eq!(facts.len(), 2); // named scalars (Bind nodes), not bare Atom
    }

    #[test]
    fn test_collect_facts_nested_bundles() {
        let ast = ThoughtAST::new(ThoughtASTKind::Bundle(vec![
            ThoughtAST::new(ThoughtASTKind::Bundle(vec![
                ThoughtAST::new(ThoughtASTKind::Bind(
                Arc::new(ThoughtAST::new(ThoughtASTKind::Atom("rsi".into()))),
                Arc::new(ThoughtAST::new(ThoughtASTKind::Linear { value: 0.7, scale: 1.0 })),
            )),
                ThoughtAST::new(ThoughtASTKind::Bind(
                Arc::new(ThoughtAST::new(ThoughtASTKind::Atom("vol".into()))),
                Arc::new(ThoughtAST::new(ThoughtASTKind::Linear { value: 1.5, scale: 1.0 })),
            )),
            ])),
            ThoughtAST::new(ThoughtASTKind::Bind(
            Arc::new(ThoughtAST::new(ThoughtASTKind::Atom("trend".into()))),
            Arc::new(ThoughtAST::new(ThoughtASTKind::Log { value: 0.03 })),
        )),
        ]));
        let facts = collect_facts(&ast);
        assert_eq!(facts.len(), 3);
        for fact in &facts {
            assert!(!matches!(fact.kind, ThoughtASTKind::Bundle(_)));
            assert!(!matches!(fact.kind, ThoughtASTKind::Atom(_)));
        }
    }

    #[test]
    fn test_collect_facts_bind_is_fact() {
        let bind = ThoughtAST::new(ThoughtASTKind::Bind(
            Arc::new(ThoughtAST::new(ThoughtASTKind::Atom("a".into()))),
            Arc::new(ThoughtAST::new(ThoughtASTKind::Atom("b".into()))),
        ));
        let ast = ThoughtAST::new(ThoughtASTKind::Bundle(vec![bind.clone(), ThoughtAST::new(ThoughtASTKind::Atom("c".into()))]));
        let facts = collect_facts(&ast);
        assert_eq!(facts.len(), 1); // Bind is a fact, Atom is not
        assert!(matches!(&facts[0].kind, ThoughtASTKind::Bind(_, _)));
    }
}
