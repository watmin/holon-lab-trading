/// encode.rs — the ONE way to turn a thought into geometry.
///
/// Progressive descent: the caller walks the AST level by level,
/// asking the cache "which of these do you have?" at each level.
/// Branches that hit stop. Branches that miss expand into their
/// children for the next round. When all branches are resolved
/// (hit or leaf), the caller computes misses locally and ships
/// results back via batch_set.
///
/// The cache is a hashmap behind pipes. It never sees the tree.
/// The caller owns the structure. The driver does hash lookups.

use std::cell::RefCell;
use std::collections::HashMap;

use holon::kernel::primitives::Primitives;
use holon::kernel::scalar::{ScalarEncoder, ScalarMode};
use holon::kernel::vector::Vector;
use holon::kernel::vector_manager::VectorManager;

use crate::encoding::thought_encoder::ThoughtAST;
use crate::programs::stdlib::cache::CacheHandle;

/// Accumulated timing from one encode() call tree.
/// Thread-local — each observer accumulates its own.
#[derive(Clone, Debug, Default)]
pub struct EncodeMetrics {
    pub nodes_walked: u64,
    pub cache_hits: u64,
    pub cache_misses: u64,
    pub ns_batch_get: u64,
    pub ns_leaf: u64,
    pub ns_cache_set: u64,
    pub batch_rounds: u64,
}

thread_local! {
    static METRICS: RefCell<EncodeMetrics> = RefCell::new(EncodeMetrics::default());
}

/// Reset and return the accumulated metrics. Call after encode() completes.
pub fn take_encode_metrics() -> EncodeMetrics {
    METRICS.with(|m| {
        let metrics = m.borrow().clone();
        *m.borrow_mut() = EncodeMetrics::default();
        metrics
    })
}

/// Encode a ThoughtAST into a Vector.
///
/// Progressive descent: walk the AST level by level, batch_get each
/// frontier. Hits go into the local map and stop expanding. Misses
/// expand into their children for the next round. When all branches
/// are resolved (hit or leaf), compute misses bottom-up locally.
/// Ship computed results back via batch_set.
///
/// The caller owns the tree walk. The cache does hash lookups.
pub fn encode(
    cache: &CacheHandle<ThoughtAST, Vector>,
    ast: &ThoughtAST,
    vm: &VectorManager,
    scalar: &ScalarEncoder,
) -> Vector {
    // Phase 1: progressive descent.
    let mut local: HashMap<ThoughtAST, Vector> = HashMap::new();
    let mut frontier: Vec<ThoughtAST> = vec![ast.clone()];

    while !frontier.is_empty() {
        let t0 = std::time::Instant::now();
        let results = cache.batch_get(frontier.clone()).unwrap_or_default();
        METRICS.with(|m| {
            let mut m = m.borrow_mut();
            m.ns_batch_get += t0.elapsed().as_nanos() as u64;
            m.batch_rounds += 1;
        });

        let mut next_frontier: Vec<ThoughtAST> = Vec::new();
        for (node, result) in frontier.into_iter().zip(results) {
            if let Some(v) = result {
                METRICS.with(|m| m.borrow_mut().cache_hits += 1);
                local.insert(node, v);
            } else {
                METRICS.with(|m| m.borrow_mut().cache_misses += 1);
                // Miss — expand non-leaf children into next frontier.
                // Leaves are never cached, so don't query them.
                for child in node.children() {
                    match &child {
                        ThoughtAST::Atom(_)
                        | ThoughtAST::Linear { .. }
                        | ThoughtAST::Log { .. }
                        | ThoughtAST::Circular { .. }
                        | ThoughtAST::Thermometer { .. } => {}
                        _ => { next_frontier.push(child); }
                    }
                }
            }
        }
        frontier = next_frontier;
    }

    // Phase 2: compute misses locally — recursive, using local map.
    let mut computed: Vec<(ThoughtAST, Vector)> = Vec::new();
    let vec = encode_local(&local, ast, vm, scalar, &mut computed);

    // Phase 3: install computed results in cache — fire and forget.
    let t0 = std::time::Instant::now();
    cache.batch_set(computed);
    METRICS.with(|m| m.borrow_mut().ns_cache_set += t0.elapsed().as_nanos() as u64);

    vec
}

