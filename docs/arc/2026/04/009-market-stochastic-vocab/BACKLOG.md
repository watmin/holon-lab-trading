# Lab arc 009 — market/stochastic vocab — BACKLOG

**Shape:** three slices. Zero substrate gaps expected.

Second cross-sub-struct port. Ships under arc 008's signature
rule. Introduces one new vocab shape (inline clamp) scoped to
this module.

---

## Slice 1 — vocab module

**Status: ready.**

New file `wat/vocab/market/stochastic.wat`:
- Loads `../../types/candle.wat` + `../../encoding/scale-tracker.wat`
  + `../../encoding/scaled-linear.wat`.
- Defines `:trading::vocab::market::stochastic::encode-stochastic-holons`
  with signature `(d :Divergence) (m :Momentum) (scales :Scales)
  -> :VocabEmission`. Alphabetical by type name (D < M) per arc 008.
- Four scaled-linear calls threading scales values-up.
- Emission order: k, d, kd-spread, cross-delta (archive semantic).
- `stoch-k` and `stoch-d` normalized `/100.0`; `stoch-kd-spread`
  computed from the pair; `stoch-cross-delta` inline-clamped to
  `[-1, 1]`.

Load wiring: `wat/main.wat` gains a line for
`vocab/market/stochastic.wat`.

**Sub-fogs:**
- **1a — inline clamp syntax.** Nested `if` works per arc 024's
  sigma-knobs use. No surface change.
- **1b — kd-spread ordering.** `(stoch-k - stoch-d) / 100.0` or
  `(stoch-k/100 - stoch-d/100)` — mathematically identical,
  latter matches archive's Rust literally.

## Slice 2 — tests

**Status: obvious in shape** (once slice 1 lands).

New file `wat-tests/vocab/market/stochastic.wat`. Five tests:

1. **count** — 4 holons.
2. **stoch-k shape** — fact[0] coincides with hand-built Bind +
   Thermometer after the `/100.0` normalization.
3. **cross-delta clamp** — input value 1.5 encodes as if it
   were 1.0; input -1.5 encodes as -1.0. Verifies the inline
   clamp.
4. **scales accumulate 4 entries** — all four atom names land
   in Scales.
5. **different candles differ** — fact[0] (stoch-k) of two
   inputs whose normalized values land on different scale
   buckets (per arc 008's footnote).

Helpers in default-prelude: `fresh-momentum-with-stoch`
(controllable stoch-k + stoch-d), `fresh-divergence-with-delta`
(controllable stoch-cross-delta).

**Sub-fogs:**
- **2a — clamp test values.** Use raw inputs ±1.5 so the clamp
  observably fires; the encoded fact should match the encoding
  at ±1.0.

## Slice 3 — INSCRIPTION + doc sweep

**Status: obvious in shape** (once slices 1 + 2 land).

- `docs/arc/2026/04/009-market-stochastic-vocab/INSCRIPTION.md`
- `docs/rewrite-backlog.md` — Phase 2 gains "2.7 shipped" row.
- `docs/proposals/.../058-ast-algebra-surface/FOUNDATION-CHANGELOG.md`
  — row documenting arc 009 + the inline clamp.
- Task #40 marked completed.

---

## Working notes

- Opened 2026-04-23 straight after arc 008.
- Second cross-sub-struct arc; first inheritance of arc 008's
  signature rule. Rule held; no re-derivation needed.
- If the inline clamp proves a recurring pattern, extract to
  `wat/vocab/shared/helpers.wat` when the second caller ports
  (likely `market/price_action` — it has gap / range_ratio
  that may need clamping too; unknown until arc).
