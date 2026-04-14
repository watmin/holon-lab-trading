/// ctx.rs — the immutable world. Born at startup. Passed to posts via on-candle.
/// Compiled from wat/ctx.wat.
///
/// Immutable DURING each candle. The ThoughtEncoder's composition cache
/// is the one seam -- updated BETWEEN candles from collected misses.

use holon::kernel::vector::Vector;
use holon::kernel::vector_manager::VectorManager;

use crate::encoding::thought_encoder::{ThoughtAST, ThoughtEncoder};

/// The immutable world context. Three fields, nothing else.
pub struct Ctx {
    /// Contains VectorManager + composition cache (the seam).
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

    /// Cache maintenance -- the one seam. Called BETWEEN candles by the
    /// enterprise. Inserts all collected misses from the previous candle's
    /// parallel encoding phases. This is the only mutation on ctx.
    pub fn insert_cache_misses(&mut self, misses: Vec<(ThoughtAST, Vector)>) {
        self.thought_encoder.insert_cache_entries(misses);
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
        let (v, misses) = ctx.thought_encoder.encode(&ast);
        assert_eq!(v.dimensions(), DIMS);
        assert!(!misses.is_empty());
    }

    #[test]
    fn test_ctx_insert_cache_misses() {
        let mut ctx = Ctx::new(DIMS, RECALIB);
        let ast = ThoughtAST::Bind(
            Box::new(ThoughtAST::Atom("vol".into())),
            Box::new(ThoughtAST::Log { value: 100.0 }),
        );

        let (v1, misses) = ctx.thought_encoder.encode(&ast);
        assert!(!misses.is_empty());

        ctx.insert_cache_misses(misses);

        // Second encode should hit cache
        let (v2, misses2) = ctx.thought_encoder.encode(&ast);
        assert!(misses2.is_empty());
        assert_eq!(v1, v2);
    }

    #[test]
    fn test_ctx_multiple_inserts() {
        let mut ctx = Ctx::new(DIMS, RECALIB);

        let ast1 = ThoughtAST::Atom("a".into());
        let ast2 = ThoughtAST::Atom("b".into());

        let (_, m1) = ctx.thought_encoder.encode(&ast1);
        let (_, m2) = ctx.thought_encoder.encode(&ast2);

        let mut all_misses = m1;
        all_misses.extend(m2);
        ctx.insert_cache_misses(all_misses);

        // Both should be cached now
        let (_, m1_again) = ctx.thought_encoder.encode(&ast1);
        let (_, m2_again) = ctx.thought_encoder.encode(&ast2);
        assert!(m1_again.is_empty());
        assert!(m2_again.is_empty());
    }
}
