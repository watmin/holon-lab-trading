# Lab arc 014 — market/flow vocab — BACKLOG

**Shape:** three slices. Zero substrate gaps (the missing `exp`
is sidestepped via algebraic equivalence — see DESIGN). One
shared compute pattern (range-conditional ratio) inlined three
times.

---

## Slice 1 — vocab module

**Status: ready.**

New file `wat/vocab/market/flow.wat`:
- Loads candle.wat + ohlcv.wat + round.wat + scale-tracker.wat +
  scaled-linear.wat.
- Defines `:trading::vocab::market::flow::encode-flow-holons`
  with signature `(m :Candle::Momentum) (o :Ohlcv) (p
  :Candle::Persistence) (scales :Scales) -> :VocabEmission`.
  Leaf-alphabetical: M < O < P.
- Six atoms — emission order matches archive: obv-slope,
  vwap-distance, buying-pressure, selling-pressure, volume-ratio,
  body-ratio.
- obv-slope and volume-ratio: log-bound Thermometer at
  (-ln 10, ln 10), no scales. ln 10 evaluated at runtime via
  `:wat::std::math::ln 10.0`.
- vwap-distance: round-to-4 → scaled-linear.
- buying-pressure / selling-pressure / body-ratio: range-conditional
  compute, round-to-2 → scaled-linear. Compute `range` and
  `range-positive` once via let-binding; branch per atom.

Wiring: `wat/main.wat` gains a load line for `vocab/market/flow.wat`.

**Sub-fogs:**
- **1a — `f64::abs` doesn't exist in wat.** Inline two-arm `if`
  for body-ratio's `abs(close - open)`. Single use; same shape
  as arc 011's signum.
- **1b — Log-bound Thermometer at runtime ln(10).** `ln 10` is a
  constant per call but evaluated each time. No precomputed-
  literal magic; the runtime cost is negligible vs cleaner
  semantics.
- **1c — three range-conditional callsites.** Different
  numerators (close-low, high-close, abs(close-open)) and
  defaults (0.5, 0.5, 0.0). Stay inline; helper extraction
  fights wat's let-binding ergonomics.

## Slice 2 — tests

**Status: obvious in shape** (once slice 1 lands).

New file `wat-tests/vocab/market/flow.wat`. Eight tests:

1. **count** — 6 holons.
2. **obv-slope log-bound shape** — fact[0], `Thermometer
   obv-slope-12 (-ln 10) (ln 10)`. Verifies the Path-B encoding.
3. **vwap-distance shape** — fact[1], round-to-4 → scaled-linear.
4. **buying-pressure shape (range > 0)** — fact[2], cross-Ohlcv
   compute (close - low) / range, round-to-2.
5. **buying-pressure default (range == 0)** — fact[2], 0.5
   default when high == low.
6. **volume-ratio log-bound shape** — fact[4], same Thermometer
   path as obv-slope but reading volume-accel.
7. **scales accumulate 4 entries** — vwap-distance + buying +
   selling + body-ratio land; obv-slope and volume-ratio don't.
8. **different candles differ** — fact[1] (vwap-distance) across
   the ScaleTracker round-to-2 boundary (arc 008 footnote).

Helpers in default-prelude:
- `fresh-ohlcv` — open + close + high + low controllable.
- `fresh-momentum` — obv-slope-12 + volume-accel controllable.
- `fresh-persistence` — vwap-distance controllable.
- `empty-scales` — fresh HashMap.

**Sub-fogs:**
- **2a — Persistence constructor arity.** 3-arg per candle.wat
  (hurst, autocorrelation, vwap-distance). Helper sets
  vwap-distance; zeros others.
- **2b — Momentum constructor arity.** 12-arg (per arc 013).
  Helper sets obv-slope-12 + volume-accel; zeros ten others.
- **2c — Test 5 (default branch).** Construct an Ohlcv with
  `high == low` so range = 0 → default 0.5 fires. Compare
  fact[2] to a Thermometer/scaled-linear of 0.5.

## Slice 3 — INSCRIPTION + doc sweep

**Status: obvious in shape** (once slices 1 – 2 land).

- `docs/arc/2026/04/014-market-flow-vocab/INSCRIPTION.md`.
  Records: K=3 first-ship, the substrate-gap-and-algebraic-
  equivalence move (durable!), the range-conditional pattern
  question (deferred), the inline `f64::abs` shape.
- `docs/rewrite-backlog.md` — Phase 2 gains "2.11 shipped" row.
- `docs/proposals/2026/04/058-ast-algebra-surface/FOUNDATION-CHANGELOG.md`
  — row documenting arc 014 + the durables.
- Task #35 marked completed.
- Lab repo commit + push.

---

## Working notes

- Opened 2026-04-24 immediately after arc 013 ship.
- Fifth cross-sub-struct, first K=3 (Momentum + Ohlcv + Persistence).
- The substrate gap on `exp` was the arc's main design call. Path
  B's algebraic equivalence preserves semantics without substrate
  cost — durable for any future "Log of exp(x)" port.
- N=10 for both log-bound Thermometers is best-current-estimate;
  empirical refinement deferred per arc 010 reflex.
