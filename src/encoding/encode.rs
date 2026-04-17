/// encode.rs — the ONE way to turn a thought into geometry.
///
/// Two-tier cache: L1 (per-entity LruCache, no pipe) absorbs repeated
/// lookups across candles. L2 (shared cache program behind pipes) handles
/// cross-entity sharing. L1 is the memo. L2 is the sharing layer.
///
/// AST keys use precomputed hashes — computed once at ThoughtAST construction.
/// All cache lookups use u64 keys — integer hashing, nanoseconds, no tree walking.
///
/// The AST-as-value invariant is load-bearing: vocabulary modules embed
/// quantized scalar values in ThoughtAST nodes (round_to at emission,
/// Hash via to_bits). Changed values produce different hashes.
/// Stale entries are unreachable, not incorrect.

use std::cell::RefCell;
use std::num::NonZeroUsize;

use lru::LruCache;

use holon::kernel::primitives::Primitives;
use holon::kernel::scalar::{ScalarEncoder, ScalarMode};
use holon::kernel::vector::Vector;
use holon::kernel::vector_manager::VectorManager;

use crate::encoding::thought_encoder::{ThoughtAST, ThoughtASTKind};
use crate::programs::stdlib::cache::CacheHandle;

/// L1 vector cache capacity per entity.
const L1_CAPACITY: usize = 16384;

/// Per-entity encoding state. Created once at thread start.
/// Owns the L1 vector cache.
pub struct EncodeState {
    l1_cache: LruCache<u64, Vector>,
}

impl EncodeState {
    pub fn new() -> Self {
        Self {
            l1_cache: LruCache::new(NonZeroUsize::new(L1_CAPACITY).unwrap()),
        }
    }
}

