# Proposal 033 — Learned Scales

**Date:** 2026-04-12
**Author:** watmin + machine
**Status:** PROPOSED

## The problem

Every Linear atom has a hardcoded scale. `close-sma200` at 0.1.
`di-spread` at 1.0. `macd-hist` at 0.01. These scales encode
assumptions about the asset. 0.1 means "the value rarely exceeds
±0.1." For BTC, close-sma200 routinely exceeds 0.3. For equities,
it rarely exceeds 0.05. The scale is wrong for both — too tight
for BTC, too loose for equities.

The enterprise is supposed to be pair-agnostic. Any two assets.
The vocabulary should not know which market it watches. The scales
should derive from the data.

## The fix

Every Linear atom's scale is a learned value — a rolling statistic
that tracks the indicator's own observed range. The vocabulary
reads the scale. The encoding uses it. The machine discovers the
right scale from the data.

```scheme
;; Today: hardcoded
(Linear "close-sma200" 0.03 0.1)   ;; BTC assumption

;; Target: learned
(Linear "close-sma200" 0.03 (scale "close-sma200"))

;; Where (scale name) returns the learned scale for this atom.
;; The scale is the 95th percentile of abs(value) observed so far.
;; Round to 2 digits — the cache stays finite.
```

## The ScaleTracker

A simple streaming statistic per Linear atom. Tracks the range
of values the atom has seen.

```scheme
(struct scale-tracker
  [ema-abs : f64]         ;; EMA of absolute values
  [count   : usize])      ;; observations

(define (update-scale tracker value)
  (let ((alpha (/ 1.0 (max (:count tracker) 100))))
    (set! (:ema-abs tracker)
      (+ (* (- 1.0 alpha) (:ema-abs tracker))
         (* alpha (abs value))))
    (inc! (:count tracker))))

(define (get-scale tracker)
  ;; The scale is ~2x the EMA of absolute values.
  ;; This covers ~95% of the distribution.
  ;; Round to 2 digits for cache stability.
  (round-to (* 2.0 (max (:ema-abs tracker) 0.001)) 2))
```

The EMA alpha is `1 / max(count, 100)`. The first 100 observations
average equally (bootstrap). After 100, the EMA decays — recent
values weigh more. The scale breathes with the data.

The `* 2.0` covers the 95th percentile (for a roughly Gaussian
distribution, 2σ covers ~95%). The `round_to(2)` quantizes the
scale to ~100 possible values. Cache keys change slowly.

## Where it lives

The ScaleTracker lives on the vocabulary struct — each typed
vocab struct (from Phase 2) holds its own ScaleTrackers.

```rust
struct MomentumThought {
    pub close_sma20: f64,
    pub close_sma50: f64,
    pub close_sma200: f64,
    pub macd_hist: f64,
    pub di_spread: f64,
    pub atr_ratio: f64,
    // Scales — learned, not hardcoded
    pub scale_close_sma20: ScaleTracker,
    pub scale_close_sma50: ScaleTracker,
    pub scale_close_sma200: ScaleTracker,
    pub scale_macd_hist: ScaleTracker,
    pub scale_di_spread: ScaleTracker,
    // atr_ratio is Log — no scale needed
}
```

Wait — the vocab structs are constructed fresh each candle via
`from_candle()`. They don't persist. The ScaleTrackers need to
persist across candles.

The ScaleTrackers live on the OBSERVER — alongside the noise
subspace, the reckoner, the incremental bundle. Each observer
owns its ScaleTrackers for its lens. The vocabulary's `forms()`
method receives the scales as parameters.

Or simpler: one global `HashMap<String, ScaleTracker>` on Ctx or
on the post. Each atom name maps to its tracker. Every vocabulary
call updates the tracker and reads the scale. The map is shared
across all observers — the same atom should have the same scale
regardless of which observer encodes it.

## The flow

```scheme
(define (encode-momentum-facts candle scales)
  (let ((v (/ (- close sma20) close)))
    ;; Update the scale tracker for this atom
    (update-scale (get scales "close-sma20") v)
    ;; Read the learned scale
    (let ((s (get-scale (get scales "close-sma20"))))
      ;; Encode with the learned scale
      (Linear "close-sma20" (round-to v 2) s))))
```

Update, read, encode. Every candle. Every atom. The scale learns
from the value it encodes. No external knowledge. No asset
assumption.

## Which atoms need scales

Only Linear atoms need learned scales. Log atoms are naturally
scale-free (they encode ratios). Circular atoms have a fixed
period (24 hours, 7 days) that is domain-independent.

From the current vocabulary:
- **Linear atoms with hardcoded scales:** ~45 atoms across all
  modules. Each gets a ScaleTracker.
- **Log atoms:** ~25 atoms. No change.
- **Circular atoms:** ~7 atoms. No change.

## The cache impact

The ThoughtAST includes the scale: `(Linear "rsi" 0.73 1.0)`.
If the scale changes from 1.0 to 1.01, it's a new cache key.
The `round_to(2)` on the scale quantizes to 100 possible values.
Scales move slowly (EMA with alpha ~0.01). A scale might change
its rounded value once every few hundred candles. The cache stays
warm between changes.

When the scale DOES change, the cache misses for that atom.
The encoder computes the new vector. The cache warms at the new
scale. The old scale's entry is in the LRU and will eventually
evict.

## The bootstrap

At candle 1, the ScaleTracker has no observations. The scale
defaults to a neutral value — 1.0 (or the old hardcoded scale
if we want backwards compatibility). After 100 candles, the
scale has converged from the data. After 500, it's stable.

The bootstrap cost: the first 100 candles have imprecise scales.
The encoding is slightly wrong. The reckoner accumulates these
early observations. The noise subspace absorbs the scale
drift. Same pattern as the distance bootstrap — start ignorant,
learn quickly, converge.

## What changes

1. **New struct:** `ScaleTracker` in `thought_encoder.rs` or
   a new `scale_tracker.rs` module.

2. **Scale storage:** `HashMap<String, ScaleTracker>` on the
   post or on a shared struct. Passed to vocabulary functions.

3. **Vocabulary functions:** Each Linear atom updates its
   tracker and reads the scale. The `forms()` method accepts
   the scale map as a parameter.

4. **All hardcoded scales removed.** Every Linear scale comes
   from the ScaleTracker. No exceptions.

## What doesn't change

- Log and Circular encoding (already scale-free)
- The ThoughtAST type (scale is already a field on Linear)
- The ThoughtEncoder (encodes whatever AST it receives)
- The cache protocol
- The extraction pipeline
- The reckoner internals

## Questions

1. Should the ScaleTracker live per-observer or globally?
   Per-observer means each lens discovers its own scale for
   shared atoms (rsi might have different ranges through
   different windows). Global means one scale per atom name.

2. The EMA decay rate — should it match the recalib interval?
   Or be independent? Faster decay adapts to regime shifts.
   Slower decay gives more stable cache keys.

3. The `* 2.0` multiplier assumes roughly Gaussian. Should we
   track the actual percentile instead? A ring buffer of
   recent values, sorted, 95th element. More accurate but
   more state.
