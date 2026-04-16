/// encode.rs — the ONE way to turn a thought into geometry.
///
/// Walks the AST top-down. Checks the cache at every node.
/// Computes only misses. Installs everything.
/// The cache is Redis — get/set. The computation is on the caller's thread.

use std::cell::RefCell;

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
    pub ns_cache_get: u64,
    pub ns_compute: u64,
    pub ns_cache_set: u64,
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

/// Encode a ThoughtAST into a Vector. Checks the cache at every node.
/// On miss, computes locally and installs. Every form is cached.
/// Timing accumulates in thread-local EncodeMetrics — call take_encode_metrics() after.
pub fn encode(
    cache: &CacheHandle<ThoughtAST, Vector>,
    ast: &ThoughtAST,
    vm: &VectorManager,
    scalar: &ScalarEncoder,
) -> Vector {
    METRICS.with(|m| m.borrow_mut().nodes_walked += 1);

    // Check cache for this exact form — every node, every time
    let t0 = std::time::Instant::now();
    let cached = cache.get(ast);
    let ns_get = t0.elapsed().as_nanos() as u64;
    METRICS.with(|m| m.borrow_mut().ns_cache_get += ns_get);

    if let Some(v) = cached {
        METRICS.with(|m| m.borrow_mut().cache_hits += 1);
        return v;
    }
    METRICS.with(|m| m.borrow_mut().cache_misses += 1);

    // Miss — compute locally, walking children recursively
    let t0 = std::time::Instant::now();
    let vec = match ast {
        ThoughtAST::Atom(name) => {
            vm.get_vector(name)
        }
        ThoughtAST::Linear { value, scale } => {
            scalar.encode(*value, ScalarMode::Linear { scale: *scale })
        }
        ThoughtAST::Log { value } => {
            scalar.encode_log(*value)
        }
        ThoughtAST::Circular { value, period } => {
            scalar.encode(*value, ScalarMode::Circular { period: *period })
        }
        ThoughtAST::Thermometer { value, min, max } => {
            scalar.encode(*value, ScalarMode::Thermometer { min: *min, max: *max })
        }
        ThoughtAST::Permute(child, shift) => {
            let v = encode(cache, child, vm, scalar);
            Primitives::permute(&v, *shift)
        }
        ThoughtAST::Bind(left, right) => {
            let l = encode(cache, left, vm, scalar);
            let r = encode(cache, right, vm, scalar);
            Primitives::bind(&l, &r)
        }
        ThoughtAST::Bundle(children) => {
            let vecs: Vec<Vector> = children.iter()
                .map(|c| encode(cache, c, vm, scalar))
                .collect();
            if vecs.is_empty() {
                Vector::zeros(vm.dimensions())
            } else {
                let refs: Vec<&Vector> = vecs.iter().collect();
                Primitives::bundle(&refs)
            }
        }
        ThoughtAST::Sequential(items) => {
            let vecs: Vec<Vector> = items.iter().enumerate()
                .map(|(i, c)| {
                    let v = encode(cache, c, vm, scalar);
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
    let ns_comp = t0.elapsed().as_nanos() as u64;
    METRICS.with(|m| m.borrow_mut().ns_compute += ns_comp);

    // Install in cache — fire and forget
    let t0 = std::time::Instant::now();
    cache.set(ast.clone(), vec.clone());
    let ns_set = t0.elapsed().as_nanos() as u64;
    METRICS.with(|m| m.borrow_mut().ns_cache_set += ns_set);

    vec
}
