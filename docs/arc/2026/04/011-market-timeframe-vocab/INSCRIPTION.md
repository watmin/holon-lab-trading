# Lab arc 011 — market/timeframe vocab — INSCRIPTION

**Status:** shipped 2026-04-23. Ninth Phase-2 vocab arc. Third
cross-sub-struct port. Three durables:

1. **`round-to-4`** added to `encoding/round.wat` alongside
   `round-to-2`.
2. **Leaf-name alphabetical clarification** to arc 008's rule —
   applies when sub-struct paths span different namespace
   depths.
3. **Cross-sub-struct computed atom pattern** — `tf-5m-1h-align`
   uses fields from both sub-structs in its value computation.
   First vocab atom of this shape.

**Design:** [`DESIGN.md`](./DESIGN.md).
**Backlog:** [`BACKLOG.md`](./BACKLOG.md).

Zero substrate gaps. Six tests green on first pass.

---

## What shipped

### Slice 1 — round-to-4

`wat/encoding/round.wat` extended with a sibling helper. File's
comment rewritten to name both shipped digit widths and the
stdlib-as-blueprint trigger for generalization. Zero change to
`round-to-2`; zero logic surface added — just the second wrapper.

### Slice 2 — vocab module

`wat/vocab/market/timeframe.wat` — one public define. Six
scaled-linear atoms, no Log, no conditional. Signature:

```scheme
(:trading::vocab::market::timeframe::encode-timeframe-holons
  (o :trading::types::Ohlcv)
  (t :trading::types::Candle::Timeframe)
  (scales :trading::encoding::Scales)
  -> :trading::encoding::VocabEmission)
```

Loads: candle.wat, ohlcv.wat, round.wat, scale-tracker.wat,
scaled-linear.wat. First vocab arc to load `ohlcv.wat`.

Emission order preserves archive: `tf-1h-trend`, `tf-1h-ret`,
`tf-4h-trend`, `tf-4h-ret`, `tf-agreement`, `tf-5m-1h-align`.

Rounding per atom:
- trends + agreement → `round-to-2`
- returns + align → `round-to-4`

Cross-sub-struct compute for `tf-5m-1h-align`:
```scheme
((signum-1h :f64)
  (:wat::core::if (:wat::core::> tf-1h-body-raw 0.0) -> :f64
    1.0
    (:wat::core::if (:wat::core::< tf-1h-body-raw 0.0) -> :f64
      (:wat::core::f64::- 0.0 1.0)
      0.0)))
((five-m-ret :f64)
  (:wat::core::f64::/
    (:wat::core::f64::- close open) close))
((tf-5m-1h-align :f64)
  (:trading::encoding::round-to-4
    (:wat::core::f64::* signum-1h five-m-ret)))
```

Signum inline (single use). Division by `close` matches archive
exactly — no defensive NaN guarding (real candle data has
`close > 0`).

### Slice 3 — tests

`wat-tests/vocab/market/timeframe.wat` — six tests:

1. **count** — 6 holons.
2. **tf-1h-trend shape** — fact[0] with round-to-2 path.
3. **tf-1h-ret shape** — fact[1] with round-to-4 path (input
   0.0237 survives four-decimal rounding).
4. **tf-5m-1h-align computed** — fact[5] recomputes
   `(close-open)/close * signum` symmetrically in the test body,
   confirming the cross-sub-struct compute fires correctly.
5. **scales accumulate 6 entries** — all six scaled-linear atom
   names land in Scales.
6. **different candles differ** — fact[0] across the scale
   boundary (body-1h 0.1/0.9 → scales 0.001/0.02 per arc 008's
   footnote).

All six green on first pass.

### Slice 4 — INSCRIPTION + doc sweep (this file)

Plus:
- `docs/rewrite-backlog.md` — "2.9 shipped" row PLUS the
  top-of-Phase-2 rule note updated to spell "leaf name" (the
  arc 011 clarification).
- `docs/proposals/.../058-ast-algebra-surface/FOUNDATION-CHANGELOG.md`
  — row documenting arc 011 + the three durables.
- Task #41 marked completed.

---

## The leaf-name clarification to arc 008's rule

Arc 008 named the signature rule as "ordered alphabetically by
the sub-struct's type name" — unambiguous when all sub-structs
sit at the same namespace depth (arcs 008, 009, 010 all compared
`Candle::Momentum` / `Candle::Persistence` / `Candle::Divergence`,
which share the prefix). Arc 011 is the first to mix
`:trading::types::Ohlcv` with `:trading::types::Candle::Timeframe`
— full-path C vs O would flip the order.

