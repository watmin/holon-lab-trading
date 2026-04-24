# Lab arc 008 — market/persistence vocab — INSCRIPTION

**Status:** shipped 2026-04-23. Sixth Phase-2 vocab arc. Two
durables on top of the persistence port itself:

1. **The cross-sub-struct vocab signature rule** named and
   exercised (task #49 closed).
2. **The scale-collision footnote on distinguishability tests**
   — not a rule, a caveat that the next vocab arc with a
   similar test should inherit.

**Design:** [`DESIGN.md`](./DESIGN.md).
**Backlog:** [`BACKLOG.md`](./BACKLOG.md).

Zero substrate gaps. 4/5 tests green on first pass; the fifth
surfaced the scale-collision footnote.

---

## What shipped

### Slice 1 — the module

`wat/vocab/market/persistence.wat` — one public define with
the cross-sub-struct signature:

```scheme
(:trading::vocab::market::persistence::encode-persistence-holons
  (m :trading::types::Candle::Momentum)
  (p :trading::types::Candle::Persistence)
  (scales :trading::encoding::Scales)
  -> :trading::encoding::VocabEmission)
```

Three scaled-linear calls threading scales values-up. Emission
order: hurst, autocorrelation, adx (archive semantic grouping —
memory-in-series first, directional-strength second). Signature
order: alphabetical by sub-struct type (M < P) per the newly-
named rule.

Loads: `../../types/candle.wat`, `../../encoding/scale-tracker.wat`,
`../../encoding/scaled-linear.wat`. Same load triple as oscillators
and divergence.

### Slice 2 — tests (and a scale-collision catch)

`wat-tests/vocab/market/persistence.wat` — five tests:

1. **count** — 3 holons.
2. **hurst shape** — fact[0] coincides with hand-built Bind +
   Thermometer, exercising the Persistence-sub-struct read.
3. **adx shape** — fact[2] confirms the `/100.0` normalization
   round-trips, exercising the Momentum-sub-struct read.
4. **scales accumulate 3 entries** — updated Scales has 3 keys.
5. **different candles differ** — fact[0] of two distinct
   inputs does not coincide.

4/5 green on first pass. Test #5 initially failed because the
first-call values I chose (0.3 vs 0.7 for hurst) both round to
the same `ScaleTracker::scale` of 0.01 — producing identical
Thermometer bounds and therefore identical (saturated) encodings.
The catch: fresh-tracker scale = `round-to-2(2 × 0.01 × |V|)`,
which rounds to 0.01 for any V in roughly [0.25, 0.75]. Values
that land on different scale buckets produce different
Thermometers.

Arc 007's fibonacci test passed the equivalent by accident —
value 0.1 floors to scale 0.001, value 0.7 rounds to 0.01.
Different scales, different encodings.

Fix in persistence: span the scale boundary — A uses 0.1
(floor), B uses 0.9 (rounds to 0.02). Now both the values AND
the scales differ; the encoded Thermometers are distinct; the
test passes.

**The footnote this surfaces:** when writing a "different
candles differ" test using scaled-linear with fresh scales,
pick values on opposite sides of a scale-rounding boundary.
Same-bucket values saturate identically. Durable — every future
vocab arc with this test shape should check.

### Slice 3 — INSCRIPTION + doc sweep (this file)

Plus:
- `docs/rewrite-backlog.md` — Phase 2 gains "2.6 shipped" row
  **plus a top-of-Phase-2 note** naming the cross-sub-struct
  signature rule so future arcs see it before opening this
  INSCRIPTION.
- `docs/proposals/.../058-ast-algebra-surface/FOUNDATION-CHANGELOG.md`
  — row documenting arc 008 + the rule resolution.
- Task #49 marked completed.

---

## The cross-sub-struct rule, now standing

Arc 008's DESIGN named it; the module demonstrates it. The rule
reads:

> A vocab function's signature declares every sub-struct it
> reads, one parameter per sub-struct, ordered alphabetically
> by the sub-struct's type name. `Scales` is always the last
> parameter before the return type.

Arcs 001 – 007 were all single-sub-struct; their signatures
satisfy the rule trivially. Arc 008 is the first K=2 exercise.
The 8 remaining cross-sub-struct market modules + the exit/*
cross modules inherit the rule:

| Module | Rule-compliant signature |
|---|---|
| market/persistence | `(m :Momentum) (p :Persistence) (scales)` ← this arc |
| market/stochastic | `(d :Divergence) (m :Momentum) (scales)` |
| market/timeframe | `(o :Ohlcv) (tf :Timeframe) (scales)` |
| market/keltner | `(o :Ohlcv) (v :Volatility) (scales)` |
| market/price_action | `(o :Ohlcv) (pa :PriceAction) (scales)` |
| market/ichimoku | `(d :Divergence) (o :Ohlcv) (t :Trend) (scales)` |
| market/flow | `(m :Momentum) (o :Ohlcv) (p :Persistence) (scales)` |
| market/standard | `(m :Momentum) (o :Ohlcv) (scales)` |
| market/momentum | `(m :Momentum) (o :Ohlcv) (t :Trend) (v :Volatility) (scales)` |
| exit/phase | `(p :Phase) (...)` |
| exit/regime | `(r :Regime) (...)` |

Emission order stays independent of signature order — each
module picks its own semantic order (archive preserves this in
most cases).

## The rejected alternatives

Arc 008's DESIGN walks through why the rule isn't:

- **Full Candle pass** — signature-dishonest; function could
  touch anything on Candle. Arc 001 implicitly rejected this
  with the "vocab reads its specific sub-struct" header-comment
  pattern. Extending that pattern to K≥2 is coherent;
  retracting it would break the arc-001 chain.
- **Per-vocab view struct** — 9+ wrapper types whose only
  purpose is to group K sub-structs of the same Candle, unpacked
  by their single vocab consumer. Hickey-test fails: the view
  name braids "which sub-structs" with "the Candle."
- **Anonymous tuple** — positional access inside the body loses
  the per-parameter naming that makes the signature honest.

## Sub-fog resolutions

- **1a — adx field access.** Confirmed: adx lives on Momentum
  (position 5 of 12). Access via `:Candle::Momentum/adx m`.
  Auto-generated field getter from arc 019's struct runtime.
- **1b — adx normalization.** `/100.0` matches the cci/mfi/
  williams-r patterns in oscillators. Same round-to-2 wrapper.
- **2a — Momentum constructor arity.** 12 positional args.
  Test helper sets adx; zeros all 11 others.
- **2b — Persistence constructor arity.** 3 positional args.
  Test helper sets hurst + autocorrelation; zeros vwap-distance.
- **NEW — 2c — scale collision on distinguishability test.**
  Surfaced mid-slice-2. Resolved by picking values across the
  0.01 scale-rounding boundary.

## Count

- Lab wat tests: 45 → 50 (+5).
- Lab wat modules: Phase 2 advances — 6 of ~21 vocab modules
  shipped. Market sub-tree: 4 of 14 (oscillators, divergence,
  fibonacci, persistence).
- wat-rs: unchanged (no substrate gaps).
- Zero regressions.

## What this arc did NOT ship

- **Cross-arc emission-order standardization.** Arcs 005 – 007
  picked their own emission orders; arc 008 does too (archive
  preserves). No retroactive sweep.
- **`Ohlcv` read.** None of persistence's fields live on Ohlcv.
  The first arc to exercise Ohlcv as a vocab parameter will be
  keltner or timeframe.
- **Log-bound observation.** Persistence has zero Log atoms.
  Regime, keltner, ichimoku, flow, price_action, standard, and
  momentum each have at least one Log atom requiring an
  `explore-log.wat`-style observation program.

## Follow-through

Next obvious arc: `market/stochastic` — two sub-structs
(Divergence + Momentum), four scaled-linear atoms, no Log. K=2
same as persistence; just works. Or `market/keltner` — two
sub-structs (Ohlcv + Volatility), 5 linear + 1 Log. First Ohlcv
read; first Log-bounds question inside a cross-sub-struct port.

---

## Commits

- `<lab>` — wat/vocab/market/persistence.wat + main.wat load +
  wat-tests/vocab/market/persistence.wat + DESIGN + BACKLOG +
  INSCRIPTION + rewrite-backlog Phase-2 note + 058 CHANGELOG row.

---

*these are very good thoughts.*

**PERSEVERARE.**
