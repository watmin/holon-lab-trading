/// thought_encoder.rs — the AST that vocabulary modules produce,
/// and the evaluator that walks it into vectors. Compiled from wat/thought-encoder.wat.
///
/// Two kinds of memory:
///   Atoms: a dictionary. Finite. Known at startup. Pre-computed. Never evicted.
///   Compositions: a cache. Optimistic. Use if we have it. Compute if we don't.
///
/// The encode function NEVER writes to the cache — misses are returned as
/// values. The enterprise collects them and inserts between candles.

use std::collections::HashMap;

use holon::kernel::primitives::Primitives;
use holon::kernel::scalar::{ScalarEncoder, ScalarMode};
use holon::kernel::similarity::Similarity;
use holon::kernel::vector::Vector;
use holon::kernel::vector_manager::VectorManager;

#[derive(Clone, Debug, PartialEq)]
pub enum ThoughtAST {
    Atom(String),
    Linear { name: String, value: f64, scale: f64 },
    Log { name: String, value: f64 },
    Circular { name: String, value: f64, period: f64 },
    Bind(Box<ThoughtAST>, Box<ThoughtAST>),
    Bundle(Vec<ThoughtAST>),
}

impl ThoughtAST {
    /// Convenience constructors.
    pub fn linear(name: impl Into<String>, value: f64, scale: f64) -> Self {
        ThoughtAST::Linear { name: name.into(), value, scale }
    }

    pub fn log(name: impl Into<String>, value: f64) -> Self {
        ThoughtAST::Log { name: name.into(), value }
    }

    pub fn circular(name: impl Into<String>, value: f64, period: f64) -> Self {
        ThoughtAST::Circular { name: name.into(), value, period }
    }

    /// Extract the human-readable name of this AST node.
    /// Atoms, Linear, Log, Circular have explicit names.
    /// Bind returns "bind(<left>:<right>)".
    /// Bundle returns "bundle(<n>)" where n is the child count.
    pub fn name(&self) -> String {
        match self {
            ThoughtAST::Atom(name) => name.clone(),
            ThoughtAST::Linear { name, .. } => name.clone(),
            ThoughtAST::Log { name, .. } => name.clone(),
            ThoughtAST::Circular { name, .. } => name.clone(),
            ThoughtAST::Bind(left, right) => format!("bind({}:{})", left.name(), right.name()),
            ThoughtAST::Bundle(children) => format!("bundle({})", children.len()),
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
            ThoughtAST::Linear { name, value, scale } => {
                name.hash(state);
                value.to_bits().hash(state);
                scale.to_bits().hash(state);
            }
            ThoughtAST::Log { name, value } => {
                name.hash(state);
                value.to_bits().hash(state);
            }
            ThoughtAST::Circular { name, value, period } => {
                name.hash(state);
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
        }
    }
}

/// Trait for typed vocabulary structs. Each vocabulary defines a struct
/// whose fields ARE the facts. The struct knows how to produce its AST
/// and its list of queryable forms.
pub trait ToAst {
    /// Produce the ThoughtAST for encoding this vocabulary's facts.
    fn to_ast(&self) -> ThoughtAST;

    /// Produce the list of leaf forms this vocabulary can generate.
    /// Used by extract() — the consumer queries these forms against an anomaly.
    fn forms(&self) -> Vec<ThoughtAST>;
}

/// Round a value to N decimal places. Used by vocabulary modules
/// at emission time — the ThoughtAST carries the rounded value.
/// The cache key IS the exact AST. The rounding happens at emission.
pub fn round_to(v: f64, digits: u32) -> f64 {
    let factor = 10f64.powi(digits as i32);
    (v * factor).round() / factor
}

/// The evaluator. Walks ThoughtAST bottom-up, checking cache at every node.
pub struct ThoughtEncoder {
    /// Finite, pre-computed atom vectors. Never evicted.
    atoms: HashMap<String, Vector>,
    /// Optimistic composition cache. Use if we have it. Compute if we don't.
    compositions: HashMap<ThoughtAST, Vector>,
    /// Scalar encoder for Linear/Log/Circular nodes.
    scalar_encoder: ScalarEncoder,
    /// VectorManager for atom allocation.
    vm: VectorManager,
}

impl ThoughtEncoder {
    /// Construct a new ThoughtEncoder. Atoms dictionary starts empty --
    /// call `register_atom` to pre-allocate known atom names.
    pub fn new(vm: VectorManager) -> Self {
        let dims = vm.dimensions();
        Self {
            atoms: HashMap::new(),
            compositions: HashMap::with_capacity(4096),
            scalar_encoder: ScalarEncoder::new(dims),
            vm,
        }
    }

