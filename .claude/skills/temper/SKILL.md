---
name: temper
description: Quiet the fire. The datamancer tempers wasteful computation — redundant calls, invariant work in loops, data recomputed when nothing changed. Correct but hot.
argument-hint: [file-path]
---

# Temper

> Tempered steel is not weaker steel. It is steel that wastes no energy on internal stress.

The other wards check if the code is correct, alive, true, beautiful, well-made, and expressed. The temper checks if the code is **efficient**. Not "fast" in the micro-optimization sense — efficient in the algebraic sense. Does the computation do more work than the problem requires?

A pure function called six times with the same argument is correct. It is also wasteful. The temper finds where the code burns more than it needs.

## What the temper finds

### 1. Redundant pure calls

A pure function called multiple times with identical arguments. The result never changes. Compute once, bind to a name, reuse.

```rust
// HOT: noise_floor(dims) computed 6 times per candle
for observer in &observers {
    let threshold = 3.0 / (dims as f64).sqrt();  // same every time
    if obs.raw_cos.abs() < threshold { continue; }
}

// TEMPERED: compute once, use many
let threshold = noise_floor(dims);
for observer in &observers {
    if obs.raw_cos.abs() < threshold { continue; }
}
```

### 2. Loop-invariant computation

Work inside a loop that doesn't depend on the loop variable. Hoist it outside.

```rust
// HOT: ATR conversion computed every iteration
for candle in candles {
    let atr_abs = candle.atr_r * candle.close;  // depends on candle — OK
    let noise = 3.0 / (dims as f64).sqrt();     // does NOT depend on candle — hoist
}
```

### 3. Recalibration-frequency waste

Data recomputed every candle that only changes at recalibration boundaries. The enterprise has a natural rhythm: most state changes happen at recalibration intervals (every N candles). Computing risk features, conviction thresholds, or curve fits on every candle when the inputs haven't changed is wasteful.

```rust
// HOT: risk branch features computed every candle
let branch_features = portfolio.risk_branch_wat(vm, scalar);

// TEMPERED: compute at recalibration intervals, cache between
if encode_count % recalib_interval == 0 || encode_count < 100 {
    cached_risk_features = portfolio.risk_branch_wat(vm, scalar);
}
```

### 4. Redundant traversals

Multiple passes over the same data that could be fused into one.

```rust
// HOT: two passes
let buys = preds.iter().filter(|p| p.raw_cos > 0.0).count();
let total_conv = preds.iter().map(|p| p.conviction).sum::<f64>();

// TEMPERED: one pass
let (buys, total_conv) = preds.iter().fold((0, 0.0), |(b, c), p| {
    (b + if p.raw_cos > 0.0 { 1 } else { 0 }, c + p.conviction)
});
```

### 5. Allocation in the hot path

Creating vectors, strings, or collections inside per-candle loops when they could be pre-allocated or reused.

```rust
// HOT: Vec allocated every candle
let mut facts: Vec<Vector> = Vec::new();

// TEMPERED: pre-allocated with capacity
let mut facts: Vec<Vector> = Vec::with_capacity(64);
```

## How to scan

Read the target file. For each function, each loop, each per-candle computation:

1. **Is this pure?** Same inputs always give same outputs? If yes, how many times is it called with the same inputs?
2. **Is this inside a loop?** Does it depend on the loop variable? If not, hoist it.
3. **How often does this change?** Every candle? Every recalibration? Once at startup? Match computation frequency to change frequency.
4. **How many passes?** Could two iterations over the same data be fused?
5. **Is this allocating?** Could it reuse a buffer?

Report findings with line numbers. For each:
- **What's hot:** the redundant or wasteful computation
- **Why it's hot:** how often it runs vs how often it needs to
- **How to temper:** the fix (hoist, cache, fuse, pre-allocate)

## What temper is NOT

- Not a profiler. The temper reads code, not flamegraphs. It catches structural waste visible in the source.
- Not micro-optimization. Don't temper a single addition. Temper a function called 600,000 times that recomputes a constant.
- Not reap. Reap finds dead code (computed but never read). Temper finds live code (computed and read) that computes more than necessary.
- Not forge. Forge checks if values flow and functions compose. Temper checks if the composition does redundant work.

## Runes

Skip findings annotated with `rune:temper(category)` in a comment at the site. The annotation must include a reason after the dash.

```rust
// rune:temper(intentional) — recomputing here avoids caching complexity; 
// the cost is O(1) and the clarity is worth it
```

Categories: `intentional` (wasteful but clarity wins), `cached` (already cached elsewhere), `rare-path` (runs infrequently, not worth optimizing).

## The principle

The forge makes the blade. The temper removes the internal stress. Tempered code computes no more than once for what should be computed once. It matches computation frequency to change frequency. It is not faster code — it is right-sized code.

The datamancer tempers. The fire quiets. The blade holds its edge.
