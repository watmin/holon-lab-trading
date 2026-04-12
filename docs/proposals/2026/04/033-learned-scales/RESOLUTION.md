# Resolution: Proposal 033 — Learned Scales

**Date:** 2026-04-12
**Decision:** ACCEPTED — implement

## Designers

Both accepted.

**Hickey:** No bootstrap default — EMA starts at zero, floor at
0.001. The `* 2.0` is a named constant. IncrementalBundle handles
scale changes correctly by construction (old scale key removed,
new scale key added — the diff fires).

**Beckman:** Scale drift doesn't corrupt prototypes — the rotation
is coherent. Both prototypes shift together. The discriminant
recovers. 1% scale change = cos(shift) ≈ 0.9999. Regime shift
(50%) = cos ≈ 0.88, recovers in ~25 hours with the slow EMA.
The `* 2.0` covers ~89% not 95%. Document as approximate.

## Designers overruled on scope

Both said global scales on Ctx. **Overruled.** The scale is
per-asset-pair. BTC/USDC has different ranges than ETH/USDC.
The same `close-sma200` atom produces scale 0.30 on BTC and
0.05 on equities. The scale lives on the post — one post per
pair, one scale map per post.

Ctx stays immutable. The scales are mutable state that evolves
per candle, per pair. The post owns them.

## The changes

1. **New struct:** `ScaleTracker` in a new `scale_tracker.rs`
   module.

   ```rust
   pub struct ScaleTracker {
       ema_abs: f64,
       count: usize,
   }

   pub const SCALE_COVERAGE: f64 = 2.0; // named constant, ~89% coverage

   impl ScaleTracker {
       pub fn new() -> Self {
           Self { ema_abs: 0.0, count: 0 }
       }

       pub fn update(&mut self, value: f64) {
           self.count += 1;
           let alpha = 1.0 / (self.count.max(100) as f64);
           self.ema_abs = (1.0 - alpha) * self.ema_abs + alpha * value.abs();
       }

       pub fn scale(&self) -> f64 {
           round_to((SCALE_COVERAGE * self.ema_abs).max(0.001), 2)
       }
   }
   ```

2. **Scale storage on the post:** `HashMap<String, ScaleTracker>`
   on the Post struct. One map per asset pair.

   ```rust
   pub struct Post {
       // ... existing fields
       pub scales: HashMap<String, ScaleTracker>,
   }
   ```

3. **Vocabulary functions accept scales:** Each `encode_*_facts`
   function receives `&mut HashMap<String, ScaleTracker>`. It
   updates the tracker for each Linear atom and reads the scale.

   ```rust
   fn encode_with_scale(
       name: &str, value: f64,
       scales: &mut HashMap<String, ScaleTracker>,
   ) -> ThoughtAST {
       let tracker = scales.entry(name.to_string())
           .or_insert_with(ScaleTracker::new);
       tracker.update(value);
       let s = tracker.scale();
       ThoughtAST::Linear {
           name: name.into(),
           value: round_to(value, 2),
           scale: s,
       }
   }
   ```

4. **All hardcoded Linear scales removed.** Every Linear atom
   uses the learned scale from its ScaleTracker. No exceptions.
   Log and Circular atoms unchanged.

5. **Threading:** `post.on_candle()` already owns the post.
   `post.scales` is available. Pass `&mut post.scales` to
   vocabulary functions. In the binary, the scales map flows
   through the same path as the candle.

## What doesn't change

- Log encoding (naturally scale-free)
- Circular encoding (fixed period — domain-independent)
- ThoughtAST type (scale is already a field on Linear)
- ThoughtEncoder (encodes whatever AST it receives)
- Cache protocol (the AST key includes the scale — when scale
  changes, the key changes, cache miss, recompute, warm at new scale)
- IncrementalBundle (handles scale changes by construction)
- Reckoner internals
- Extraction pipeline

## Bootstrap

EMA starts at zero. First candle: `scale = max(2.0 * 0.0, 0.001)
= 0.001`. Near-zero. The encoding uses almost the entire manifold
for tiny values. Over 100 candles, the EMA converges. By candle
500, the scale is stable. The noise subspace absorbs the drift.
Same bootstrap pattern as distances.

No hardcoded initial value. The machine starts ignorant and
learns. Always.
