# Lab arc 017 — market/price-action vocab — BACKLOG

**Shape:** three slices. Zero substrate gaps; substrate-direct
port. Three Log atoms across two domain shapes. First lab
`f64::min` consumer.

---

## Slice 1 — vocab module

**Status: ready.**

New file `wat/vocab/market/price-action.wat`:
- Loads candle.wat + ohlcv.wat + round.wat + scale-tracker.wat +
  scaled-linear.wat. (No shared/helpers.wat.)
- Defines `:trading::vocab::market::price-action::encode-price-action-holons`
  with signature `(o :Ohlcv) (p :Candle::PriceAction) (scales :Scales)
  -> :VocabEmission`. Leaf-alphabetical: O < P.
- 7 atoms, archive emission order: range-ratio, gap,
  consecutive-up, consecutive-down, body-ratio-pa, upper-wick,
  lower-wick.

Substrate primitives used:
- `:wat::core::f64::max` for range-ratio floor + consecutive-X
  floor + `max(open, close)` (upper-wick numerator).
- `:wat::core::f64::min` for `min(open, close)` (lower-wick
  numerator) — **first lab caller**.
- `:wat::core::f64::abs` for `abs(close - open)` (body-ratio-pa
  numerator) — second lab caller after arc 015 flow migration.
- `:wat::core::f64::clamp` for gap atom's pre-encoding clamp ±1.

Wiring: `wat/main.wat` gains a load line (`vocab/market/price-action.wat`).

**Sub-fogs:**
- **1a — PriceAction constructor arity.** 4-arg per candle.wat
  (range-ratio, gap, consecutive-up, consecutive-down).
- **1b — File name.** `price-action.wat` (kebab-case wat
  convention) for archive's `price_action.rs`. Matches the
  `:trading::vocab::market::price-action::*` namespace.
- **1c — Range-conditional repeats from flow.wat.** Compute
  `range` once via `(:Ohlcv/high) - (:Ohlcv/low)`, guard
  `range-positive` once. Three branches, all default 0.0.

## Slice 2 — tests

**Status: obvious in shape** (once slice 1 lands).

New file `wat-tests/vocab/market/price-action.wat`. Eight tests:

1. **count** — 7 holons.
2. **range-ratio plain-Log shape** — fact[0], `Log` form, bounds
   (0.001, 0.5).
3. **gap shape with clamp** — fact[1], `(gap / 0.05)` clamped to
   ±1, round-to-4 → scaled-linear. Test with input that triggers
   clamp (e.g., gap = 0.10 → 0.10/0.05 = 2.0 → clamp = 1.0).
4. **consecutive-up plain-Log shape** — fact[2], `Log (1+n) 1.0
   20.0` form. Verify the new bounds.
5. **consecutive-up floor** — input -2 → `1 + -2 = -1` → max with
   1.0 → 1.0 → round-to-2 1.0 → Log 1.0 1.0 20.0.
6. **body-ratio-pa shape (range > 0)** — fact[4], cross-Ohlcv
   compute via abs + range, round-to-2.
7. **upper-wick (range > 0)** — fact[5], `(high - max(open, close))
   / range`. Tests `f64::max` use.
8. **lower-wick (range > 0)** — fact[6], `(min(open, close) - low)
   / range`. Tests **first f64::min consumer**.

(Could add a 9th for "scales accumulate 4 entries" — gap +
body-ratio-pa + upper-wick + lower-wick = 4 scaled-linear; the
3 Logs don't touch. Decide during implementation.)

Helpers in default-prelude:
- `fresh-ohlcv` — open + high + low + close controllable.
- `fresh-price-action` — all 4 fields controllable.
- `empty-scales`.

## Slice 3 — INSCRIPTION + doc sweep

**Status: obvious in shape** (once slices 1 – 2 land).

- `docs/arc/2026/04/017-market-price-action-vocab/INSCRIPTION.md`.
  Records: 4th plain-Log caller in fraction-of-price family;
  5th + 6th plain-Log callers in NEW count-starting-at-1
  family; first f64::min consumer; second abs consumer; range-
  conditional pattern recurrence; gap atom's pre-clamp shape.
- `docs/rewrite-backlog.md` — Phase 2 gains "2.14 shipped" row.
- `docs/proposals/2026/04/058-ast-algebra-surface/FOUNDATION-CHANGELOG.md`
  — row documenting arc 017.
- Task #38 marked completed.
- Lab repo commit + push.
