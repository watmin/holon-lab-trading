/// ThoughtEncoder — evaluates ThoughtAST into vectors.
/// Atoms dict + LRU cache. encode returns (Vector, Vec<(ThoughtAST, Vector)>).

use std::collections::HashMap;

use holon::kernel::primitives::Primitives;
use holon::kernel::scalar::{ScalarEncoder, ScalarMode};
use holon::kernel::vector::Vector;
use holon::kernel::vector_manager::VectorManager;

use crate::enums::ThoughtAST;

/// Evaluates ThoughtASTs into vectors.
pub struct ThoughtEncoder {
    /// Finite, pre-computed, permanent atom vectors.
    atoms: HashMap<String, Vector>,
    /// Optimistic, self-evicting composition cache.
    compositions: HashMap<ThoughtAST, Vector>,
    /// Scalar encoder for linear/log/circular values.
    scalar_encoder: ScalarEncoder,
}

/// The known atom vocabulary.
const ATOM_NAMES: &[&str] = &[
    "rsi", "williams-r", "cci-magnitude", "cci-direction", "cci",
    "mfi", "roc-1", "roc-3", "roc-6", "roc-12",
    "obv-slope", "volume-accel", "vwap-distance",
    "hurst", "autocorrelation", "adx",
    "kama-er", "choppiness", "dfa-alpha", "variance-ratio",
    "entropy-rate", "aroon-up", "aroon-down", "fractal-dim",
    "rsi-divergence-bull", "rsi-divergence-bear",
    "cloud-position", "cloud-thickness", "tk-cross-delta", "tk-spread",
    "stoch-k", "stoch-d", "stoch-kd-spread", "stoch-cross-delta",
    "range-pos-12", "range-pos-24", "range-pos-48",
    "fib-distance-12", "fib-distance-24", "fib-distance-48",
    "kelt-pos", "bb-pos", "squeeze", "bb-breakout-upper", "bb-breakout-lower",
    "bb-width",
    "close-sma20", "close-sma50", "close-sma200",
    "sma20-sma50", "sma50-sma200",
    "macd", "macd-signal", "macd-hist",
    "di-spread",
    "range-ratio", "gap", "consecutive-up", "consecutive-down",
    "tf-1h-ret", "tf-1h-body", "tf-1h-range-pos",
    "tf-4h-ret", "tf-4h-body", "tf-4h-range-pos",
    "tf-agreement",
    "minute", "hour", "day-of-week", "day-of-month", "month-of-year",
    // Exit vocab atoms
    "atr-ratio", "atr-roc-6", "atr-roc-12",
    "trend-consistency-6", "trend-consistency-12", "trend-consistency-24",
    "divergence",
    "close-delta", "rsi-delta",
    "macd-hist-change", "now", "3-ago",
    // Edge atom
    "market-edge",
];

impl ThoughtEncoder {
    /// Create a new ThoughtEncoder from a VectorManager.
    /// Pre-computes all atom vectors from the known vocabulary.
    pub fn new(vm: &VectorManager) -> Self {
        let dims = vm.dimensions();
        let mut atoms = HashMap::new();
        for &name in ATOM_NAMES {
            atoms.insert(name.to_string(), vm.get_vector(name));
        }
        Self {
            atoms,
            compositions: HashMap::new(),
            scalar_encoder: ScalarEncoder::new(dims),
        }
    }

    /// Look up an atom vector by name.
    fn lookup_atom(&self, name: &str) -> Vector {
        self.atoms
            .get(name)
            .cloned()
            .unwrap_or_else(|| panic!("Unknown atom: {}", name))
    }

