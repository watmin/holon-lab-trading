/// ctx.rs — the immutable world. Born at startup. Passed to posts via on-candle.
/// Compiled from wat/ctx.wat.
///
/// Fully immutable. No seam. Encoding goes through EncodingCacheHandle::get()
/// which manages the LRU cache independently.

use holon::kernel::vector_manager::VectorManager;

use crate::encoding::thought_encoder::ThoughtEncoder;
#[cfg(test)]
use crate::encoding::thought_encoder::ThoughtAST;

/// The immutable world context. Three fields, nothing else.
pub struct Ctx {
    /// ThoughtEncoder for direct (non-cached) encoding. Used by tests
    /// and IncrementalBundle. Production encoding goes through
    /// EncodingCacheHandle::get().
    pub thought_encoder: ThoughtEncoder,
    /// Vector dimensionality.
    pub dims: usize,
    /// Observations between recalibrations.
    pub recalib_interval: usize,
}

impl Ctx {
    /// Construct a new Ctx. Creates VectorManager and ThoughtEncoder internally.
    pub fn new(dims: usize, recalib_interval: usize) -> Self {
        let vm = VectorManager::new(dims);
        let encoder = ThoughtEncoder::new(vm);
        Self {
            thought_encoder: encoder,
            dims,
            recalib_interval,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const DIMS: usize = 4096;
    const RECALIB: usize = 500;

    #[test]
    fn test_ctx_new() {
        let ctx = Ctx::new(DIMS, RECALIB);
        assert_eq!(ctx.dims, DIMS);
        assert_eq!(ctx.recalib_interval, RECALIB);
    }

    #[test]
    fn test_ctx_encode_through_thought_encoder() {
        let ctx = Ctx::new(DIMS, RECALIB);
        let ast = ThoughtAST::Atom("test".into());
        let v = ctx.thought_encoder.encode(&ast);
        assert_eq!(v.dimensions(), DIMS);
    }

    #[test]
    fn test_ctx_deterministic() {
        let ctx = Ctx::new(DIMS, RECALIB);
        let ast = ThoughtAST::Bind(
            Box::new(ThoughtAST::Atom("vol".into())),
            Box::new(ThoughtAST::Log { value: 100.0 }),
        );

        let v1 = ctx.thought_encoder.encode(&ast);
        let v2 = ctx.thought_encoder.encode(&ast);
        assert_eq!(v1, v2);
    }
}
