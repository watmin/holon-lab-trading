/// encode.rs — the ONE way to turn a thought into geometry.
///
/// Walks the AST top-down. Checks the cache at every node.
/// Computes only misses. Installs everything.
/// The cache is Redis — get/set. The computation is on the caller's thread.

use holon::kernel::primitives::Primitives;
use holon::kernel::scalar::{ScalarEncoder, ScalarMode};
use holon::kernel::vector::Vector;
use holon::kernel::vector_manager::VectorManager;

use crate::encoding::thought_encoder::ThoughtAST;
use crate::programs::stdlib::cache::CacheHandle;

/// Encode a ThoughtAST into a Vector. Checks the cache at every node.
/// On miss, computes locally and installs. Every form is cached.
pub fn encode(
    cache: &CacheHandle<ThoughtAST, Vector>,
    ast: &ThoughtAST,
    vm: &VectorManager,
    scalar: &ScalarEncoder,
) -> Vector {
    // Check cache for this exact form — every node, every time
    if let Some(cached) = cache.get(ast) {
        return cached;
    }

    // Miss — compute locally, walking children recursively
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

    // Install in cache — fire and forget
    cache.set(ast.clone(), vec.clone());
    vec
}