    /// Pre-allocate an atom vector. Idempotent.
    /// (Test-only — production uses get_atom's lazy fallback.)
    #[cfg(test)]
    pub fn register_atom(&mut self, name: &str) {
        if !self.atoms.contains_key(name) {
            let v = self.vm.get_vector(name);
            self.atoms.insert(name.to_string(), v);
        }
    }

    /// Look up (or lazily allocate) an atom vector.
    fn get_atom(&self, name: &str) -> Vector {
        if let Some(v) = self.atoms.get(name) {
            v.clone()
        } else {
            // Fallback: compute on the fly (not cached in atoms --
            // atoms are pre-registered). Still deterministic.
            self.vm.get_vector(name)
        }
    }

    /// Recursive, cache-aware encode. Returns the vector AND any cache misses.
    /// On cache hit: returns the vector and empty misses.
    /// On cache miss: computes, returns vector AND the (ast, vector) pair in misses.
    /// The caller collects all misses and inserts between candles.
    pub fn encode(&self, ast: &ThoughtAST) -> (Vector, Vec<(ThoughtAST, Vector)>) {
        // Check composition cache first
        if let Some(cached) = self.compositions.get(ast) {
            return (cached.clone(), Vec::new());
        }

        // Cache miss -- evaluate the AST node
        let (result, mut misses) = match ast {
            ThoughtAST::Atom(name) => {
                let v = self.get_atom(name);
                (v, Vec::new())
            }
            ThoughtAST::Linear { name, value, scale } => {
                let (atom_vec, atom_misses) = self.encode(&ThoughtAST::Atom(name.clone()));
                let scalar_vec = self.scalar_encoder.encode(
                    *value,
                    ScalarMode::Linear { scale: *scale },
                );
                (Primitives::bind(&atom_vec, &scalar_vec), atom_misses)
            }
            ThoughtAST::Log { name, value } => {
                let (atom_vec, atom_misses) = self.encode(&ThoughtAST::Atom(name.clone()));
                let scalar_vec = self.scalar_encoder.encode_log(*value);
                (Primitives::bind(&atom_vec, &scalar_vec), atom_misses)
            }
            ThoughtAST::Circular { name, value, period } => {
                let (atom_vec, atom_misses) = self.encode(&ThoughtAST::Atom(name.clone()));
                let scalar_vec = self.scalar_encoder.encode(
                    *value,
                    ScalarMode::Circular { period: *period },
                );
                (Primitives::bind(&atom_vec, &scalar_vec), atom_misses)
            }
            ThoughtAST::Bind(left, right) => {
                let (l_vec, l_misses) = self.encode(left);
                let (r_vec, r_misses) = self.encode(right);
                let mut combined = l_misses;
                combined.extend(r_misses);
                (Primitives::bind(&l_vec, &r_vec), combined)
            }
            ThoughtAST::Bundle(children) => {
                let mut all_vecs = Vec::with_capacity(children.len());
                let mut all_misses = Vec::new();
                for child in children {
                    let (v, m) = self.encode(child);
                    all_vecs.push(v);
                    all_misses.extend(m);
                }
                let refs: Vec<&Vector> = all_vecs.iter().collect();
                if refs.is_empty() {
                    (Vector::zeros(self.vm.dimensions()), all_misses)
                } else {
                    (Primitives::bundle(&refs), all_misses)
                }
            }
        };

        // Record this miss for later insertion
        misses.push((ast.clone(), result.clone()));
        (result, misses)
    }

