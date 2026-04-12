# Review: Proposal 033 — Learned Scales

*Reviewed as Rich Hickey*

---

## The core diagnosis is correct

The problem is real and the framing is honest. Hardcoded scales are
knowledge smuggled in from outside the system. They are not derived from
the data. They are not even particularly good guesses for the asset they
were written for — the proposal acknowledges that 0.1 is already wrong
for BTC. This is the right thing to fix.

The vocabulary is supposed to be a *lens*, not a hypothesis about
which market it watches. Every hardcoded scale is a hypothesis. Remove
the hypotheses.

---

## What this proposal gets right

**The EMA is the right data structure.** A ring buffer of 500 values
and a sort is complexity you don't need. The EMA accumulates
continuously, uses constant space, and degrades gracefully from cold
start. The alpha schedule — equal weight for the first 100 observations,
then decaying — is a clean bootstrap without a separate warm-up mode.

**`round_to(2)` is the correct lever.** The cache key is the AST.
If the scale drifts continuously, every candle is a cache miss. Quantizing
to two decimal places means the scale changes its cache-key-visible value
rarely — the cache stays warm. This is not a hack. It is the right place
to apply quantization: at the boundary between continuous state and
discrete identity.

**"Update, read, encode" is the right sequence.** The value encodes
against the scale it helped produce. The scale reflects the distribution
of the thing being encoded. This is self-consistent.

**Log and Circular are correctly exempt.** The proposal understands *why*
those encodings are already scale-free. This is not a mechanical
enumeration — it is a correct conceptual claim.

---

## The unresolved question that matters most

**Per-observer or global?**

The proposal raises this and then offers both options without deciding.
This is the most consequential design question in the proposal.

Think about what a scale *is*. A scale answers: "what is the typical
magnitude of this value?" The magnitude of `rsi` is not a property of
the momentum observer's window. It is a property of the indicator itself
as computed from the price history. Two observers watching the same asset
with different windows will see the same `rsi` formula applied to
overlapping data. The distribution of `rsi` values does not change
substantially with window length. It is bounded by construction.

A per-observer scale for `rsi` would produce slightly different scales
for each lens — not because the indicator behaves differently, but
because of sampling noise. You would then have six slightly different
scales for the same atom, and the same atom name would encode to slightly
different vectors in each observer's context. This undermines the premise
of the shared thought encoder.

The answer is **global**. One ScaleTracker per atom name. The scale is a
property of the indicator, not of the observer. Put it on the post or
on the enterprise, not on individual observers.

The shared ThoughtEncoder is already global. The scales should be
co-located with it — on `Ctx`, alongside the ThoughtEncoder. They are
the same kind of thing: learned facts about the encoding space, not
about any particular observer's cognition.

---

## The `* 2.0` assumption deserves scrutiny

"This covers ~95% of the distribution" is only true for Gaussian data.
DI-spread is bounded to [-1, 1] by construction. It is not Gaussian.
Close-sma200 in a trending market has a fat tail. MACD histogram can
spike.

The `* 2.0` is not wrong — it is a reasonable heuristic. But name it
honestly in the code. Call it `coverage-factor`, make it a constant,
and document that it is a rule of thumb, not a statistical claim. If
you want to revisit it later, the lever is visible. If you treat it as
a magic number, the next person cannot reason about why the encoding
sometimes clips.

More importantly: clipping at the scale is not catastrophic. The scalar
encoder saturates — a value above the scale encodes to +1 or -1 in that
direction. The geometry does not break. The coverage factor affects
resolution, not correctness. A value of 1.5 covers 87% of a Gaussian.
A value of 2.0 covers 95%. The difference in encoding quality is small.
Do not let perfect be the enemy of shipped.

---

## The bootstrap framing is sound but incomplete

