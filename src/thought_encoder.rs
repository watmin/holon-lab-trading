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
}
