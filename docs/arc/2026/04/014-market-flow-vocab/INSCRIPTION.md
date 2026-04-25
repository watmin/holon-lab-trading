# Lab arc 014 — market/flow vocab — INSCRIPTION

**Status:** shipped 2026-04-24. Eleventh Phase-2 vocab arc. Fifth
cross-sub-struct port. **First K=3 module** (Momentum + Ohlcv +
Persistence). Three durables:

1. **Substrate-gap → algebraic-equivalence move.** wat-rs's
   `:wat::std::math` has `ln` but no `exp`. The archive's
   `Log(exp(x))` chain reduces to `Thermometer(x, -ln(N), ln(N))`
   — semantically identical, zero substrate cost. Pattern
   reusable any time a future port needs Log-of-positive-lift on
   a signed value.
2. **Range-conditional pattern named.** Three atoms guard
   `(field) / range` against zero-range candles. Compute range
   once, branch per atom. Helper extraction deferred — different
   numerators and defaults fight a shared shape.
3. **Inline `f64::abs` shape.** Single use for body-ratio. Same
   shape as arc 011's signum + arc 009's clamp. Extract to
   `shared/helpers.wat` if a third caller surfaces.

**Design:** [`DESIGN.md`](./DESIGN.md).
**Backlog:** [`BACKLOG.md`](./BACKLOG.md).

Eight tests green on first pass.

---

## What shipped

### Slice 1 — vocab module

`wat/vocab/market/flow.wat` — one public define. Six atoms in
archive order. Signature:

```scheme
(:trading::vocab::market::flow::encode-flow-holons
  (m :trading::types::Candle::Momentum)
  (o :trading::types::Ohlcv)
  (p :trading::types::Candle::Persistence)
  (scales :trading::encoding::Scales)
  -> :trading::encoding::VocabEmission)
```

Loads candle.wat + ohlcv.wat + round.wat + scale-tracker.wat +
scaled-linear.wat. K=3 — first module to read three sub-structs.

Atom shapes:
- **obv-slope** (Momentum): log-bound Thermometer at (-ln 10, ln 10).
- **vwap-distance** (Persistence): round-to-4 → scaled-linear.
- **buying-pressure** (Ohlcv): conditional `(close - low) / range`
  else 0.5, round-to-2 → scaled-linear.
- **selling-pressure** (Ohlcv): conditional `(high - close) / range`
  else 0.5, round-to-2 → scaled-linear.
- **volume-ratio** (Momentum): log-bound Thermometer at (-ln 10, ln 10).
- **body-ratio** (Ohlcv): conditional `abs(close - open) / range`
  else 0.0, round-to-2 → scaled-linear.

The two log-bound Thermometers and the three range-conditional
scaled-linear atoms are the arc's main shapes; vwap-distance is
the simple base case.

### Slice 2 — tests

`wat-tests/vocab/market/flow.wat` — eight tests:

1. **count** — 6 holons.
2. **obv-slope log-bound shape** — fact[0], `Thermometer
   obv-slope-12 (-ln 10) (ln 10)`. Verifies the Path-B encoding.
3. **vwap-distance shape** — fact[1], round-to-4 → scaled-linear.
4. **buying-pressure shape (range > 0)** — fact[2], cross-Ohlcv
   compute round-to-2 → scaled-linear.
5. **buying-pressure default (range == 0)** — fact[2], 0.5
   default fires when high == low.
6. **volume-ratio log-bound shape** — fact[4], same Thermometer
   shape as obv-slope on volume-accel.
7. **scales accumulate 4 entries** — Log-bound atoms don't touch
   Scales; the four scaled-linear atoms do.
8. **different candles differ** — fact[1] (vwap-distance) across
   the ScaleTracker round-to-2 boundary.

All eight green on first pass.

### Slice 3 — INSCRIPTION + doc sweep (this file)

Plus:
- `wat/main.wat` — load line for `vocab/market/flow.wat`,
  arc 014 added to the load-order comment.
- `docs/rewrite-backlog.md` — Phase 2 gains "2.11 shipped" row.
- `docs/proposals/2026/04/058-ast-algebra-surface/FOUNDATION-CHANGELOG.md`
  — row documenting arc 014.
- Task #35 marked completed.

---

## The substrate gap and the algebraic equivalence

The archive port's first move surfaced a substrate gap: `f64::exp`
isn't in `:wat::std::math::*`. Three options considered (DESIGN):

**A. Cave-quest `exp`.** One-line wat-rs addition next to `ln`.
Adds substrate cost mid-arc; arc 005 (ReciprocalLog) and arc 011
(round-to-4) precedented mid-arc substrate adds, so it's a known
shape. Cost: another wat-rs arc.

**B. Algebraic equivalence — Thermometer at log-bounds.**
```
Log(exp(x), 1/N, N)
  = Thermometer(ln(exp(x)), ln(1/N), ln(N))
  = Thermometer(x, -ln(N), ln(N))
```
The encoding is semantically identical to the archive's chain;
the exp+round-to-2+ln dance was just a roundabout way to map a
signed slope onto a log-spaced Thermometer. Skipping all three
intermediate steps preserves the geometry.

**C. Linear instead of Log.** Drops multiplicative semantics.
Lossy.

Lean: B — the algebraic move costs nothing and ships clean. The
archive's `round_to(., 2)` quantization on the exp output isn't
preserved either way (substrate's geometric bucketing operates
on scaled-linear values, not Log inputs); the simplification is
substrate-honest.