/// Accumulated timing from one encode() call tree.
/// Thread-local — each observer accumulates its own.
#[derive(Clone, Debug, Default)]
pub struct EncodeMetrics {
    pub nodes_walked: u64,
    pub cache_hits: u64,
    pub cache_misses: u64,
    pub l1_hits: u64,
    pub l1_misses: u64,
    pub ns_batch_get: u64,
    pub ns_cache_set: u64,
    pub ns_compute: u64,
    pub batch_rounds: u64,
    pub forms_computed: u64,
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
/// Four phases:
/// 1. Walk the tree, collect L1 misses (by u64 key).
/// 2. Batch_get L2 for L1 misses. Populate L1 from L2 hits.
/// 3. Compute remaining misses sequentially with L1 memoization.
/// 4. Install computed results into L1 and confirmed batch_set to L2.
pub fn encode(
    state: &mut EncodeState,
    l2_cache: &CacheHandle<u64, Vector>,
    ast: &ThoughtAST,
    vm: &VectorManager,
    scalar: &ScalarEncoder,
) -> Vector {
    // Phase 1: walk the tree, collect L1 misses for L2 lookup.
    let mut l1_miss_keys: Vec<u64> = Vec::new();
    collect_l1_misses(ast, &mut state.l1_cache, &mut l1_miss_keys);

    // Phase 2: batch_get L2 for L1 misses. Populate L1 from L2 hits.
    if !l1_miss_keys.is_empty() {
        let t0 = std::time::Instant::now();
        let l2_results = l2_cache.batch_get(l1_miss_keys.clone()).unwrap_or_default();
        METRICS.with(|m| {
            let mut m = m.borrow_mut();
            m.ns_batch_get += t0.elapsed().as_nanos() as u64;
            m.batch_rounds += 1;
        });
        for (i, result) in l2_results.into_iter().enumerate() {
            if let Some(v) = result {
                METRICS.with(|m| m.borrow_mut().cache_hits += 1);
                state.l1_cache.put(l1_miss_keys[i], v);
            } else {
                METRICS.with(|m| m.borrow_mut().cache_misses += 1);
            }
        }
    }

    // Phase 3: compute remaining misses using L1 (now populated from L2).
    let t0 = std::time::Instant::now();
    let mut computed: Vec<(u64, Vector)> = Vec::new();
    let vec = encode_local(ast, &mut state.l1_cache, vm, scalar, &mut computed);
    METRICS.with(|m| {
        let mut m = m.borrow_mut();
        m.ns_compute += t0.elapsed().as_nanos() as u64;
        m.forms_computed += computed.len() as u64;
    });

    // Phase 4: install computed results into L1 and confirmed batch_set to L2.
    let t0 = std::time::Instant::now();
    for (k, v) in &computed {
        state.l1_cache.put(*k, v.clone());
    }
    METRICS.with(|m| m.borrow_mut().l1_hits = state.l1_cache.len() as u64);
    l2_cache.batch_set(computed);
    METRICS.with(|m| m.borrow_mut().ns_cache_set += t0.elapsed().as_nanos() as u64);

    vec
}

/// Walk the AST, collect non-leaf nodes that miss L1.
/// Stops expanding below L1 hits — their subtrees are resolved.
fn collect_l1_misses(
    ast: &ThoughtAST,
    l1_cache: &mut LruCache<u64, Vector>,
    miss_keys: &mut Vec<u64>,
) {
    // Skip leaves — never cached.
    match &ast.kind {
        ThoughtASTKind::Atom(_)
        | ThoughtASTKind::Linear { .. }
        | ThoughtASTKind::Log { .. }
        | ThoughtASTKind::Circular { .. }
        | ThoughtASTKind::Thermometer { .. } => return,
        _ => {}
    }

    let key = ast.precomputed_hash();

    if l1_cache.get(&key).is_some() {
        METRICS.with(|m| m.borrow_mut().l1_hits += 1);
        return;
    }
    METRICS.with(|m| m.borrow_mut().l1_misses += 1);

    miss_keys.push(key);
    for child in ast.children() {
        collect_l1_misses(&child, l1_cache, miss_keys);
    }
}

/// Recursive encode with L1 memoization via u64 keys.
fn encode_local(
    ast: &ThoughtAST,
    l1_cache: &mut LruCache<u64, Vector>,
    vm: &VectorManager,
    scalar: &ScalarEncoder,
    computed: &mut Vec<(u64, Vector)>,
) -> Vector {
    METRICS.with(|m| m.borrow_mut().nodes_walked += 1);

    // Check L1 for non-leaf nodes.
    match &ast.kind {
        ThoughtASTKind::Atom(_)
        | ThoughtASTKind::Linear { .. }
        | ThoughtASTKind::Log { .. }
        | ThoughtASTKind::Circular { .. }
        | ThoughtASTKind::Thermometer { .. } => {}
        _ => {
            let key = ast.precomputed_hash();
            if let Some(v) = l1_cache.get(&key) {
                return v.clone();
            }
        }
    }

    let vec = match &ast.kind {
        ThoughtASTKind::Atom(name) => vm.get_vector(name),
        ThoughtASTKind::Linear { value, scale } => {
            scalar.encode(*value, ScalarMode::Linear { scale: *scale })
        }
        ThoughtASTKind::Log { value } => scalar.encode_log(*value),
        ThoughtASTKind::Circular { value, period } => {
            scalar.encode(*value, ScalarMode::Circular { period: *period })
        }
        ThoughtASTKind::Thermometer { value, min, max } => {
            scalar.encode(*value, ScalarMode::Thermometer { min: *min, max: *max })
        }
        ThoughtASTKind::Permute(child, shift) => {
            let v = encode_local(child, l1_cache, vm, scalar, computed);
            Primitives::permute(&v, *shift)
        }
        ThoughtASTKind::Bind(left, right) => {
            let l = encode_local(left, l1_cache, vm, scalar, computed);
            let r = encode_local(right, l1_cache, vm, scalar, computed);
            Primitives::bind(&l, &r)
        }
        ThoughtASTKind::Bundle(children) => {
            let vecs: Vec<Vector> = children.iter()
                .map(|c| encode_local(c, l1_cache, vm, scalar, computed))
                .collect();
            if vecs.is_empty() {
                Vector::zeros(vm.dimensions())
            } else {
                let refs: Vec<&Vector> = vecs.iter().collect();
                Primitives::bundle(&refs)
            }
        }
        ThoughtASTKind::Sequential(items) => {
            let vecs: Vec<Vector> = items.iter().enumerate()
                .map(|(i, c)| {
                    let v = encode_local(c, l1_cache, vm, scalar, computed);
                    Primitives::permute(&v, i as i32)
                })
                .collect();
            if vecs.is_empty() {
                Vector::zeros(vm.dimensions())
            } else {
                let refs: Vec<&Vector> = vecs.iter().collect();
                Primitives::bundle(&refs)
            }
        }
    };

    // Collect intermediary forms. Skip leaves.
    match &ast.kind {
        ThoughtASTKind::Atom(_)
        | ThoughtASTKind::Linear { .. }
        | ThoughtASTKind::Log { .. }
        | ThoughtASTKind::Circular { .. }
        | ThoughtASTKind::Thermometer { .. } => {}
        _ => {
            let key = ast.precomputed_hash();
            computed.push((key, vec.clone()));
        }
    }

    vec
}