/// Recursive local encode. Uses the pre-resolved HashMap for hits.
/// Computes misses on this thread. Collects computed results for batch_set.
fn encode_local(
    local: &HashMap<ThoughtAST, Vector>,
    ast: &ThoughtAST,
    vm: &VectorManager,
    scalar: &ScalarEncoder,
    computed: &mut Vec<(ThoughtAST, Vector)>,
) -> Vector {
    METRICS.with(|m| m.borrow_mut().nodes_walked += 1);

    // Check local map first — resolved hits.
    if let Some(v) = local.get(ast) {
        return v.clone();
    }

    // Miss — compute locally.
    let vec = match ast {
        ThoughtAST::Atom(name) => {
            let t0 = std::time::Instant::now();
            let v = vm.get_vector(name);
            METRICS.with(|m| m.borrow_mut().ns_leaf += t0.elapsed().as_nanos() as u64);
            v
        }
        ThoughtAST::Linear { value, scale } => {
            let t0 = std::time::Instant::now();
            let v = scalar.encode(*value, ScalarMode::Linear { scale: *scale });
            METRICS.with(|m| m.borrow_mut().ns_leaf += t0.elapsed().as_nanos() as u64);
            v
        }
        ThoughtAST::Log { value } => {
            let t0 = std::time::Instant::now();
            let v = scalar.encode_log(*value);
            METRICS.with(|m| m.borrow_mut().ns_leaf += t0.elapsed().as_nanos() as u64);
            v
        }
        ThoughtAST::Circular { value, period } => {
            let t0 = std::time::Instant::now();
            let v = scalar.encode(*value, ScalarMode::Circular { period: *period });
            METRICS.with(|m| m.borrow_mut().ns_leaf += t0.elapsed().as_nanos() as u64);
            v
        }
        ThoughtAST::Thermometer { value, min, max } => {
            let t0 = std::time::Instant::now();
            let v = scalar.encode(*value, ScalarMode::Thermometer { min: *min, max: *max });
            METRICS.with(|m| m.borrow_mut().ns_leaf += t0.elapsed().as_nanos() as u64);
            v
        }
        ThoughtAST::Permute(child, shift) => {
            let v = encode_local(local, child, vm, scalar, computed);
            let t0 = std::time::Instant::now();
            let r = Primitives::permute(&v, *shift);
            METRICS.with(|m| m.borrow_mut().ns_leaf += t0.elapsed().as_nanos() as u64);
            r
        }
        ThoughtAST::Bind(left, right) => {
            let l = encode_local(local, left, vm, scalar, computed);
            let r = encode_local(local, right, vm, scalar, computed);
            let t0 = std::time::Instant::now();
            let v = Primitives::bind(&l, &r);
            METRICS.with(|m| m.borrow_mut().ns_leaf += t0.elapsed().as_nanos() as u64);
            v
        }
        ThoughtAST::Bundle(children) => {
            let vecs: Vec<Vector> = children.iter()
                .map(|c| encode_local(local, c, vm, scalar, computed))
                .collect();
            let t0 = std::time::Instant::now();
            let v = if vecs.is_empty() {
                Vector::zeros(vm.dimensions())
            } else {
                let refs: Vec<&Vector> = vecs.iter().collect();
                Primitives::bundle(&refs)
            };
            METRICS.with(|m| m.borrow_mut().ns_leaf += t0.elapsed().as_nanos() as u64);
            v
        }
        ThoughtAST::Sequential(items) => {
            let vecs: Vec<Vector> = items.iter().enumerate()
                .map(|(i, c)| {
                    let v = encode_local(local, c, vm, scalar, computed);
                    Primitives::permute(&v, i as i32)
                })
                .collect();
            let t0 = std::time::Instant::now();
            let v = if vecs.is_empty() {
                Vector::zeros(vm.dimensions())
            } else {
                let refs: Vec<&Vector> = vecs.iter().collect();
                Primitives::bundle(&refs)
            };
            METRICS.with(|m| m.borrow_mut().ns_leaf += t0.elapsed().as_nanos() as u64);
            v
        }
    };

    // Collect intermediary forms for batch_set. Skip leaves — they're
    // cheap to recompute (~100ns). Only cache compositions that required
    // children to be computed first (Bind, Permute, Bundle, Sequential).
    match ast {
        ThoughtAST::Atom(_)
        | ThoughtAST::Linear { .. }
        | ThoughtAST::Log { .. }
        | ThoughtAST::Circular { .. }
        | ThoughtAST::Thermometer { .. } => {}
        _ => { computed.push((ast.clone(), vec.clone())); }
    }

    vec
}
