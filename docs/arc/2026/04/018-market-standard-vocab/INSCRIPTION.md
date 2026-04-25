# Lab arc 018 — market/standard vocab — INSCRIPTION

**Status:** shipped 2026-04-24. Fifteenth Phase-2 vocab arc.
**Last market sub-tree vocab — market sub-tree complete (13 of
13).** Heaviest port + first window-based vocab. Bootstrapped
two wat-rs substrate uplifts (arcs 047 + 048) before completing.

The arc surfaced FOUR substrate gaps during sketch:
- `last`, `find-last-index`, `f64::max-of`, `f64::min-of` (arc 047)
- `first`-on-Vec returning T-with-error vs Option<T> (arc 047)
- User-enum value construction (arc 048 — Phase fields)

Each gap landed in its own substrate arc, then arc 018 resumed
with substrate-direct calls. The "natural-form-then-promote"
rhythm at full strength.

---

## What shipped

### The vocab

`wat/vocab/market/standard.wat` — eight atoms describing
window-level market context:

| Pos | Atom | Source | Encoding |
|---|---|---|---|
| 0 | `since-rsi-extreme` | window iter on rsi > 80 \|\| < 20 | plain Log (1.0, 100.0) |
| 1 | `since-vol-spike` | window iter on volume-accel > 2 | plain Log (1.0, 100.0) |
| 2 | `since-large-move` | window iter on \|roc-1\| > 0.02 | plain Log (1.0, 100.0) |
| 3 | `dist-from-high` | (close - max(high)) / close | scaled-linear |
| 4 | `dist-from-low` | (close - min(low)) / close | scaled-linear |
| 5 | `dist-from-midpoint` | (close - mid) / close | scaled-linear |
| 6 | `dist-from-sma200` | (close - sma200) / close | scaled-linear |
| 7 | `session-depth` | 1 + window-len | plain Log (1.0, 100.0) |

**Signature departs from the K-sub-struct rule** — window vocabs
take `Vec<Candle>` directly. Single-candle vocabs continue to
use the cross-sub-struct rule from arc 008/011. Window vocabs
are a different class.

```scheme
(:trading::vocab::market::standard::encode-standard-holons
  (window :Vec<trading::types::Candle>)
  (scales :trading::encoding::Scales)
  -> :trading::encoding::VocabEmission)
```

