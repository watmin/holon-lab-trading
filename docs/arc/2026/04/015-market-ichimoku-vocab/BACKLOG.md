# Lab arc 015 — market/ichimoku vocab — BACKLOG

**Shape:** four slices. Zero substrate gaps. One helper extraction
(`clamp` to `vocab/shared/helpers.wat`). Second plain-Log caller
(cloud-thickness, citing arc 013).

---

## Slice 1 — extract `clamp` to shared helpers

**Status: ready.**

Extend `wat/vocab/shared/helpers.wat` with:

```scheme
(:wat::core::define
  (:trading::vocab::shared::clamp
    (v :f64) (lo :f64) (hi :f64)
    -> :f64)
  (:wat::core::if (:wat::core::< v lo) -> :f64
    lo
    (:wat::core::if (:wat::core::> v hi) -> :f64
      hi
      v)))
```

File header gains a paragraph naming `clamp` alongside `circ` +
`named-bind`. The "extract on fourth caller" trigger from arc
014's INSCRIPTION is named.

**Sub-fogs:** none expected. Pure helper define.

## Slice 2 — vocab module

**Status: ready** (after slice 1).

New file `wat/vocab/market/ichimoku.wat`:
- Loads candle.wat + ohlcv.wat + round.wat + scale-tracker.wat +
  scaled-linear.wat + shared/helpers.wat.
- Defines `:trading::vocab::market::ichimoku::encode-ichimoku-holons`
  with signature `(d :Candle::Divergence) (o :Ohlcv) (t :Candle::Trend)
  (scales :Scales) -> :VocabEmission`. Leaf-alphabetical D < O < T.
- Six atoms — emission order matches archive: cloud-position,
  cloud-thickness, tk-cross-delta, tk-spread, tenkan-dist,
  kijun-dist.
- cloud-position: nested-if with inline floor + clamp via shared
  helper, round-to-2 → scaled-linear.
- cloud-thickness: floor + round-to-4 → plain Log with bounds
  (0.0001, 0.5).
- tk-cross-delta + tk-spread + tenkan-dist + kijun-dist: clamp ±1
  + round-to-2 → scaled-linear.

Wiring: `wat/main.wat` gains a load line for `vocab/market/ichimoku.wat`.

**Sub-fogs:**
- **2a — cloud-thickness floor preservation.** round-to-4 keeps
  0.0001 → 0.0001 (matches arc 013 atr-ratio precedent).
- **2b — cloud-position nested compute.** Two branches with
  different denominators; inner floor for the cloud-width-positive
  branch. Inline let* binding for the inner branch's intermediate
  values.

## Slice 3 — tests

**Status: obvious in shape** (once slices 1 – 2 land).

New file `wat-tests/vocab/market/ichimoku.wat`. Eight tests:

1. **count** — 6 holons.
2. **cloud-position above-saturated** — close above cloud_top by
   wide margin → clamp pushes to +1.0 → scaled-linear shape.
3. **cloud-position collapsed-cloud branch** — cloud_width = 0 →
   else-branch fires with denominator `close × 0.01`.
4. **cloud-thickness plain-Log shape** — fact[1], `Log` form,
   bounds (0.0001, 0.5).
5. **cloud-thickness floor** — input 0.0 → floor 0.0001 →
   round-to-4 0.0001 → Log 0.0001 0.0001 0.5.
6. **tk-spread shape** — fact[3], cross-Ohlcv compute clamp ±1.
7. **scales accumulate 5 entries** — five scaled-linear; cloud-
   thickness's plain Log doesn't touch.
8. **different candles differ** — fact[0] (cloud-position) across
   the ScaleTracker round-to-2 boundary (arc 008 footnote).

Helpers in default-prelude:
- `fresh-ohlcv` — close controllable.
- `fresh-divergence` — tk-cross-delta controllable.
- `fresh-trend` — sma20, sma50, sma200, tenkan-sen, kijun-sen,
  cloud-top, cloud-bottom controllable.
- `empty-scales` — fresh HashMap.

**Sub-fogs:**
- **3a — Trend constructor arity.** 7-arg per arc 013 momentum.
- **3b — Divergence constructor arity.** 4-arg (rsi-divergence-bull,
  rsi-divergence-bear, tk-cross-delta, stoch-cross-delta).

## Slice 4 — INSCRIPTION + doc sweep

**Status: obvious in shape** (once slices 1 – 3 land).

- `docs/arc/2026/04/015-market-ichimoku-vocab/INSCRIPTION.md`.
  Records the `clamp` extraction (with the specific count: 6
  callers), the second plain-Log caller (cloud-thickness), the
  nested-if cloud-position shape, the deferred sweep of arc 009.
- `docs/rewrite-backlog.md` — Phase 2 gains "2.12 shipped" row.
- `docs/proposals/2026/04/058-ast-algebra-surface/FOUNDATION-CHANGELOG.md`
  — row documenting arc 015.
- Task #36 marked completed.
- Lab repo commit + push.

---

## Working notes

- Opened 2026-04-24 immediately after arc 014.
- K=3 (Divergence + Ohlcv + Trend) — second K=3 module.
- The clamp extraction is the arc's main durable; the rest is
  mechanical port. Future vocab arcs use `:trading::vocab::shared::clamp`
  rather than re-inlining the two-arm if.
- The "compute-atom helper?" question reaches its ninth caller
  across arcs (5 here + 4 in arc 013). Still inlined; the per-atom
  variation in numerator/denominator/post-processing keeps a
  shared helper from being clean. Question stays open for arc 016
  (standard.wat, heaviest).