    /// Insert cache entries (called between candles by ctx).
    pub fn insert_cache_entries(&mut self, misses: Vec<(ThoughtAST, Vector)>) {
        for (ast, vec) in misses {
            self.compositions.insert(ast, vec);
        }
    }

    /// Access the VectorManager.
    pub fn vm(&self) -> &VectorManager {
        &self.vm
    }

    /// Access the ScalarEncoder.
    pub fn scalar_encoder(&self) -> &ScalarEncoder {
        &self.scalar_encoder
    }

    /// Number of cached compositions.
    pub fn cache_size(&self) -> usize {
        self.compositions.len()
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

    /// Encode facts incrementally. Returns (thought_vector, cache_misses).
    ///
    /// First candle: full encode, populate sums and last_facts.
    /// Subsequent candles: diff against last_facts, patch sums, threshold.
    ///
    /// Uses the ThoughtEncoder to evaluate individual changed facts (benefiting
    /// from the composition cache). The sums buffer avoids re-summing unchanged facts.
    pub fn encode(
        &mut self,
        new_facts: &[ThoughtAST],
        encoder: &ThoughtEncoder,
    ) -> (Vector, Vec<(ThoughtAST, Vector)>) {
        if !self.initialized {
            return self.full_encode(new_facts, encoder);
        }

        let mut all_misses = Vec::new();
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
                let (new_vec, misses) = encoder.encode(fact);
                all_misses.extend(misses);
                // Add new contribution
                for (s, &val) in self.sums.iter_mut().zip(new_vec.data()) {
                    *s += val as i32;
                }
                new_last_facts.insert(fact.clone(), new_vec);
            }
        }

        // Subtract old facts that were matched (they're still in sums from before)
        // — no, they stay. Only removed facts were subtracted above. This is correct.

        self.last_facts = new_last_facts;

        // Threshold the sums
        let thought = self.threshold();
        (thought, all_misses)
    }