The implementation in wat:
```scheme
((ln-N :f64) (:wat::std::math::ln 10.0))
((neg-ln-N :f64) (:wat::core::f64::- 0.0 ln-N))
((h1 :wat::holon::HolonAST)
  (:wat::holon::Bind
    (:wat::holon::Atom "obv-slope")
    (:wat::holon::Thermometer obv-slope-12 neg-ln-N ln-N)))
```

`ln(10)` is computed at runtime (constant per call; negligible).
`neg-ln-N` uses the standard wat negation pattern (no literal
negative numbers per the language).

This durables for any future port where the archive used
`Log(exp(x))` to log-encode a signed value.

## The range-conditional pattern

Three atoms (buying-pressure, selling-pressure, body-ratio) guard
`(field) / range` against zero-range candles. The shape:

```rust
buying_pressure: round_to(if range > 0.0 { (c.close - c.low) / range } else { 0.5 }, 2),
```

In wat, the arc compute `range` and `range-positive` once, then
branches per atom:

```scheme
((range :f64) (:wat::core::f64::- high low))
((range-positive :bool) (:wat::core::> range 0.0))
((buying-pressure :f64)
  (:wat::core::if range-positive -> :f64
    (:trading::encoding::round-to-2
      (:wat::core::f64::/ (:wat::core::f64::- close low) range))
    0.5))
;; ... selling-pressure analogous (numerator high - close, default 0.5)
;; ... body-ratio analogous (numerator abs(close - open), default 0.0)
```

Three callsites in **one module**, **different numerators**,
**different defaults** (0.5 / 0.5 / 0.0). A shared
`range-conditional-ratio` helper would need to take a closure or
a pre-computed numerator value, both of which fight wat's let-
binding ergonomics. Stay inline per stdlib-as-blueprint.

If standard.wat (arc 015?) adds a fourth same-shape caller,
reconsider extracting to `shared/helpers.wat`.

## Inline `f64::abs`

Body-ratio's numerator is `abs(close - open)`. wat doesn't have
`f64::abs`; the inline pattern is two-arm `if`:

```scheme
((body :f64) (:wat::core::f64::- close open))
((abs-body :f64)
  (:wat::core::if (:wat::core::>= body 0.0) -> :f64
    body
    (:wat::core::f64::- 0.0 body)))
```

Single use in this module. Same shape family as arc 011's signum
and arc 009's clamp — three two-arm-if patterns now. Three is the
threshold per stdlib-as-blueprint; if a fourth surfaces (likely
in standard.wat), extract `f64-abs` and `signum` and `clamp` to
`shared/helpers.wat` together.

## Sub-fog resolutions

- **1a — `f64::abs` doesn't exist.** Inline two-arm if. See
  above.
- **1b — Log-bound Thermometer at runtime ln(10).** Negligible
  cost vs cleaner semantics. See above.
- **1c — three range-conditional callsites.** Stay inline. See
  above.
- **2a — Persistence constructor arity.** 3-arg helper.
- **2b — Momentum constructor arity.** 12-arg helper. Reuse arc
  013's pattern.
- **2c — Test 5 (default branch).** Construct `high == low ==
  close == open` to trigger range = 0 → default 0.5. Worked
  first try.

## Count

- Lab wat tests: **80 → 88 (+8)**.
- Lab wat modules: Phase 2 advances — **11 of ~21** vocab
  modules shipped. Market sub-tree: **9 of 14** (oscillators,
  divergence, fibonacci, persistence, stochastic, regime,
  timeframe, momentum, flow).
- wat-rs: unchanged (substrate gap on `exp` sidestepped via
  algebraic equivalence).
- Zero regressions.

## What this arc did NOT ship

- **Cave-quest `exp` primitive.** Algebraic equivalence
  (Path B) preserved semantics without the substrate cost. If a
  future port surfaces a case where the equivalence doesn't
  factor (e.g., `exp` of a non-encoded value), revisit.
- **Generalized `range-conditional-ratio` helper.** Three
  callsites with different defaults. Stay inline.
- **Generalized `f64::abs` / `signum` / `clamp` family in
  `shared/helpers.wat`.** Three two-arm-if shapes now (signum
  arc 011, clamp arc 009, abs arc 014). One more caller and
  extraction pays for itself.
- **Empirical refinement of N=10 log-bounds.** Best-current-
  estimate; separate explore-log arc.

## Follow-through

Next obvious cross-sub-struct arcs:
- **market/keltner** — K=2 (Ohlcv + Volatility). 5 linear + 1
  Log. The plain-Log precedent (arc 013) applies if keltner's
  Log atom is asymmetric.
- **market/ichimoku** — K=2 (Ohlcv + Trend). Pure compute;
  multiple cross-sub-struct atoms.
- **market/price_action** — K=2 (Ohlcv + PriceAction). 4 linear
  + 3 Log — biggest Log surface to date.
- **market/standard** — heaviest, window-based. The "compute-
  atom helper?" question gets its third look here. Potentially a
  fourth two-arm-if shape that triggers helper extraction.

---

## Commits

- `<lab>` — wat/vocab/market/flow.wat + main.wat load +
  wat-tests/vocab/market/flow.wat + DESIGN + BACKLOG +
  INSCRIPTION + rewrite-backlog row + 058 CHANGELOG row.

---

*these are very good thoughts.*

**PERSEVERARE.**