    /// Encode a ThoughtAST into a vector.
    /// Returns (result_vector, cache_misses) where cache_misses are
    /// (ast, vector) pairs that were computed but not yet in the cache.
    /// The encode function NEVER writes to the cache. Values up.
    pub fn encode(&self, ast: &ThoughtAST) -> (Vector, Vec<(ThoughtAST, Vector)>) {
        // Check cache first
        if let Some(cached) = self.compositions.get(ast) {
            return (cached.clone(), Vec::<(ThoughtAST, Vector)>::new());
        }

        // Cache miss — compute
        let (result, mut misses) = match ast {
            ThoughtAST::Atom(name) => {
                (self.lookup_atom(name), vec![])
            }

            ThoughtAST::Linear { name, value, scale } => {
                let (atom_vec, atom_misses) = self.encode(&ThoughtAST::Atom(name.clone()));
                let scalar_vec = self.scalar_encoder.encode(*value, ScalarMode::Linear { scale: *scale });
                (Primitives::bind(&atom_vec, &scalar_vec), atom_misses)
            }

            ThoughtAST::Log { name, value } => {
                let (atom_vec, atom_misses) = self.encode(&ThoughtAST::Atom(name.clone()));
                let scalar_vec = self.scalar_encoder.encode_log(*value);
                (Primitives::bind(&atom_vec, &scalar_vec), atom_misses)
            }

            ThoughtAST::Circular { name, value, period } => {
                let (atom_vec, atom_misses) = self.encode(&ThoughtAST::Atom(name.clone()));
                let scalar_vec = self.scalar_encoder.encode(*value, ScalarMode::Circular { period: *period });
                (Primitives::bind(&atom_vec, &scalar_vec), atom_misses)
            }

            ThoughtAST::Bind(left, right) => {
                let (l_vec, l_misses) = self.encode(left);
                let (r_vec, r_misses) = self.encode(right);
                let mut all_misses = l_misses;
                all_misses.extend(r_misses);
                (Primitives::bind(&l_vec, &r_vec), all_misses)
            }

            ThoughtAST::Bundle(children) => {
                let mut vecs = Vec::new();
                let mut all_misses = Vec::new();
                for child in children {
                    let (v, m) = self.encode(child);
                    vecs.push(v);
                    all_misses.extend(m);
                }
                let refs: Vec<&Vector> = vecs.iter().collect();
                (Primitives::bundle(&refs), all_misses)
            }
        };

        // Record this computation as a miss
        misses.push((ast.clone(), result.clone()));
        (result, misses)
    }

    /// Insert cache misses into the compositions cache.
    /// Called between candles — the one seam.
    pub fn insert_cache_misses(&mut self, misses: Vec<(ThoughtAST, Vector)>) {
        for (ast, vec) in misses {
            self.compositions.insert(ast, vec);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_encode_atom_non_zero() {
        let vm = VectorManager::new(4096);
        let encoder = ThoughtEncoder::new(&vm);
        let ast = ThoughtAST::Atom("rsi".into());
        let (vec, misses) = encoder.encode(&ast);
        assert!(vec.nnz() > 0);
        assert!(!misses.is_empty());
    }

    #[test]
    fn test_encode_linear_non_zero() {
        let vm = VectorManager::new(4096);
        let encoder = ThoughtEncoder::new(&vm);
        let ast = ThoughtAST::Linear { name: "rsi".into(), value: 0.55, scale: 1.0 };
        let (vec, misses) = encoder.encode(&ast);
        assert!(vec.nnz() > 0);
        assert!(!misses.is_empty());
    }

    #[test]
    fn test_encode_log_non_zero() {
        let vm = VectorManager::new(4096);
        let encoder = ThoughtEncoder::new(&vm);
        let ast = ThoughtAST::Log { name: "volume-accel".into(), value: 1.5 };
        let (vec, _misses) = encoder.encode(&ast);
        assert!(vec.nnz() > 0);
    }

    #[test]
    fn test_encode_circular_non_zero() {
        let vm = VectorManager::new(4096);
        let encoder = ThoughtEncoder::new(&vm);
        let ast = ThoughtAST::Circular { name: "hour".into(), value: 14.0, period: 24.0 };
        let (vec, _misses) = encoder.encode(&ast);
        assert!(vec.nnz() > 0);
    }

    #[test]
    fn test_encode_bundle_non_zero() {
        let vm = VectorManager::new(4096);
        let encoder = ThoughtEncoder::new(&vm);
        let ast = ThoughtAST::Bundle(vec![
            ThoughtAST::Atom("rsi".into()),
            ThoughtAST::Atom("mfi".into()),
        ]);
        let (vec, _misses) = encoder.encode(&ast);
        assert!(vec.nnz() > 0);
    }

    #[test]
    fn test_cache_hit() {
        let vm = VectorManager::new(4096);
        let mut encoder = ThoughtEncoder::new(&vm);
        let ast = ThoughtAST::Linear { name: "rsi".into(), value: 0.55, scale: 1.0 };

        let (vec1, misses) = encoder.encode(&ast);
        encoder.insert_cache_misses(misses);

        let (vec2, misses2) = encoder.encode(&ast);
        // Cache hit — no new misses for this exact AST
        assert_eq!(vec1, vec2);
        assert!(misses2.is_empty());
    }
}