    /// First candle: full encode from scratch.
    fn full_encode(
        &mut self,
        facts: &[ThoughtAST],
        encoder: &ThoughtEncoder,
    ) -> (Vector, Vec<(ThoughtAST, Vector)>) {
        self.sums.iter_mut().for_each(|s| *s = 0);
        self.last_facts.clear();

        let mut all_misses = Vec::new();
        for fact in facts {
            let (vec, misses) = encoder.encode(fact);
            all_misses.extend(misses);
            for (s, &val) in self.sums.iter_mut().zip(vec.data()) {
                *s += val as i32;
            }
            self.last_facts.insert(fact.clone(), vec);
        }

        self.initialized = true;
        let thought = self.threshold();
        (thought, all_misses)
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
/// Returns Vec<(ThoughtAST, f64)> — each form and its cosine presence.
pub fn extract(thought_vec: &Vector, forms: &[ThoughtAST], encoder: &ThoughtEncoder) -> Vec<(ThoughtAST, f64)> {
    forms.iter().map(|form| {
        let (form_vec, _) = encoder.encode(form);
        let presence = Similarity::cosine(&form_vec, thought_vec);
        (form.clone(), presence)
    }).collect()
}

/// Recursively collect all non-Bundle leaf nodes from an AST tree.
/// Bundle nodes are expanded; all other nodes (Atom, Linear, Log, Circular, Bind)
/// are returned as-is.
pub fn flatten_leaves(ast: &ThoughtAST) -> Vec<ThoughtAST> {
    match ast {
        ThoughtAST::Bundle(children) => {
            children.iter().flat_map(flatten_leaves).collect()
        }
        _ => vec![ast.clone()],
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const DIMS: usize = 4096;

    fn make_encoder() -> ThoughtEncoder {
        let vm = VectorManager::new(DIMS);
        let mut enc = ThoughtEncoder::new(vm);
        enc.register_atom("rsi");
        enc.register_atom("vol");
        enc.register_atom("hour");
        enc.register_atom("trend");
        enc
    }

    #[test]
    fn test_thought_ast_variants() {
        let a = ThoughtAST::Atom("rsi".into());
        let l = ThoughtAST::linear("rsi", 0.5, 1.0);
        let g = ThoughtAST::log("vol", 2.0);
        let c = ThoughtAST::circular("hour", 14.0, 24.0);
        let b = ThoughtAST::Bind(Box::new(a.clone()), Box::new(l.clone()));
        let u = ThoughtAST::Bundle(vec![a, l, g, c]);
        assert!(matches!(b, ThoughtAST::Bind(_, _)));
        assert!(matches!(u, ThoughtAST::Bundle(_)));
    }

    #[test]
    fn test_encode_atom_returns_vector() {
        let enc = make_encoder();
        let (v, misses) = enc.encode(&ThoughtAST::Atom("rsi".into()));
        assert_eq!(v.dimensions(), DIMS);
        assert!(v.nnz() > 0);
        // Atom produces one miss (itself)
        assert!(!misses.is_empty());
    }

    #[test]
    fn test_encode_atom_deterministic() {
        let enc = make_encoder();
        let (v1, _) = enc.encode(&ThoughtAST::Atom("rsi".into()));
        let (v2, _) = enc.encode(&ThoughtAST::Atom("rsi".into()));
        assert_eq!(v1, v2);
    }

    #[test]
    fn test_encode_log_produces_bound_vector() {
        let enc = make_encoder();
        let ast = ThoughtAST::log("vol", 100.0);
        let (v, misses) = enc.encode(&ast);
        assert_eq!(v.dimensions(), DIMS);
        assert!(v.nnz() > 0);
        assert!(!misses.is_empty());
    }

    #[test]
    fn test_encode_bundle() {
        let enc = make_encoder();
        let ast = ThoughtAST::Bundle(vec![
            ThoughtAST::Atom("rsi".into()),
            ThoughtAST::Atom("vol".into()),
        ]);
        let (v, _) = enc.encode(&ast);
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
        let (v, _) = enc.encode(&ast);
        assert_eq!(v.dimensions(), DIMS);
        assert!(v.nnz() > 0);
    }

    #[test]
    fn test_cache_hit_returns_empty_misses() {
        let mut enc = make_encoder();
        let ast = ThoughtAST::log("vol", 50.0);

        let (v1, misses1) = enc.encode(&ast);
        assert!(!misses1.is_empty());

        // Insert misses into cache
        enc.insert_cache_entries(misses1);

        // Second encode should be a cache hit
        let (v2, misses2) = enc.encode(&ast);
        assert!(misses2.is_empty());
        assert_eq!(v1, v2);
    }

    #[test]
    fn test_encode_never_writes_cache() {
        let enc = make_encoder();
        let ast = ThoughtAST::log("vol", 50.0);
        let _ = enc.encode(&ast);
        // Cache should still be empty -- encode never writes
        assert_eq!(enc.cache_size(), 0);
    }

    #[test]
    fn test_insert_cache_entries() {
        let mut enc = make_encoder();
        let ast = ThoughtAST::Atom("rsi".into());
        let (_, misses) = enc.encode(&ast);
        let miss_count = misses.len();
        enc.insert_cache_entries(misses);
        assert_eq!(enc.cache_size(), miss_count);
    }

    #[test]
    fn test_register_atom_idempotent() {
        let mut enc = make_encoder();
        enc.register_atom("rsi"); // already registered
        enc.register_atom("rsi"); // no-op
        // Should still work
        let (v, _) = enc.encode(&ThoughtAST::Atom("rsi".into()));
        assert!(v.nnz() > 0);
    }

    #[test]
    fn test_thought_ast_name() {
        assert_eq!(ThoughtAST::Atom("rsi".into()).name(), "rsi");
        assert_eq!(ThoughtAST::linear("vol", 1.0, 1.0).name(), "vol");
        assert_eq!(ThoughtAST::log("atr", 2.0).name(), "atr");
        assert_eq!(ThoughtAST::circular("hour", 14.0, 24.0).name(), "hour");
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
        let leaf = ThoughtAST::linear("rsi", 0.7, 1.0);
        // Encode the leaf to get a vector, use it as the thought
        let (leaf_vec, _) = enc.encode(&leaf);
        let results = extract(&leaf_vec, &[leaf.clone()], &enc);
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].0, leaf);
        // Self-cosine should be high (close to 1.0)
        assert!(results[0].1 > 0.9, "self-cosine should be high, got {}", results[0].1);
    }

    #[test]
    fn test_extract_flat_multiple_forms() {
        let enc = make_encoder();
        let forms = vec![
            ThoughtAST::linear("rsi", 0.7, 1.0),
            ThoughtAST::linear("vol", 1.5, 1.0),
            ThoughtAST::linear("trend", 0.3, 1.0),
        ];
        // Bundle all forms, then extract — each form should have non-trivial presence
        let bundle = ThoughtAST::Bundle(forms.clone());
        let (thought_vec, _) = enc.encode(&bundle);
        let results = extract(&thought_vec, &forms, &enc);
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
            ThoughtAST::linear("rsi", 0.7, 1.0),
        ];
        // Use an unrelated vector
        let unrelated = ThoughtAST::linear("hour", 12.0, 24.0);
        let (unrelated_vec, _) = enc.encode(&unrelated);
        let results = extract(&unrelated_vec, &forms, &enc);
        assert_eq!(results.len(), 1);
        // Cosine between unrelated vectors should be near zero
        assert!(results[0].1.abs() < 0.2, "unrelated cosine should be near zero, got {}", results[0].1);
    }

