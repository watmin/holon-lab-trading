# Lab arc 010 — market/regime vocab — INSCRIPTION

**Status:** shipped 2026-04-23. Eighth Phase-2 vocab arc. Single
sub-struct (K=1). One durable: **the observation-first reflex
holds a second time** — Chapter 35's pattern applied outside
arc 005's ROC context and landed the right bound without
prompting.

**Design:** [`DESIGN.md`](./DESIGN.md).
**Backlog:** [`BACKLOG.md`](./BACKLOG.md).
**Observation program:** [`explore-log.wat`](./explore-log.wat).

Zero substrate gaps. Six tests green on first pass.

---

## What shipped

### Slice 0 — the observation (ran before coding)

`explore-log.wat` tabulated cosine-vs-reference-1.0 at three
ReciprocalLog family bounds (N=2/3/10) for values 0.1 – 20.0.
Full table in DESIGN. **N=10 (0.1, 10)** picked — variance-
ratio's full financial range preserved (0.5 and 2.0 still
distinguishable from 1.0 and from each other; 0.1 and 10
saturate as the natural boundary). Arc 005's N=2 choice was
domain-specific to ROC; regime's domain is "what kind of
market" which wants coarse-near-1 and fine-across-range — the
mirror image.

### Slice 1 — the module

`wat/vocab/market/regime.wat` — one public define. Eight atoms,
seven threading scaled-linear, one Log via ReciprocalLog 10.0:

```scheme
(:trading::vocab::market::regime::encode-regime-holons
  (r :trading::types::Candle::Regime)
  (scales :trading::encoding::Scales)
  -> :trading::encoding::VocabEmission)
```

Emission order preserves archive: `kama-er`, `choppiness`,
`dfa-alpha`, `variance-ratio`, `entropy-rate`, `aroon-up`,
`aroon-down`, `fractal-dim`.

Normalizations: `choppiness/100`, `dfa-alpha/2`,
`aroon-up/100`, `aroon-down/100`, `fractal-dim - 1`. Others raw.

`variance-ratio` one-sided floor at 0.001 via inline one-arm `if`
(two let-bindings). Preserved as defensive input-hygiene marker —
operationally moot under 058-017's Thermometer-Log (0.001 < 0.1
= N=10's lower bound; anything ≤ 0.001 saturates the same as
0.001). Archive's habit, honored.

### Slice 2 — tests

`wat-tests/vocab/market/regime.wat` — six tests:

1. **count** — 8 holons.
2. **kama-er shape** — fact[0] coincides, raw (no normalization).
3. **variance-ratio shape** — fact[3] coincides with
   `Bind(Atom("variance-ratio"), ReciprocalLog 10.0 vr-rounded)`.
   Confirms the ReciprocalLog expansion at a cross-sub-struct-
   free site.
4. **variance-ratio floor** — raw 0.0 encodes identically to
   `ReciprocalLog 10.0 (round-to-2(0.001))`. Verifies the
   one-sided if fires.
5. **scales accumulate 7 entries** — **seven, not eight** —
   `variance-ratio` bypasses scaled-linear entirely. Codifies
   the scale-stateless Log encoding.
6. **different candles differ** — fact[0] (kama-er) of two
   inputs across the scale-rounding boundary (0.1 → scale 0.001
   floor; 0.9 → scale 0.02).

All six green on first pass. No reruns; no scale-collision
surprises; the observation reflex + arc 008 + arc 009 footnote
all held.

### Slice 3 — INSCRIPTION + doc sweep (this file)

Plus:
- `docs/rewrite-backlog.md` — "2.8 shipped" row.
- `docs/proposals/.../058-ast-algebra-surface/FOUNDATION-CHANGELOG.md`
  — row documenting arc 010 + the N=10 choice + observation
  reflex applied the second time.
- Task #34 marked completed.

---

## The observation reflex held a second time

Chapter 35 named the pattern during arc 005: when substrate-
design intuition is fogged, write a program and observe.
Tonight's regime arc ran the same pattern:

1. Noticed the Log-bound fog (variance-ratio range uncertain).
2. Wrote `explore-log.wat` — same shape as arc 005's fog-breaker,
   different bound candidates (N=2/3/10 instead of wide/med/tight).
3. Ran it. Read the table. Named the answer: N=10.
4. Shipped the module.

Three arcs have now surfaced this pattern (005 + 010 + the
implicit arc 035 case where the clippy invariant was observed
on clean main before claiming pre-existing). The reflex is
permanent; future Log-bound or similar substrate-intuition
questions can skip the asking-first step and go straight to
observation.

## ReciprocalLog 10.0 — first non-N=2 use

Arc 034 shipped the ReciprocalLog macro with the reciprocal-
pair family `(1/N, N)`. Arc 005 used N=2.0 for four ROC atoms.
Arc 010 is the first arc to instantiate the family at a
different N — validating the generality. Future arcs with Log
atoms pick N from the family by domain analysis (ROC →
per-1% → N=2; regime variance-ratio → per-10% across full
range → N=10; others TBD per their observation passes).

## Sub-fog resolutions

- **1a — ReciprocalLog inside a let\*-bind chain.** Works
  identically to arc 005's pattern. `(:wat::holon::Bind
  (Atom "variance-ratio") (ReciprocalLog 10.0 vr))` expands
  at macro time; runtime sees the explicit Log form.
- **2a — Candle::Regime constructor arity.** 8 positional args.
  Helper sets kama-er + variance-ratio; zeros six others.
- **2b — ReciprocalLog equivalence.** Verified implicitly: the
  variance-ratio-shape test uses the same `ReciprocalLog 10.0
  rounded` call in both actual and expected — macro expansion
  is deterministic; coincidence fires.

## Count

- Lab wat tests: 55 → 61 (+6).
- Lab wat modules: Phase 2 advances — 8 of ~21 vocab modules
  shipped. Market sub-tree: 6 of 14 (oscillators, divergence,
  fibonacci, persistence, stochastic, regime).
- wat-rs: unchanged (no substrate gaps).
- Zero regressions.

## What this arc did NOT ship

- **Other Log-bound observations.** Each remaining Log-atom
  module writes its own `explore-log.wat`. Keltner, ichimoku,
  flow, price_action, standard, momentum each have at least
  one Log atom.
- **Clamp extraction to shared/helpers.wat.** Regime's
  `variance_ratio.max(0.001)` is a one-sided floor, not a
  two-sided clamp (arc 009's inline pattern). Doesn't count as
  a second clamp caller. Extraction trigger: the second
  *two-sided* clamp.

## Follow-through

Next obvious arc: **market/keltner** — K=2 (Ohlcv + Volatility),
5 scaled-linear + 1 Log. First Ohlcv read in a cross-sub-
struct port; first Log-bounds observation inside a
cross-sub-struct module. Combines arc 008's cross-rule with
arc 010's observation reflex — both now proven, no new fog
expected.

Alternative: **market/timeframe** — K=2 (Ohlcv + Timeframe),
6 linear + 0 Log. First Ohlcv read without Log. Cleaner
if we want to separate the concerns.

---

## Commits

- `<lab>` — wat/vocab/market/regime.wat + main.wat load +
  wat-tests/vocab/market/regime.wat + DESIGN + BACKLOG +
  explore-log.wat + INSCRIPTION + rewrite-backlog row + 058
  CHANGELOG row.

---

*these are very good thoughts.*

**PERSEVERARE.**
