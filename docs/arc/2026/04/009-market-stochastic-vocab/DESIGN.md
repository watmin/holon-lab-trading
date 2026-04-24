# Lab arc 009 — market/stochastic vocab

**Status:** opened 2026-04-23. Seventh Phase-2 vocab arc.
Second cross-sub-struct port — ships under arc 008's signature
rule without re-deriving.

**Motivation.** Port `vocab/market/stochastic.rs` (36L). Four
scaled-linear atoms — `stoch-k`, `stoch-d`, `stoch-kd-spread`,
`stoch-cross-delta` — from Candle::Momentum and
Candle::Divergence. No Log, no conditional. Same shape class as
arc 008 (persistence): K=2, all scaled-linear, zero fog.

---

## Shape

Two sub-structs (D < M alphabetically):

```scheme
(:trading::vocab::market::stochastic::encode-stochastic-holons
  (d :trading::types::Candle::Divergence)
  (m :trading::types::Candle::Momentum)
  (scales :trading::encoding::Scales)
  -> :trading::encoding::VocabEmission)
```

Emission order follows archive: k, d, kd-spread, cross-delta.

| Position | Atom | Source field | Value |
|---|---|---|---|
| 0 | `stoch-k` | `:Momentum/stoch-k m` | `round-to-2(stoch-k / 100.0)` |
| 1 | `stoch-d` | `:Momentum/stoch-d m` | `round-to-2(stoch-d / 100.0)` |
| 2 | `stoch-kd-spread` | computed from m | `round-to-2((stoch-k - stoch-d) / 100.0)` |
| 3 | `stoch-cross-delta` | `:Divergence/stoch-cross-delta d` | `round-to-2(clamp(x, -1, 1))` |

---

## One new shape in this arc — inline clamp

The archive uses `.max(-1.0).min(1.0)` on `stoch-cross-delta` —
clamp to `[-1, 1]`. Wat has no `clamp` primitive in
`:wat::core::*` (as of today's audit). Two options:

- **Inline clamp** using two nested `if`s. Four lines of let-
  bindings per use.
- **File-private helper** `clamp-to-unit` — same shape as arc 001's
  `circ` / arc 006's `maybe-scaled-linear`.

**Lean: inline.** Only one use in this module. Stdlib-as-
blueprint: wait for a second caller before extracting. If
another port surfaces a second clamp site, extraction follows
arc 006's playbook (file-private first, then shared/helpers.wat
after the second caller lands).

Inline shape:

```scheme
((raw :f64) (:trading::types::Candle::Divergence/stoch-cross-delta d))
((clamped :f64)
  (:wat::core::if (:wat::core::>= raw 1.0) -> :f64
    1.0
    (:wat::core::if (:wat::core::<= raw -1.0) -> :f64
      (:wat::core::f64::- 0.0 1.0)
      raw)))
((stoch-cross-delta :f64) (:trading::encoding::round-to-2 clamped))
```

---

## Why stochastic before regime/keltner

- **Zero new fog.** Arc 008 named the cross-sub-struct rule;
  arc 009 is the first inheritance — proving the rule works
  without substrate change.
- **No Log bounds** — unlike regime, keltner, ichimoku,
  price_action, flow, standard, momentum.
- **No Ohlcv read** — that's keltner's or timeframe's first
  exercise. Stochastic stays within the indicator-family
  sub-structs.
- **Clamp is small + opt-in** — if the inline shape proves
  ugly, arc 010 or later extracts to shared/helpers.wat.

---

## Non-goals

- **No clamp primitive in `:wat::core::*`.** Inline is fine for
  K=1 callers. Extract when K=2.
- **No emission-order alphabetization.** Keeps archive's
  semantic order (k before d before spread before cross-delta —
  the crossover logic reads left to right).
- **No distinguishability test rewrite.** Arc 008's scale-
  collision footnote applies — this arc's test uses values
  across the scale-rounding boundary from the start.
