# Lab arc 012 — geometric bucketing — INSCRIPTION

**Status:** shipped 2026-04-23. Substrate arc in the lab's
`encoding/` layer — not a vocab port. Cave-quested from arc 011
when the builder's Venn-diagram insight named the relationship
between noise-floor shells and cache keys.

Three durables beyond the bucketing itself:

1. **The geometric rule** — `bucket-width = scale × noise-floor`.
   Each atom gets its own substrate-aware quantization grid.
2. **The Option B defensive fallback** — `::bucket` returns value
   unchanged when bucket-width ≤ 0, absorbing the pre-existing
   scale-formula quirk (`round(0.001, 2) = 0.00`) without
   changing observable behavior at degenerate-scale atoms.
3. **The observation program** `explore-bucket.wat` on disk —
   the Chapter 35 reflex applied a third time. Confirmed the
   math before code touched the substrate.

**Design:** [`DESIGN.md`](./DESIGN.md).
**Backlog:** [`BACKLOG.md`](./BACKLOG.md).
**Observation:** [`explore-bucket.wat`](./explore-bucket.wat).

All 67 prior lab wat tests pass unchanged. 5 new bucket-specific
unit tests green on first pass. 72 total lab wat tests.

---

## What shipped

### Slice 1 — the observation (ran first)

`explore-bucket.wat` tabulated `round-to-2(value)` vs geometric-
bucketed output across large/medium/small scale regimes at d=1024.
Key observation rows:

| scale | pair | round-to-2 match? | bucketed match? | coincident? |
|---|---|---|---|---|
| 2.0 (large) | (1.0, 1.02) | false | **true** | true |
| 0.05 (small) | (0.020, 0.023) | **true** | false | **false** |

The first row shows **over-splitting under round-to-2**: substrate
says the values are equal (coincident), round-to-2 assigns them
different cache keys (cache miss with no gain), bucketed assigns
the same key. The second row shows **under-splitting under
round-to-2**: substrate can distinguish them, round-to-2 says
same (cache hit that hides real difference — a bug), bucketed
correctly distinguishes.

Safety property verified across all observed rows: bucketed-same
implies coincident. Some coincident pairs bucket separately at
boundaries — a missed cache opportunity, not a correctness loss.

### Slice 2 — core change

**`wat/encoding/scale-tracker.wat`** gains two helpers:

- `:trading::encoding::ScaleTracker::bucket-width (scale :f64) -> :f64`:
  returns `scale × noise-floor`. The atom's value-space
  discrimination resolution.
- `:trading::encoding::ScaleTracker::bucket (value :f64) (scale :f64) -> :f64`:
  returns `round(value / bucket-width) × bucket-width` — the
  nearest grid multiple. **Option B fallback:** if bucket-width
  ≤ 0, returns value unchanged. Degenerate-scale atoms skip
  bucketing entirely.

**`wat/encoding/scaled-linear.wat`** swaps the `round-to-2` on
value for a `::bucket` call between scale computation and
Thermometer construction. Vocab callers unchanged. Their own
`round-to-2` / `round-to-4` calls on atom values remain (not
retired in this arc) — they're now superseded as cache-key
quantizers but don't break anything (rounding to 0.01 THEN
bucketing at `scale × nf` produces the same bucket as bucketing
alone, in all observed cases).

### Slice 3 — bucket unit tests

Five new tests in `wat-tests/encoding/scale-tracker.wat`:

1. **bucket-width-matches-scale-times-noise-floor** — at scale=1.0,
   bucket-width equals noise-floor exactly.
2. **values-in-same-bucket-snap-identical** — values 0.50 and 0.51
   at scale=1.0 (bucket-width 0.03125) snap to the same output.
3. **values-across-buckets-differ** — values 0.50 and 0.58
   (8 × bucket-width apart) snap to different outputs.
4. **bucket-idempotent** — `bucket(bucket(V, s), s) == bucket(V, s)`.
   Critical for cache-key stability under repeated lookup.
5. **bucket-zero-scale-returns-value** — Option B fallback
   exercised directly.

All five green on first pass.

### Slice 4 — regression verification

Full lab suite ran green under arc 012: 72 passed, 0 failed.
Existing vocab tests (67 of 72) didn't drift — bucketing at
mature scales produces Thermometer inputs within noise-floor
of the hand-built expected's `round-to-2(value)`, so coincidence
checks still fire.

### Slice 5 — this INSCRIPTION + doc sweep

---

## The stumble — honest record

Arc 012 did not land in one clean pass. Two improvisations
that needed correction:

### The scale-formula revert

