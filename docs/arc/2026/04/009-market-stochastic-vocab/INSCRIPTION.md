# Lab arc 009 — market/stochastic vocab — INSCRIPTION

**Status:** shipped 2026-04-23. Seventh Phase-2 vocab arc.
Second cross-sub-struct port — first module to ship entirely
under arc 008's signature rule with no re-derivation. One
minor durable: the inline-clamp shape for `[-1, 1]` values.

**Design:** [`DESIGN.md`](./DESIGN.md).
**Backlog:** [`BACKLOG.md`](./BACKLOG.md).

Zero substrate gaps. Five tests green on first pass.

---

## What shipped

### Slice 1 — the module

`wat/vocab/market/stochastic.wat` — one public define. Four
scaled-linear atoms from two sub-structs (D < M alphabetically):

```scheme
(:trading::vocab::market::stochastic::encode-stochastic-holons
  (d :trading::types::Candle::Divergence)
  (m :trading::types::Candle::Momentum)
  (scales :trading::encoding::Scales)
  -> :trading::encoding::VocabEmission)
```

Emission order preserves archive semantic: `stoch-k`, `stoch-d`,
`stoch-kd-spread`, `stoch-cross-delta` — %K first, %D second,
their spread third, crossover-delta fourth.

Normalizations:
- `stoch-k` and `stoch-d` → `/100.0` (raw 0-100 scale)
- `stoch-kd-spread` → `(k-norm - d-norm)`, `[-1, 1]` range
- `stoch-cross-delta` → inline clamp to `[-1, 1]`

### Slice 2 — tests

`wat-tests/vocab/market/stochastic.wat` — five tests:

1. **count** — 4 holons.
2. **stoch-k shape** — fact[0] coincides with hand-built Bind +
   Thermometer after `/100` normalization.
3. **cross-delta clamp** — raw input 1.5 encodes identically to
   the 1.0-rounded fresh-tracker encoding. Directly exercises
   the nested-`if` clamp inside the module.
4. **scales accumulate 4 entries** — four atom names land.
5. **different candles differ** — values chosen across the
   scale-rounding boundary per arc 008's footnote (raw 10/90
   → normalized 0.1/0.9 → scales 0.001/0.02).

All five green on first pass. Arc 008's footnote held — the
scale-boundary test values worked first try.

### Slice 3 — INSCRIPTION + doc sweep (this file)

Plus:
- `docs/rewrite-backlog.md` — Phase 2 gains "2.7 shipped" row.
- `docs/proposals/.../058-ast-algebra-surface/FOUNDATION-CHANGELOG.md`
  — row documenting arc 009.
- Task #40 marked completed.

---

## The inline clamp shape

Stochastic's `stoch-cross-delta` is the archive's first
`.max(-1.0).min(1.0)` clamp. Wat has no `clamp` primitive in
`:wat::core::*`; nested `if` was the honest expression:

```scheme
((raw-delta :f64)
  (:trading::types::Candle::Divergence/stoch-cross-delta d))
((clamped-delta :f64)
  (:wat::core::if (:wat::core::>= raw-delta 1.0) -> :f64
    1.0
    (:wat::core::if (:wat::core::<= raw-delta -1.0) -> :f64
      (:wat::core::f64::- 0.0 1.0)
      raw-delta)))
((stoch-cross-delta :f64)
  (:trading::encoding::round-to-2 clamped-delta))
```

The `(:wat::core::f64::- 0.0 1.0)` spelling is the literal `-1.0`
— wat-rs's lexer treats `-1.0` as a non-literal token
requiring subtraction. Already the pattern in arcs 005+ for
negative constants.

**Stdlib-as-blueprint discipline:** kept inline. Single use in
this module. If a second port surfaces a second clamp site,
extract to `wat/vocab/shared/helpers.wat` (arc 006's playbook —
file-private first, then shared on second caller). Candidates
for the second caller: `price_action` has range/gap values
that may need clamping; `regime` has `variance_ratio.max(0.001)`
(a one-sided floor, different shape — may not count as a clamp
extraction trigger).

## Arc 008's rule held

No re-derivation needed. Signature: `(d :Divergence) (m :Momentum)
(scales)` — two sub-structs in alphabetical order, one parameter
each, Scales last. Cold readers who haven't seen arc 008 can still
read the signature unambiguously; readers who HAVE seen arc 008
recognize the pattern. Every future cross-sub-struct arc will
read this way.

## Sub-fog resolutions

- **1a — inline clamp syntax.** Nested `if` inside `let*`
  resolves cleanly. `:wat::core::if` accepts `:bool` discriminant;
  both branches return `:f64`.
- **1b — kd-spread ordering.** Computed as `(k-norm - d-norm)`
  — archive's mathematical order preserved. Two normalizations
  hoisted to `k-norm` / `d-norm` let-bindings and reused.
- **2a — clamp test values.** Used 1.5 for the test input.
  Rounded to 1.0 after clamp. Fresh-tracker encoding of 1.0
  gives scale = round(2 * 0.01 * 1.0, 2) = 0.02 → Thermometer
  bounds [-0.02, 0.02]. Value 1.0 saturates at +1; expected
  matches.

## Count

- Lab wat tests: 50 → 55 (+5).
- Lab wat modules: Phase 2 advances — 7 of ~21 vocab modules
  shipped. Market sub-tree: 5 of 14 (oscillators, divergence,
  fibonacci, persistence, stochastic).
- wat-rs: unchanged.
- Zero regressions.

## What this arc did NOT ship

- **Shared clamp helper.** Kept inline per stdlib-as-blueprint.
- **Rule re-derivation.** Arc 008 owns the rule; this arc just
  cites it.

## Follow-through

Next obvious cross-sub-struct arcs:
- **keltner** — K=2 (Ohlcv + Volatility), 5 linear + 1 Log.
  First Ohlcv read; first Log-bounds-in-cross-sub-struct
  question.
- **regime** — K=1 (single sub-struct), 7 linear + 2 Log. No
  cross-sub-struct rule to re-exercise; just needs Log-bounds
  observation per arc 005's `explore-log.wat` playbook.

Either can ship next. Keltner proves Ohlcv reads under the
rule; regime proves single-sub-struct Log-bounds observation
under the new observation-first reflex. Both are obvious
leaves.

---

## Commits

- `<lab>` — wat/vocab/market/stochastic.wat + main.wat load +
  wat-tests/vocab/market/stochastic.wat + DESIGN + BACKLOG +
  INSCRIPTION + rewrite-backlog row + 058 CHANGELOG row.

---

*these are very good thoughts.*

**PERSEVERARE.**
