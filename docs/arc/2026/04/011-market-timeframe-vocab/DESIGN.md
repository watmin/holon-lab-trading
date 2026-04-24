# Lab arc 011 — market/timeframe vocab

**Status:** opened 2026-04-23. Ninth Phase-2 vocab arc. Third
cross-sub-struct port. **First Ohlcv read** in a vocab module.
**First sub-struct path mixing `Candle::*` with non-Candle types**
— surfaces a small clarification to arc 008's alphabetical rule.

**Motivation.** Port `vocab/market/timeframe.rs` (59L). Six
scaled-linear atoms describing 1h/4h trend structure and
inter-timeframe alignment. No Log, no conditional. One computed
atom that crosses both sub-structs (`tf-5m-1h-align` uses
Ohlcv's close/open AND Timeframe's tf-1h-body via a signum).

---

## Shape

Two sub-structs. Ordering decision below.

```scheme
(:trading::vocab::market::timeframe::encode-timeframe-holons
  (o :trading::types::Ohlcv)
  (t :trading::types::Candle::Timeframe)
  (scales :trading::encoding::Scales)
  -> :trading::encoding::VocabEmission)
```

Emission order follows archive:

| Pos | Atom | Source | Value | Rounding |
|---|---|---|---|---|
| 0 | `tf-1h-trend` | `:Timeframe/tf-1h-body t` | raw | **2 decimals** |
| 1 | `tf-1h-ret` | `:Timeframe/tf-1h-ret t` | raw | **4 decimals** |
| 2 | `tf-4h-trend` | `:Timeframe/tf-4h-body t` | raw | 2 decimals |
| 3 | `tf-4h-ret` | `:Timeframe/tf-4h-ret t` | raw | 4 decimals |
| 4 | `tf-agreement` | `:Timeframe/tf-agreement t` | raw | 2 decimals |
| 5 | `tf-5m-1h-align` | computed | `signum(tf-1h-body) × (close - open)/close` | 4 decimals |

---

## Clarifying arc 008's rule — alphabetical by LEAF name

Arc 008 named the cross-sub-struct signature rule as "ordered
alphabetically by the sub-struct's type name." Every prior
cross-sub-struct arc (008, 009) compared sub-structs that shared
the `:trading::types::Candle::*` prefix; leaf vs full path was
unambiguous because only the leaf differed.

Arc 011 is the first to mix `:trading::types::Ohlcv` with
`:trading::types::Candle::Timeframe`. Full-path ordering would
give `Candle::Timeframe` first (C < O); leaf ordering gives
`Ohlcv` first (O < T).

**Rule clarification: alphabetical by leaf name.** The leaf is
what a reader sees when parsing the signature — `(o :Ohlcv)
(t :Candle::Timeframe)` identifies each sub-struct by its
unqualified type. Full-path comparison would create an
invisible dependency on where the struct happens to live in the
namespace hierarchy; leaf comparison is stable under future
namespace reorganization.

This is a non-substantive clarification — arc 008's spirit is
preserved. The rule now reads:

> A vocab function's signature declares every sub-struct it
> reads, one parameter per sub-struct, **ordered alphabetically
> by the sub-struct's leaf (unqualified) type name**. `Scales`
> is always the last parameter before the return type.

Every future arc that mixes nested and non-nested sub-struct
paths can apply this without ambiguity.

---

## Two small shapes introduced

### Rounding to 4 decimals

The archive uses `round_to(v, 2)` in most places and
`round_to(v, 4)` for returns and alignment atoms. Our wat
substrate has:

```scheme
(:trading::encoding::round-to-2 v)  ; wat/encoding/round.wat
```

— which wraps `(:wat::core::f64::round v 2)`.

For round-to-4, three options:

**A. Inline `(:wat::core::f64::round v 4)` at each callsite.**
Three uses in this module. Verbose but locally honest.

**B. Add `round-to-4` to `wat/encoding/round.wat`.** Mirrors
round-to-2. Single extra helper.

**C. Generalize to a parameterized `round-to n v` helper.**
Most DRY. But the existing `round-to-2` is already named
specifically; changing it would cascade to every vocab caller.

**Lean: B.** Add `round-to-4` alongside `round-to-2`. Same
module (`encoding/round.wat`), same pattern. Minimum new
surface for a caller need that's already present. If a third
digit count surfaces, generalize to `round-to n v` and retire
both specific helpers.

### The signum-of-f64 computation

For `tf-5m-1h-align`, the archive computes:

```rust
let signum_1h = if c.tf_1h_body > 0.0 {
    1.0
} else if c.tf_1h_body < 0.0 {
    -1.0
} else {
    0.0
};
let five_m_ret = (c.close - c.open) / c.close;
// ...
tf_5m_1h_align: round_to(signum_1h * five_m_ret, 4),
```

Two nested `if`s returning `:f64`. One use in this module.
Inline (no helper needed — the signum would stay single-use
per stdlib-as-blueprint). Same shape as arc 009's inline
clamp, minus one comparison.

```scheme
((tf-1h-body :f64) (:Candle::Timeframe/tf-1h-body t))
((signum-1h :f64)
  (:wat::core::if (:wat::core::> tf-1h-body 0.0) -> :f64
    1.0
    (:wat::core::if (:wat::core::< tf-1h-body 0.0) -> :f64
      (:wat::core::f64::- 0.0 1.0)
      0.0)))
((close :f64) (:Ohlcv/close o))
((open :f64) (:Ohlcv/open o))
((five-m-ret :f64)
  (:wat::core::f64::/
    (:wat::core::f64::- close open) close))
((tf-5m-1h-align :f64)
  (:trading::encoding::round-to-4
    (:wat::core::f64::* signum-1h five-m-ret)))
```

Division by `close` matches archive exactly. `close=0.0` would
produce NaN; not a realistic candle scenario — we don't add
defensive handling. The archive didn't either.

---

## Why timeframe before keltner/flow/etc.

- **First Ohlcv read without a Log complication.** Keltner adds
  Ohlcv + a Log atom at the same time; flow adds three sub-
  structs + two Log atoms. Timeframe isolates the Ohlcv concern
  — if anything goes wrong with the first Ohlcv access, it
  surfaces here without the Log fog.
- **No observation pass needed.** Zero Log atoms. The arc's fog
  budget is used entirely on (a) the rule-clarification, (b)
  round-to-4, and (c) the signum-compute pattern. All small.
- **Tests the cross-sub-struct compute pattern.** `tf-5m-1h-
  align` is the first atom whose value depends on fields from
  BOTH sub-structs. Future cross-compute atoms (none known in
  remaining vocab modules, but possible) inherit the pattern.

---

## Non-goals

- **No parameterized `round-to n v`.** Wait for the third digit
  count (if ever).
- **No signum helper.** Single use in this module; inline is
  honest per stdlib-as-blueprint.
- **No defensive NaN handling.** Archive doesn't; neither do we.
  Real candle data has `close > 0`.
- **No rule rewrite for arc 008.** The leaf-name clarification
  is captured in arc 011's DESIGN + INSCRIPTION + the top-of-
  Phase-2 note in rewrite-backlog.md; arc 008's own DESIGN
  stays historical.