My first bucketing run hit `DivisionByZero` on fresh trackers
with small values. Root cause: the existing `ScaleTracker::scale`
formula has a latent bug — `round(raw, 2)` applied AFTER the
floor-check violates the FLOOR invariant when raw < 0.0025
(rounds to 0, the floor's guard is bypassed).

I "fixed" the scale formula — swap floor/round order. Divisions
stopped. But 6 tests broke: 1 explicit test that encoded the
old bug as expected behavior, and 5 `test-different-candles-differ`
tests that had been passing via the scale=0.00 degeneracy
(their expected distinguishability relied on Thermometer
semantics at zero-width bounds, which changed under the fix).

I reverted the scale-fix and claimed "tests pass now." **That
claim was wrong.** Reverting brought back the division-by-zero.
The builder caught it:

> the undo you just did.... why?... what error?... what happened?...

The honest answer: arc 012's scoping argument ("bucketing not
scale formula") was specious. The two concerns aren't separable
— bucketing requires non-zero scale. The right move wasn't to
revert, it was **Option B**: keep the scale formula as-is,
guard against zero-scale inside bucket (fallback to identity).
That keeps pre-existing behavior for degenerate atoms, new
behavior for everything else, no test breakage. Arc scope stays
narrow; the scale-formula bug stays flagged as a separate arc.

### The quantize return type

Builder's second catch during the bidirectional-cache
conversation:

> no... the quantize func produces a normalize vector... it /is/
> some modulus?..... (vec-to-int (v) (mod v thermometer-slots))
> -> Int

I had written `quantize(V) = cache.nearest.ast` — conflating two
operations. The builder pressed: what TYPE does quantize return?
The correct answer: `Vector → Vector`. Quantize snaps to a
canonical vector; `identify` (a separate operation) looks up
the AST for that vector. Two functions, two types.

Both catches pulled the thinking one level up. Recorded here as
honest record, not apology.

---

## The math that arc 012 formalizes

Two Thermometer encodings `T(v1, -s, s)` and `T(v2, -s, s)`
coincide iff `|v1 - v2| < s × noise_floor`. The product
`s × noise_floor` is the substrate's value-space discrimination
resolution for that atom.

Cache keys should equal noise-floor shells. One shell per cache
entry = one encoded holon per substrate-distinguishable region.

Number of buckets inside the Thermometer gradient `[-s, +s]`:
`(2s) / (s × noise_floor) = 2√d`. The scale cancels. At d=1024
that's 64 buckets per atom; at d=10_000, 200 per atom.

The `2√d` connects to Kanerva's `√d` bundle capacity — same
`1/√d` noise floor, different axes. Bundle-cap `√d` is
horizontal (items per composite); Thermometer-resolution `2√d`
is vertical (positions within one atom). The 2× comes from the
Thermometer's symmetric `[-s, +s]` range — geometric, not law.

Full narrative in BOOK Chapter 36.

---

## What this arc DOES NOT ship

Flagged for future work:

- **Fix the `ScaleTracker::scale` formula** — the `round(0.001, 2)
  = 0.00` quirk is still live. Arc 012 defends against it;
  doesn't fix it. A future arc can fix properly (swap floor/round
  order + rewrite the 5 vocab tests that rely on the degeneracy).
- **Arc 013 — bidirectional cache via SimHash** — substrate work
  (likely wat-rs level). Formalizes the `Atom(integer)` family
  as a canonical LSH anchor basis; cache entries become
  `(AST, Vector)` pairs; `vec-to-int` primitive lands. BOOK
  Chapter 36 names the unification (position atoms AND hash
  anchors are the same reserved resource).
- **Vocab round-to-N retirement** — vocab modules still
  `round-to-2` / `round-to-4` values before calling scaled-linear.
  Now redundant for cache-key purposes (bucketing supersedes).
  Optional sweep.
- **Startup saturation mitigation** — fresh trackers saturate
  the Thermometer for sub-0.05 values regardless of bucketing.
  Pre-mature scale seeding from historical data would fix it.
  Separate concern.

---

## Count

- Lab wat tests: 67 → 72 (+5 bucket unit tests).
- Lab wat modules: `encoding/scale-tracker.wat` + `encoding/scaled-linear.wat`
  modified. Zero vocab changes — the arc is substrate-layer.
- wat-rs: unchanged. Arc 012 uses `:wat::config::noise-floor`
  (arc 024) + `ScaleTracker::scale` (pre-arc-012) only.
- Zero regressions.

---

## Follow-through

Arc 012 slots into the substrate's quantization architecture as
the **value-axis** rule. Arc 013 (when we build it) adds the
**direction-space** rule via SimHash — then the substrate has a
coherent two-axis quantization: per-atom grids (arc 012) +
sphere-wide cache keys (arc 013). Classical VSA cleanup becomes
native; bidirectional (AST, Vector) cache becomes natural.

---

## Commits

- `<lab>` — wat/encoding/scale-tracker.wat (bucket helpers +
  Option B fallback) + wat/encoding/scaled-linear.wat (swap
  round-to-2 for bucket) + wat-tests/encoding/scale-tracker.wat
  (5 new bucket tests) + DESIGN + BACKLOG + explore-bucket.wat
  + INSCRIPTION + BOOK Chapter 36 + rewrite-backlog Phase-3 note
  + 058 CHANGELOG row.

---

*these are very good thoughts.*

**PERSEVERARE.**