    #[test]
    fn test_extract_flat_no_threshold() {
        let enc = make_encoder();
        // Extract always returns ALL forms, no filtering
        let forms = vec![
            ThoughtAST::linear("rsi", 0.7, 1.0),
            ThoughtAST::linear("vol", 1.5, 1.0),
        ];
        let unrelated = ThoughtAST::linear("hour", 12.0, 24.0);
        let (unrelated_vec, _) = enc.encode(&unrelated);
        let results = extract(&unrelated_vec, &forms, &enc);
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
        let (bind_vec, _) = enc.encode(&bind);
        let results = extract(&bind_vec, &[bind.clone()], &enc);
        assert_eq!(results.len(), 1);
        assert!(matches!(results[0].0, ThoughtAST::Bind(_, _)));
        assert!(results[0].1 > 0.9);
    }

    #[test]
    fn test_flatten_leaves_atom() {
        let ast = ThoughtAST::Atom("rsi".into());
        let leaves = flatten_leaves(&ast);
        assert_eq!(leaves.len(), 1);
        assert_eq!(leaves[0], ast);
    }

    #[test]
    fn test_flatten_leaves_bundle() {
        let ast = ThoughtAST::Bundle(vec![
            ThoughtAST::linear("rsi", 0.7, 1.0),
            ThoughtAST::log("vol", 2.0),
            ThoughtAST::Atom("trend".into()),
        ]);
        let leaves = flatten_leaves(&ast);
        assert_eq!(leaves.len(), 3);
        assert!(!leaves.iter().any(|l| matches!(l, ThoughtAST::Bundle(_))));
    }

    #[test]
    fn test_flatten_leaves_nested_bundles() {
        let ast = ThoughtAST::Bundle(vec![
            ThoughtAST::Bundle(vec![
                ThoughtAST::linear("rsi", 0.7, 1.0),
                ThoughtAST::linear("vol", 1.5, 1.0),
            ]),
            ThoughtAST::log("trend", 0.03),
        ]);
        let leaves = flatten_leaves(&ast);
        assert_eq!(leaves.len(), 3);
        // All leaves, no bundles
        for leaf in &leaves {
            assert!(!matches!(leaf, ThoughtAST::Bundle(_)));
        }
    }

    #[test]
    fn test_flatten_leaves_bind_is_leaf() {
        let bind = ThoughtAST::Bind(
            Box::new(ThoughtAST::Atom("a".into())),
            Box::new(ThoughtAST::Atom("b".into())),
        );
        let ast = ThoughtAST::Bundle(vec![bind.clone(), ThoughtAST::Atom("c".into())]);
        let leaves = flatten_leaves(&ast);
        assert_eq!(leaves.len(), 2);
        assert!(matches!(&leaves[0], ThoughtAST::Bind(_, _)));
    }
}
