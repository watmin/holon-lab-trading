# Review: Proposal 033 — Learned Scales

**Reviewer:** Brian Beckman
**Date:** 2026-04-12

---

## The central question

The proposal correctly names the problem (hardcoded scales are wrong for
any asset that doesn't match BTC circa whenever the constants were chosen)
but is silent on the consequential mathematical question raised by the
reviewer's prompt: does a changing scale corrupt the accumulated prototypes
in the reckoner?

The answer is yes — and the proposal needs to account for it.

---

## The Linear encoder is a rotation map

The scalar encoder implements:

```
encode_linear(value, scale):
    angle = (value / scale) * 2π
    v[i] = sign( base[i] * cos(angle) + ortho[i] * sin(angle) )
```

This is a rotation in the two-dimensional subspace spanned by `base` and
`ortho`, projected back to bipolar integers. The **scale** parameter
determines how much of the full 2π rotation corresponds to the observable
range of the atom. Call the rotation function `R(θ)` where `θ = value / scale`.

The key property: `R(θ)` is smooth and periodic. Two values `v1` and `v2`
produce similar vectors if and only if `|v1/scale - v2/scale|` is small.

When scale changes from `s` to `s'`, the same value `v` maps to:

```
θ  = v / s   (old angle)
θ' = v / s'  (new angle)
```

These are geometrically different points on the rotation manifold. The
cosine similarity between the old and new encoding of the identical value `v` is:

```
cos(θ - θ') = cos(v/s - v/s') = cos(v * (1/s - 1/s'))
```

For a scale change of 1% (`s' = 1.01s`) and a value at full scale
(`v = s`), this gives:

```
cos(1 - 1/1.01) = cos(0.0099) ≈ 0.9999
```

One percent scale change at full-range value: essentially identical.
The encoding is continuous in the scale parameter. Small scale changes
produce small vector changes.

This is the saving grace. The question then reduces to: **how fast can
the scale change, and how large is the rotation induced?**

---

## What "corruption" actually means

The reckoner accumulates thought vectors via an `Accumulator` (running
sum of f64 values, not thresholded). The discriminant is derived from
the difference between the Up-prototype and the Down-prototype. The
discriminant lives in the same space as the thought vectors.

When scale drifts continuously, each newly observed thought vector is a
slightly rotated version of what it would have been under the old scale.
The accumulated prototype is a frequency-weighted sum of all historical
thought vectors. So the prototype is a sum of vectors at slightly different
rotations.

This is **not** corruption in the catastrophic sense. It is a controlled
form of blur. The prototype gradually rotates to track the current
encoding. Old observations exert diminishing influence as the accumulator
accumulates more recent ones (the decay mechanism removes this concern
further).

However, there is a failure mode: if the scale changes *abruptly* by a
large amount — a sudden regime shift where BTC starts moving 5x its
historical range — then the angle `v * (1/s_old - 1/s_new)` can be
large. In the extreme case, the same market state encodes to a nearly
orthogonal vector under the new scale. The existing prototype is garbage.

---

## Magnitude of the problem

The EMA with alpha = `1/max(count, 100)` is slow. After 100 candles the
alpha is 0.01. A 50% scale increase (say, close-sma200 goes from 0.1 to
0.15) requires how many candles to propagate?

The EMA time constant at alpha=0.01 is `1/alpha = 100 candles`. To get
within 5% of the new value from the old requires `3 × time_constant = 300
candles`. At 5-minute candles: 25 hours.

During those 300 candles, the scale is somewhere between the old and new
value. The angle shift is bounded by the total regime shift. If `s_new =
1.5 * s_old` and the atom is at full scale:

```
max angle shift = v * |1/s_old - 1/s_new|
                = s_new * (1/s_old - 1/s_new)
                = s_new/s_old - 1
                = 0.5 radians ≈ 29°
```

`cos(0.5) ≈ 0.88`. During a genuine regime shift, past observations
(encoded under the old scale) and new observations (encoded under the
new scale) will have cosine ~0.88 with each other rather than 1.0.

This is a mild blur, not catastrophic corruption. The reckoner's
discriminants are derived from differences between class prototypes,
and both classes experience the same rotation. The discriminant direction
rotates with the distribution — coherently. The reckoner degrades
gracefully during regime transition and recovers as the prototype catches
up to the new encoding.

The slow EMA is actually the right choice here. A fast EMA would thrash
the cache and invalidate prototypes more aggressively. The slow EMA acts
as a low-pass filter on scale volatility — which is exactly what you want
when the downstream accumulator's memory is measured in hundreds of
candles.

---

## The IncrementalBundle interaction

The `IncrementalBundle` holds a `last_facts: HashMap<ThoughtAST, Vector>`.
When scale changes, `ThoughtAST::Linear { name, value, scale }` has a
different `scale` field. The hash changes. The old fact is "removed" and
the new fact is "added" — the incremental diff fires correctly.

This is fine. The incremental bundle handles the scale change as a changed
fact. No special handling needed. The proposal's observation that
"cache misses for that atom" is correct and already handled by the existing
mechanism.

---

## The real concern: prototype staleness during rapid drift

There is one scenario where the proposal's analysis is incomplete:
**bootstrap into a new regime**.

If the enterprise is deployed on a new asset (or restarted mid-trend),
the first 100 candles establish the scale from regime data. The reckoner
is also accumulating during these 100 candles. Those early observations
are encoded under imprecise scales.

After 100 candles, the scale stabilizes. But the reckoner's accumulated
prototypes contain 100 observations with mixed scale encodings. The
proposal notes this and says "same pattern as the distance bootstrap —
start ignorant, learn quickly, converge." This is correct, but the
*resolution* of the early observations is lower than the proposal
implies.

The proposal's bootstrap section should acknowledge: the first ~100
observations are encoded at up to `s_initial = 1.0` (the neutral
default). If the true scale converges to, say, `s_final = 0.3`, then
early observations are encoded with `scale = 1.0` while the encoding
manifold at `scale = 0.3` is 3x more sensitive. The angle shift between
the two extremes:

```
angle shift = v * (1/1.0 - 1/0.3) = v * (-2.33)
```

At `v = 0.3`: angle shift = `0.3 * 2.33 = 0.7 radians ≈ 40°`.

`cos(40°) ≈ 0.77`. These 100 early observations are semi-stale from
day 1. The accumulator's decay will wash them out over time, but the
proposal should note that a warm-start via a calibration phase (feed
the first 100–500 candles without training the reckoner) would give
cleaner early prototypes.

---

## The `* 2.0` assumption

The proposal justifies `get_scale = 2.0 * EMA(|value|)` as "covers
the 95th percentile (for a roughly Gaussian distribution, 2σ covers ~95%)."

This is the 2σ argument applied to a half-normal (since we are taking
absolute values). The EMA of `|value|` is an estimate of `E[|X|]`. For
a zero-mean Gaussian, `E[|X|] = σ * sqrt(2/π) ≈ 0.798σ`. So:

```
2.0 * E[|X|] ≈ 2.0 * 0.798σ = 1.596σ
```

This covers only ~89% of a Gaussian, not 95%. The proposal's multiplier
is *slightly too conservative* (the scale will be somewhat tighter than
claimed). The practical impact is modest — 89% vs 95% coverage means a
few extra large excursions hit the saturation region.

A better multiplier is `2.5 * EMA(|value|)` for ~95% coverage of a
zero-mean Gaussian (`2.5 * 0.798 ≈ 2.0σ`). Or, more honestly: track
EMA of `value²` (the second moment), take the square root to get
`sqrt(E[X²]) = RMS`, and use `2.0 * RMS` as the scale. This is correct
for any zero-mean distribution, not just Gaussian.

For financial indicators that are not zero-mean (close-sma200 is often
persistently one-signed in trending markets), the `EMA(|value|)` estimate
degrades further. The actual 95th percentile will be higher than the
estimated scale. The system self-corrects over time (the scale EMA will
chase the long-run mean of absolute values), but in a sustained trend the
scale underestimates the range.

This is a minor calibration issue, not a correctness issue. The direction
is right: data-derived scale is better than hardcoded. The multiplier
should be documented as approximate, with the understanding that
`round_to(2)` quantization absorbs the imprecision.

---

## On the per-observer vs global question

The proposal asks whether ScaleTrackers should be per-observer or global.

The answer is global, and the reasoning is algebraic: the scale
parameter is part of the `ThoughtAST` node and therefore part of the
cache key. If observer A uses `scale=0.31` for `close-sma200` and
observer B uses `scale=0.28`, they produce different vectors for the
same value of `close-sma200`. The cache no longer serves cross-observer
hits. The composition cache is a global resource shared across observers
(it lives on `ctx`), and cache utility depends on observers sharing AST
nodes.

More importantly: two observers should agree on *what a value means*.
`close-sma200 = 0.15` should represent the same geometric point in the
thought space regardless of which observer encodes it. The scale is a
measurement unit, not a perspective. Make it global.

The exception would be if different observers deliberately use different
*windows* of history (e.g., a short-window observer vs long-window
observer might observe genuinely different value ranges for the same atom
over their respective training windows). In that case, the observers have
genuinely different data distributions and should have different scales.
But this is a design choice that should be explicit in the observer
specification, not an emergent artifact of separate ScaleTrackers.

---

## On the EMA decay rate question

The proposal asks whether the EMA decay rate should match the recalib
interval. The answer: they serve different timescales and should be
independent.

The recalib interval controls how often discriminants are recomputed from
accumulated prototypes. It is a *snapshot* operation — it looks at the
current state of the accumulator and derives geometry.

The EMA decay rate for scales controls the *measurement unit*. A scale
that matches the recalib interval would recompute its estimate every N
candles. This creates quantized jumps in the scale at each recalib, which
defeats the `round_to(2)` cache-stability strategy. A continuous EMA
with alpha ≈ 0.01 changes the rounded scale at most every few hundred
candles — predictably and smoothly. Keep them independent.

---

## Summary judgment

The proposal is correct in intent, correct in mechanism, and correct in
the cache analysis. The two areas that need strengthening:

1. **Bootstrap**: acknowledge that scale defaults of `1.0` are
   potentially far from the converged value. Consider a calibration
   phase (encode but do not observe) for the first 100–500 candles.
   Or: use the old hardcoded scale as the initial value instead of 1.0,
   which bounds the bootstrap error.

2. **Multiplier**: document the `* 2.0` as an approximation with known
   bias for non-Gaussian, non-zero-mean indicators. The alternative
   `2.5 * EMA(|v|)` or `2.0 * EMA_RMS(v)` is more defensible.

The fundamental question — does a changing scale corrupt the reckoner's
accumulated prototypes — has the answer: no, not catastrophically. Scale
drift induces a continuous, bounded rotation on the encoding manifold.
The rotation is coherent (both classes experience it equally), the
accumulator's memory washes out stale observations, and the EMA is slow
enough that the encoding and the prototype rotate together. The system
is tolerant of the perturbation it introduces.

**Verdict: Accept with minor revisions.** The bootstrap initial value
and the multiplier documentation are the two items to address before
implementation.
