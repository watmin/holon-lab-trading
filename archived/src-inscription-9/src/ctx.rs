/// The immutable world — born at startup, immutable DURING each candle.
/// The ThoughtEncoder's composition cache is the one seam —
/// updated BETWEEN candles from collected misses.

use holon::kernel::vector::Vector;

use crate::enums::ThoughtAST;
use crate::thought_encoder::ThoughtEncoder;

/// The context struct — immutable during each candle.
pub struct Ctx {
    /// Contains VectorManager + composition cache (the seam).
    pub thought_encoder: ThoughtEncoder,
    /// Vector dimensionality.
    pub dims: usize,
    /// Observations between recalibrations.
    pub recalib_interval: usize,
}

impl Ctx {
    /// Create a new context.
    pub fn new(thought_encoder: ThoughtEncoder, dims: usize, recalib_interval: usize) -> Self {
        Self {
            thought_encoder,
            dims,
            recalib_interval,
        }
    }

    /// Insert cache misses into the ThoughtEncoder between candles.
    /// This is the one seam — the sequential phase after all parallel steps.
    pub fn insert_cache_misses(&mut self, misses: Vec<(ThoughtAST, Vector)>) {
        self.thought_encoder.insert_cache_misses(misses);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use holon::kernel::vector_manager::VectorManager;

    #[test]
    fn test_ctx_construct() {
        let vm = VectorManager::new(4096);
        let encoder = ThoughtEncoder::new(&vm);
        let ctx = Ctx::new(encoder, 4096, 500);
        assert_eq!(ctx.dims, 4096);
        assert_eq!(ctx.recalib_interval, 500);
    }

    #[test]
    fn test_ctx_insert_cache_misses() {
        let vm = VectorManager::new(4096);
        let encoder = ThoughtEncoder::new(&vm);
        let mut ctx = Ctx::new(encoder, 4096, 500);

        let ast = ThoughtAST::Linear { name: "rsi".into(), value: 0.55, scale: 1.0 };
        let (_vec, misses) = ctx.thought_encoder.encode(&ast);
        assert!(!misses.is_empty());

        ctx.insert_cache_misses(misses);

        // Now it should be cached
        let (_vec2, misses2) = ctx.thought_encoder.encode(&ast);
        assert!(misses2.is_empty());
    }
}