"Start ignorant, learn quickly, converge" is the right philosophy. But
the proposal says the default scale at candle 1 is `1.0` (or the old
hardcoded value). There is a better default: the EMA of absolute values
starts at `0.0`, and `get-scale` returns `max(ema * 2.0, 0.001)`. The
minimum clamp `0.001` prevents division by zero. No separate concept of
"default" is needed. The scale starts at the floor and rises as
observations arrive.

The concern about "the first 100 candles have imprecise scales" is valid
but understated. In the first 100 candles, the scale will be
systematically *too small* (the EMA is building up from zero or a small
seed). This means values will be encoded as relatively *large* — pushed
toward +1 or -1 more often. The reckoner will learn on these early,
slightly saturated observations. This is fine — the noise subspace also
runs concurrently and will absorb much of the early variance. The system
has multiple layers of tolerance for early noise.

---

## The cache impact section is accurate

The analysis of cache behavior is correct. Scale changes are rare due
to EMA inertia and the rounding quantization. Cache misses on scale
changes are bounded and localized to the changed atom. The LRU eviction
of stale entries is the right cleanup mechanism — passive, not active.

The one thing not mentioned: when the scale changes, the IncrementalBundle's
`last-facts` map will contain entries at the old scale. On the next candle,
those old AST keys will differ from the new AST keys (different scale field).
The incremental diff will treat them as *removed* (old) and *added* (new).
This is correct behavior. The delta path handles it cleanly without any
special-casing. The incremental bundle is resilient to scale changes by
construction.

---

## What "changes" is slightly wrong

The proposal says the ThoughtAST type does not change. This is true.
But the proposal also says vocabulary functions will "accept the scale
map as a parameter." This is new. The current signatures are:

```scheme
(define (encode-momentum-facts [c : Candle]) : Vec<ThoughtAST> ...)
```

The new signatures will be:

```scheme
(define (encode-momentum-facts [c : Candle] [scales : ScaleMap]) : Vec<ThoughtAST> ...)
```

And the call sites in `post.wat` (`market-lens-facts`, `exit-lens-facts`)
will need to pass the scale map down. That means `market-lens-facts`
and `exit-lens-facts` also need the scale map. That means `post-on-candle`
needs it. That means the post needs access to the scale map — which lives
on Ctx.

This is not a large change. But it is a **threading** problem. The scale
map needs to flow from Ctx through `post-on-candle` through
`market-lens-facts` through the individual vocab functions. Count the
touch points before you write them, so you do not discover them mid-flight.

The clean resolution: because the scale map belongs on Ctx (see above),
`post-on-candle` already receives `ctx`. The scale map is `(:scales ctx)`.
No extra parameter threading. The vocab functions receive it as a separate
argument (not the whole Ctx — that would be coupling). The call in
`market-lens-facts` passes `(:scales ctx)` to each vocab function.

---

## Naming

`ScaleTracker` is fine. `ema-abs` is fine. `get-scale` is slightly
awkward — it does not *get* a stored scale, it *computes* one from
tracked state. Call it `learned-scale` or `computed-scale`. The function
returns a derived value, not a stored one. Names should say what a thing
*is*, not how you *access* it.

`scale-map` or `ScaleMap` is a reasonable alias for
`HashMap<String, ScaleTracker>`. Define it as a newtype or type alias
so call sites do not carry the full generic.

---

## The summary judgment

This proposal is sound. The problem is real, the mechanism is correct,
the cache analysis is accurate, the exemptions are principled. The
unresolved questions are not show-stoppers — they have clear answers.

Decide: **global scales on Ctx**. That collapses both open questions at
once. The EMA decay rate should be independent of the recalib interval —
scales are properties of the market, not of the learning cycle.

One actionable addition before implementation: count the call sites.
Every vocabulary function that emits a Linear fact needs the scale map.
Audit all twelve modules. Write the new signatures in the wat files
before writing any Rust. The wards will catch mismatches between the
spec and the implementation.

The proposal is approved with the design decision above made explicit.
