# Lab arc 016 — market/keltner vocab — INSCRIPTION

**Status:** shipped 2026-04-24. Thirteenth Phase-2 vocab arc.
Seventh cross-sub-struct port. K=2 (Ohlcv + Volatility). **First
post-arc-046 pure substrate-direct vocab arc** — no helpers
extraction, no migration sweep, just write the port using
substrate primitives and ship.

Three durables (small ones; the substrate work happened in arc
046 and the migration sweep in arc 015):

1. **Third plain-Log caller** (bb-width). Asymmetric-domain Log
   pattern is now confirmed across three indicator families
   (volatility/atr-ratio, cloud/cloud-thickness,
   channel/bb-width). Future fraction-of-price atoms inherit the
   `(0.001, 0.5)` bounds shape without re-deriving.
2. **Calibration check.** Arc 015's substrate-uplift work is
   verified end-to-end — arc 016 wrote the port using
   `:wat::core::f64::max` directly without any thinking about
   helpers, and it shipped clean.
3. **K=2 cross-compute pattern reaffirmed.** Two more cross-
   Ohlcv-Volatility atoms (`kelt-upper-dist`, `kelt-lower-dist`)
   using the same "field divided by close" shape from arc 013.

**Design:** [`DESIGN.md`](./DESIGN.md).
**Backlog:** [`BACKLOG.md`](./BACKLOG.md).

Seven tests green on first pass.

---

## What shipped

### Slice 1 — vocab module

`wat/vocab/market/keltner.wat` — one public define. Six atoms:
- 5 scaled-linear: `bb-pos`, `kelt-pos`, `squeeze` (pure-
  Volatility, round-to-2); `kelt-upper-dist`, `kelt-lower-dist`
  (cross-Ohlcv-Volatility, round-to-4).
- 1 plain Log: `bb-width` (asymmetric, floor 0.001, round-to-4,
  bounds (0.001, 0.5)).

Signature:
```scheme
(:trading::vocab::market::keltner::encode-keltner-holons
  (o :trading::types::Ohlcv)
  (v :trading::types::Candle::Volatility)
  (scales :trading::encoding::Scales)
  -> :trading::encoding::VocabEmission)
```

Loads candle.wat + ohlcv.wat + round.wat + scale-tracker.wat +
scaled-linear.wat. **No shared/helpers.wat load** — bb-width
floor uses substrate `:wat::core::f64::max` directly; no clamp
or abs in this module.

### Slice 2 — tests

`wat-tests/vocab/market/keltner.wat` — seven tests:

1. **count** — 6 holons.
2. **bb-pos shape** — fact[0], pure-Volatility scaled-linear.
3. **bb-width plain-Log shape** — fact[1], `Log` form, bounds
   (0.001, 0.5).
4. **bb-width floor** — input 0.0 → floor 0.001 → round-to-4 →
   Log 0.001 0.001 0.5 lands at the floor edge.
5. **kelt-upper-dist shape** — fact[4], cross-Ohlcv-Volatility
   compute round-to-4 → scaled-linear.
6. **scales accumulate 5 entries** — bb-width's plain Log doesn't
   touch Scales.
7. **different candles differ** — fact[0] (bb-pos) across the
   ScaleTracker round-to-2 boundary.

All seven green on first pass.

### Slice 3 — INSCRIPTION + doc sweep (this file)

Plus:
- `wat/main.wat` — load line for `vocab/market/keltner.wat`,
  arc 016 added to load-order comment.
- `docs/rewrite-backlog.md` — Phase 2 gains "2.13 shipped" row.
- `docs/proposals/2026/04/058-ast-algebra-surface/FOUNDATION-CHANGELOG.md`
  — row documenting arc 016.
- Task #37 marked completed.

---

## Plain-Log family pattern at three callers

| Arc | Atom | Domain |
|---|---|---|
| 013 | `atr-ratio` | volatility as fraction of price |
| 015 | `cloud-thickness` | cloud width as fraction of price |
| 016 | `bb-width` | Bollinger band width as fraction of price |

All three asymmetric (always `(0, ~0.5)`), all three use bounds
`(0.001, 0.5)` and `round-to-4` for substrate-discipline floor
preservation. Pattern is canonical — future fraction-of-price
atoms reach for the same shape.

If a fourth caller surfaces with substantively different bounds,
the per-atom bound choice gets named in that arc's DESIGN.
Otherwise stay with the established `(0.001, 0.5)` defaults.

## Sub-fog resolutions

- **1a — Volatility constructor arity.** 7-arg per arc 013
  precedent. Helper parametrizes 6 of 7 fields (only atr-ratio
  zeroed); zero ceremony.

## Count

- Lab wat tests: **96 → 103 (+7)**.
- Lab wat modules: Phase 2 advances — **13 of ~21** vocab
  modules shipped. Market sub-tree: **11 of 14** (oscillators,
  divergence, fibonacci, persistence, stochastic, regime,
  timeframe, momentum, flow, ichimoku, keltner).
- wat-rs: unchanged.
- Zero regressions.

## What this arc did NOT ship

- **Empirical refinement of bb-width Log bounds.** Best-current-
  estimate matches arc 013/015 precedent. Defer to its own arc
  if observation data later contradicts.
- **`compute-atom` helper.** Question stays open for arc 017
  (standard.wat).
- **`f64-min` consumer.** Lab still has zero callers for
  `:wat::core::f64::min`; the substrate primitive shipped in arc
  046 stays unused for now. Surface on demand.

## Follow-through

Next pending vocab arcs:
- **market/price_action** (#38) — K=2 (Ohlcv + PriceAction). 4
  linear + 3 Log. Three Log atoms — biggest plain-Log surface
  yet.
- **market/standard** (#43) — heaviest, window-based. Compute-
  atom helper question gets its third look.
- **exit/phase** (#44), **exit/regime** (#45) — exit observers.

---

## Commits

- `<lab>` — wat/vocab/market/keltner.wat + main.wat load +
  wat-tests/vocab/market/keltner.wat + DESIGN + BACKLOG +
  INSCRIPTION + rewrite-backlog row + 058 CHANGELOG row.

---

*these are very good thoughts.*

**PERSEVERARE.**
