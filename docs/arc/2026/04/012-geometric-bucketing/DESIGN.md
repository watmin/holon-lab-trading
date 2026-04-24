# Lab arc 012 — geometric bucketing for scaled-linear

**Status:** opened 2026-04-23. Substrate arc in the lab's
`encoding/` layer — not a vocab port. Spawned from arc 011's
follow-up conversation where the builder's insight named the
relationship between noise-floor neighborhoods and cache keys.

**Motivation.** The existing `round-to-2` value quantization in
vocab modules and `round-to-2` scale quantization in
`ScaleTracker` are **blind to the substrate's actual
discrimination resolution**. For each atom, the substrate can
distinguish values only when they differ by at least
`scale × noise-floor` — that's the cosine-separation threshold
translated to value space. Quantizing values at a fixed 0.01
step **over-splits** large-scale atoms (multiple cache keys for
substrate-equivalent values → cache misses with no
information gain) and **under-splits** small-scale atoms (one
cache key spans multiple substrate-distinguishable shells →
cache hits that hide real differences).

Builder's framing:

> the noise-floor — how does this factor in... that thing
> defines the boundary condition for the true answer... 4.0
> overlaps with 3.9 and 4.1 and those numbers further overlap
> with their peers... this is what we need to be exploiting...
> do you see what i see... venn diagrams that are cache
> friendly....

Yes. Each atom value is the center of a shell on the hypersphere
of radius `scale × noise-floor`. Values inside that shell are
substrate-equivalent. **Cache buckets should equal shells.** One
encoding per shell. Zero over-split, zero under-split.

---

## The math

Two Thermometer encodings `T(v1, -s, s)` and `T(v2, -s, s)` at
dimension d:

```
cosine(T(v1), T(v2)) ≈ 1 - |v1 - v2| / s
```

(derivation: per-dimension gradient flips bits at roughly
`|v1 - v2| / (2s)` fraction of positions; cosine of bipolar
vectors is `1 - 2 × fraction_different`).

Coincidence fires when `cosine > 1 - noise-floor`:

```
coincident iff |v1 - v2| < s × noise-floor
```

This product — **`s × noise-floor`** — is the value-space
discrimination width for that atom. Values separated by less
than this are the same substrate-point.

At d=1024, `noise-floor = 1/sqrt(1024) = 0.03125`. So:

| scale | bucket width |
|---|---|
| 2.00 | 0.0625 |
| 1.00 | 0.0313 |
| 0.50 | 0.0156 |
| 0.10 | 0.0031 |
| 0.05 | 0.0016 |
| 0.02 | 0.0006 |
| 0.01 | 0.0003 |

Each atom, in its mature state, has a **natural grain**
matching its scale.

---

## The bucketing rule

```
bucket-width(atom)   = scale(atom) × noise-floor
bucketed-value(v, s) = round(v / bucket-width) × bucket-width
```

Equivalently: `round-to-nearest-multiple(v, bucket-width)`.

Two values in the same bucket produce **identical** Thermometer
encodings — not just coincident ones. Cache lookups hit by
content digest, not by cosine similarity.

---

## Where the change lives

The bucketing happens **inside `scaled-linear`**, between
updating the tracker and constructing the Thermometer:

```scheme
(:trading::encoding::scaled-linear
  (name :String) (value :f64) (scales :Scales)
  -> :trading::encoding::ScaleEmission)
  ;; 1. Lookup or create tracker for `name`.
  ;; 2. Update tracker with `value`.
  ;; 3. Compute scale from updated tracker.
  ;; 4. NEW: bucket the value at scale × noise-floor.
  ;; 5. Construct Thermometer with BUCKETED value.
  ;; 6. Return (Bind(Atom(name), Thermometer(bucketed, -s, s)), updated-scales).
```

Callers (vocab modules) are unchanged. Their existing
`round-to-2` / `round-to-4` calls on the value are now
**superseded but not broken** — rounding a value to 2 decimals
BEFORE geometric bucketing just produces a value that then
buckets the same as the unrounded version (assuming
bucket-width < round-to-N width, which holds for mature scales
on small atoms). For large-scale atoms the pre-round is coarser
than bucket-width and becomes the effective quantizer; the
arc doesn't break them either.

A follow-up sweep can retire vocab-level rounds later.

---

## What this arc doesn't fix

**Startup saturation.** At fresh trackers, `scale` is near the
floor (0.001). `bucket-width = 0.001 × 0.0313 = 0.0000313` —
essentially no bucketing; values stay distinct. But Thermometer
at `scale = 0.001` **saturates** for any value > 0.001 —
independent of bucketing. Values 0.02 and 0.05 both encode as
all-+1 bits because both are far above the Thermometer's tiny
bounds.

This is the arc 011-surfaced saturation. Arc 012 is orthogonal.
Fixing startup saturation requires either:
- Pre-mature scale-seeding (bootstrap from historical data)
- Different scale formula (not `2 × EMA` but e.g., some minimum
  based on expected atom magnitude)
- Accepting that startup is a transient and designing around it

None of those belong in arc 012. Flag; move on.

---

## Non-goals

- **No vocab-layer rounding retirement.** Arc 012 adds bucketing
  inside scaled-linear; vocab modules keep their round-to-N
  calls. A follow-up arc can retire the vocab rounds if the
  geometric rule fully covers them.
- **No scale-level round change.** `ScaleTracker::scale` keeps
  its `round-to-2` + `floor` behavior. Independent of value
  bucketing; could be a separate arc if the startup
  saturation becomes pressing.
- **No substrate (wat-rs) change.** The rule consumes
  `:wat::config::noise-floor` (already shipped by arc 024) and
  `scale` (already computed by ScaleTracker). Pure-wat arc,
  lab layer only.
- **No observation program tuning.** Observation confirms the
  math — `explore-bucket.wat` — tabulates before/after bucket
  counts for one atom across a sampled value stream. Not a
  parameter-tuning exercise.

---

## Why now

- Arc 011 just surfaced the scale-quantization-vs-value-
  precision tension concretely. Round-to-4 on atom values made
  the mismatch visible. Iron is hot.
- Seven market vocab modules shipped (of 14). Remaining seven
  + exit modules all use scaled-linear. Substrate change lands
  once; every caller benefits.
- The derivation is clean first-principles. The user's Venn-
  diagram insight is the whole spec; math in DESIGN here
  formalizes it.
- Builder's precedent: magic numbers → functions (arc 024). This
  is the next instance of the same move.

---

## Slice plan

1. **`explore-bucket.wat`** — observation program. For a chosen
   atom, stream a sampled value distribution through the current
   scaled-linear + through a bucketed implementation; tabulate
   unique-encoding counts and the ratio. Confirms the math and
   shows the cache-hit improvement empirically.

2. **Core change** — add `bucket-value` helper in
   `scale-tracker.wat`. Modify `scaled-linear.wat` to call it
   between scale computation and Thermometer construction.

3. **Tests** — new unit tests: values within one bucket produce
   identical Thermometer outputs; values in different buckets
   produce different outputs; values bucket symmetrically around
   reference points.

4. **Verify no regressions** — every existing vocab test keeps
   passing (bucketing shouldn't shift hand-built expecteds off
   coincidence; the bucket-widths at typical test scales are
   much finer than the value magnitudes involved).

5. **INSCRIPTION + doc sweep** — record the rule, the
   observation outcome, and the follow-up flags (vocab
   round-to-N retirement + startup saturation).