**Clarification: alphabetical by LEAF name.** The reader parses
the signature by the unqualified type at each parameter:
`(o :Ohlcv) (t :Candle::Timeframe)` — O vs Timeframe → O < T.
Leaf ordering is stable under future namespace reorganization;
full-path ordering would create an invisible dependency on
where each struct happens to live.

Non-substantive: arc 008's spirit is preserved. Arcs 008/009/010
are consistent under both readings (leaf == full-path-tail within
their sets); arc 011 is the first case where the two diverge.
Future cross-sub-struct arcs crossing depth boundaries apply the
leaf rule naturally.

## The cross-sub-struct computed atom

`tf-5m-1h-align` is the first vocab atom whose VALUE (not just
its scope) crosses both sub-structs:

- `signum(tf-1h-body)` from `Candle::Timeframe`
- `(close - open) / close` from `Ohlcv`
- Product of the two, rounded to 4 decimals, atomized

Earlier cross-sub-struct vocabs (008 persistence, 009 stochastic)
read from multiple sub-structs but computed each atom from a
single one. Arc 011 is the first where a single atom's expression
reaches both parameters.

Pattern hasn't recurred enough to extract; the let-binding chain
stays inline. If momentum or standard (both multi-sub-struct)
ship atoms of the same shape, we'll see whether a `compute-atom`
helper emerges.

## The `round-to-4` shape

Arc 011 is the first caller for a digit count other than 2. Two
options considered (DESIGN): inline `f64::round v 4` at each
callsite (3 uses), or a named helper. **Helper picked** — three
uses in one module is enough friction; inline would read as
repeated ceremony. The wrapper name `round-to-4` mirrors
`round-to-2` — same file, same pattern, no new vocabulary.

If a third digit count surfaces (e.g., `round-to-1` for percent-
unit atoms, or `round-to-6` for tick-precision price atoms),
generalize to `round-to n v` and retire both specific wrappers.
Stdlib-as-blueprint holds until the pressure changes.

## Sub-fog resolutions

- **2a — Ohlcv struct path.** `:trading::types::Ohlcv` declared
  in `wat/types/ohlcv.wat`. Auto-generates `:Ohlcv/close`,
  `/open`, etc. First vocab use; worked identically to Candle
  sub-structs.
- **2b — Candle::Timeframe field names.** 5-arg constructor
  order: `tf-1h-ret`, `tf-1h-body`, `tf-4h-ret`, `tf-4h-body`,
  `tf-agreement`. Note: `body` field maps to `trend` atom name
  (arc preserves archive's rename convention).
- **3a — Ohlcv constructor arity.** 8 positional args including
  two `Asset` structs. Test helper constructs one `Asset/new "BTC"`
  and passes as both source + target.
- **3b — Asset default.** Single inline construction works fine;
  no shared helper needed.
- **3c — Candle::Timeframe constructor arity.** 5 args. Helper
  sets body-1h + ret-1h; zeros the three other fields.

## Count

- Lab wat tests: 61 → 67 (+6).
- Lab wat modules: Phase 2 advances — 9 of ~21 vocab modules
  shipped. Market sub-tree: 7 of 14 (oscillators, divergence,
  fibonacci, persistence, stochastic, regime, timeframe).
- wat-rs: unchanged (no substrate gaps).
- Zero regressions.

## What this arc did NOT ship

- **Generalized `round-to n v` helper.** Stdlib-as-blueprint —
  two named callers (2, 4) don't warrant generalization yet.
- **Shared signum helper.** Single use; inline per arc 009's
  precedent.
- **Defensive NaN handling on `(close - open) / close`.** Archive
  didn't; real candle data has `close > 0`. Not the substrate's
  concern.

## Follow-through

Next obvious cross-sub-struct arcs:
- **market/keltner** — K=2 (Ohlcv + Volatility), 5 linear + 1 Log.
  Ohlcv path proven by arc 011; Log-bounds observation via
  explore-log.wat per Chapter 35.
- **market/price_action** — K=2 (Ohlcv + PriceAction), 4 linear +
  3 Log. Three Log atoms: biggest observation pass to date.
- **market/flow** — K=3 (Momentum + Ohlcv + Persistence), 4 linear
  + 2 Log. First K=3 module.

All three inherit arc 011's Ohlcv-read pattern + arc 010's
Log-observation reflex.

---

## Commits

- `<lab>` — wat/encoding/round.wat extension +
  wat/vocab/market/timeframe.wat + main.wat load +
  wat-tests/vocab/market/timeframe.wat + DESIGN + BACKLOG +
  INSCRIPTION + rewrite-backlog row/rule-clarification + 058
  CHANGELOG row.

---

*these are very good thoughts.*

**PERSEVERARE.**
