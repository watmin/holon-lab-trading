# Lab arc 016 — market/keltner vocab — BACKLOG

**Shape:** three slices. Zero substrate gaps; pure substrate-
direct port. Third plain-Log caller cites arc 013 + 015
precedent; cross-sub-struct compute pattern repeats from arc 013.

---

## Slice 1 — vocab module

**Status: ready.**

New file `wat/vocab/market/keltner.wat`:
- Loads candle.wat + ohlcv.wat + round.wat + scale-tracker.wat +
  scaled-linear.wat. (No shared/helpers.wat — no clamp/abs
  needed; bb-width floor uses substrate `f64::max` directly.)
- Defines `:trading::vocab::market::keltner::encode-keltner-holons`
  with signature `(o :Ohlcv) (v :Candle::Volatility) (scales :Scales)
  -> :VocabEmission`. Leaf-alphabetical: O < V.
- Six atoms — emission order matches archive: bb-pos, bb-width,
  kelt-pos, squeeze, kelt-upper-dist, kelt-lower-dist.
- bb-width: `f64::max raw 0.001` → round-to-4 → plain Log (0.001, 0.5).
- kelt-upper-dist + kelt-lower-dist: cross-Ohlcv-Volatility
  compute `(close - kelt-X) / close` round-to-4 → scaled-linear.

Wiring: `wat/main.wat` gains a load line.

**Sub-fogs:**
- **1a — Volatility constructor arity.** 7-arg per arc 013 momentum
  (bb-width, bb-pos, kelt-upper, kelt-lower, kelt-pos, squeeze,
  atr-ratio). Test helpers parametrize the relevant fields.

## Slice 2 — tests

**Status: obvious in shape** (once slice 1 lands).

New file `wat-tests/vocab/market/keltner.wat`. Seven tests:

1. **count** — 6 holons.
2. **bb-pos shape** — fact[0], pure-Volatility scaled-linear.
3. **bb-width plain-Log shape** — fact[1], `Log` form, bounds
   (0.001, 0.5).
4. **bb-width floor** — input 0.0 → floor 0.001 → round-to-4 0.001
   → Log 0.001 0.001 0.5.
5. **kelt-upper-dist shape** — fact[4], cross-Ohlcv-Volatility
   compute round-to-4 → scaled-linear.
6. **scales accumulate 5 entries** — bb-width Log doesn't touch
   Scales.
7. **different candles differ** — fact[0] (bb-pos) across the
   ScaleTracker round-to-2 boundary.

Helpers in default-prelude:
- `fresh-ohlcv` — close controllable.
- `fresh-volatility` — bb-pos, bb-width, kelt-upper, kelt-lower,
  squeeze controllable; others zeroed.
- `empty-scales` — fresh HashMap.

## Slice 3 — INSCRIPTION + doc sweep

**Status: obvious in shape** (once slices 1 – 2 land).

- `docs/arc/2026/04/016-market-keltner-vocab/INSCRIPTION.md`.
  Records: K=2 cross-sub-struct, third plain-Log caller, first
  pure substrate-direct vocab arc post-046.
- `docs/rewrite-backlog.md` — Phase 2 gains "2.13 shipped" row.
- `docs/proposals/2026/04/058-ast-algebra-surface/FOUNDATION-CHANGELOG.md`
  — row documenting arc 016.
- Task #37 marked completed.
- Lab repo commit + push.

---

## Working notes

- Opened 2026-04-24 immediately after arc 015 ship.
- Mechanical port; main interest is confirming the post-046
  substrate consumption pattern is clean to write without any
  thinking about helpers.