**Empty-window guard** — returns `(tuple empty-vec scales)` when
the window is empty (mirrors archive's `Vec::new()` return).

### Substrate primitives consumed (full arc 047 + arc 048 set)

| Primitive | Arc | Usage |
|---|---|---|
| `:wat::core::last` | 047 | `current = (last window)` (with Option unwrap) |
| `:wat::core::find-last-index` | 047 | three since-X computations |
| `:wat::core::f64::max-of` | 047 | window-high aggregate |
| `:wat::core::f64::min-of` | 047 | window-low aggregate |
| `:wat::core::f64::max` | 046 | `since-X = max(1, n - last-idx)` floor |
| `:wat::core::f64::abs` | 046 | `\|roc-1\|` predicate |
| `:trading::types::PhaseLabel::Transition` | 048 | empty-window unreachable Phase sentinel |
| `:trading::types::PhaseDirection::None` | 048 | same |

The empty-window unreachable branch builds a default Candle so
the type checker has a value (the doubly-unreachable `:None` arm
of `(last window)` after the explicit empty-guard). Arc 048's
user-enum support makes Phase construction work.

### Tests

`wat-tests/vocab/market/standard.wat` — eight tests:

1. **count for non-empty window** — 8 holons.
2. **empty window emits zero holons** — empty-window guard.
3. **since-rsi-extreme finds extreme** — RSI=85 in 2-candle window.
4. **since-rsi-extreme defaults to n** — None case (no match).
5. **dist-from-high shape** — cross-Ohlcv compute.
6. **session-depth Log shape** — count family bounds.
7. **scales accumulate 4 entries** — four scaled-linear; four Log
   atoms don't touch.
8. **since-vol-spike finds spike** — vol > 2.0 detection.

All eight green on first pass after substrate landed.

### What this arc bootstrapped (substrate work)

The market/standard sketch surfaced gaps that became their own
arcs:

**wat-rs arc 047 — Vec accessors / aggregates return Option**.
- Polymorphism shift on `first/second/third` for Vec inputs
  (Vec branch returns `Option<T>`; Tuple unchanged)
- Four new natural-form primitives: `last`, `find-last-index`,
  `f64::max-of`, `f64::min-of`
- Sweep of 7 wat-rs callsites + ~10 lab callsites

**wat-rs arc 048 — User-defined enum value support**.
- `Value::Enum` + `EnumValue` generic representation
- `:Enum::Variant` (unit) + `(:Enum::Variant args)` (tagged)
  construction syntax (mirrors Rust)
- Match pattern extension for user enums (exhaustiveness +
  variant-belongs-to-scrutinee + binder arity all checked)
- Lab migration of 10 enum decls to PascalCase

Each substrate arc shipped before arc 018 resumed. The
"natural-form-then-promote" rhythm: write the natural form,
discover the gap, fill the gap, ship the caller.

---

## The plain-Log family — three shapes now

| Family | Bounds | Round | Domain | Callers |
|---|---|---|---|---|
| Fraction-of-price | `(0.001, 0.5)` | round-to-4 | always `(0, ~0.5)` | atr-ratio (013), cloud-thickness (015), bb-width (016), range-ratio (017) |
| Count-starting-at-1 (small window) | `(1.0, 20.0)` | round-to-2 | streak count, ≤20 | consecutive-up/down (017) |
| Count-starting-at-1 (full window) | `(1.0, 100.0)` | round-to-2 | window-spanning count, ≤100 | since-rsi/vol/large (018), session-depth (018) |

Standard.wat extends the count family to a wider bound suiting
typical 100-candle observer windows. Same shape, different
upper.

## Window-vocab signature departure

Arc 008/011's K-sub-struct rule applies to single-candle vocabs:
each vocab declares specifically the sub-structs it reads. Window
vocabs are categorically different — they iterate over multiple
candles, sometimes reading multiple sub-struct fields per
candle. Decomposition into per-candle sub-struct slices is
impractical.

**Rule recap:** single-candle vocabs use the K-sub-struct
signature; window vocabs take `Vec<Candle>` directly. Two
distinct classes. Future window vocabs (in exit/* tree?) inherit
the Vec<Candle> shape; their arc DESIGN names the class.

## Sub-fog resolutions

- **1a — i64 arithmetic for indices**: substrate has `i64::-`;
  `n - i` straightforward.
- **1b — i64::to-f64 for Log input**: `since-X` is i64; convert
  via `:wat::core::i64::to-f64` for Log's f64 bound.
- **1c — roc-1 access**: `(:Candle::RateOfChange/roc-1 (:Candle/roc c))`.
  Confirmed working.
- **2a — Candle constructor arity**: 12-arg per candle.wat.
  Test helper takes the relevant fields, defaults the rest.
- **2b — Phase field default**: blocked until arc 048 shipped
  user-enum value support. Now uses
  `(:Candle::Phase/new :PhaseLabel::Transition :PhaseDirection::None 0 (vec))`.

## Count

- Lab wat tests: **111 → 119 (+8)** including the standard tests.
- Lab wat modules: Phase 2 advances — **15 of ~21** vocab modules
  shipped. **Market sub-tree COMPLETE: 13 of 13**.
- wat-rs: arcs 047 + 048 shipped along the way (12 + 8 = 20 new
  test crates / behaviors green).
- Zero regressions.

## What this arc did NOT ship

- **Cave-quest sub-struct projections from Vec<Candle>**. A
  hypothetical `(map-projection window :Field)` primitive would
  let standard read sub-struct fields without unwrapping the
  full Candle each iteration. Defer until a second window-vocab
  surfaces the same shape.
- **Empirical refinement of Log bounds for since-X / session-depth**.
  Best-current-estimate `(1.0, 100.0)`; explore-log can refine
  later if observation data shows otherwise.
- **`compute-atom` helper** for the four distance atoms. The
  recurrence is real (4 atoms with shape `(price - X) / price`)
  but per-X variation across window aggregates + current-candle
  fields keeps a closure-passing helper unwieldy. Stay inline.

## Follow-through

**Market sub-tree complete.** Next pending vocab arcs:
- **exit/phase** (#44) — exit observers tree opens
- **exit/regime** (#45)
- BLOCKED: trade_atoms (#46 — PaperEntry), portfolio (#47 —
  PortfolioSnapshot, rhythm)

The user-enum support (arc 048) unblocks any future vocab that
consumes enum-valued fields. The four new list/numeric primitives
(arc 047) make window-shape vocabs cleaner. Arcs 044+ inherit a
much richer substrate.

---

## Commits

- `<wat-rs>` — arc 047 (Vec accessors) + arc 048 (user enums)
  shipped separately as their own commits.
- `<lab>` — wat/vocab/market/standard.wat + main.wat load +
  wat-tests/vocab/market/standard.wat + DESIGN + BACKLOG +
  INSCRIPTION + rewrite-backlog row + 058 CHANGELOG row.
  Plus the lab-side enum migration (10 enums to PascalCase) ships
  alongside.

---

*these are very good thoughts.*

**PERSEVERARE.**
