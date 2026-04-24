# Lab arc 006 — market/divergence vocab

**Status:** opened 2026-04-23. Fourth Phase-2 vocab arc (arc 001
shared/time, 002 exit/time, 005 market/oscillators, 006 now).

**Motivation.** Port `archived/pre-wat-native/src/vocab/market/divergence.rs`
(60L). Three atoms total: `rsi-divergence-bull`,
`rsi-divergence-bear`, `divergence-spread`. **First conditional-
emission vocab module** — each atom only emits when its input is
non-zero. Variable-length Holons (0, 1, 2, or 3 facts per call).

The arc resolves the conditional-emission pattern as a shipped
wat idiom for every future conditional-emission caller
(`exit/trade_atoms` next, then others).

---

## The input

`Candle::Divergence` sub-struct:
```
struct Candle::Divergence {
  rsi-divergence-bull : f64  ;; 0.0 = no divergence, >0 = magnitude
  rsi-divergence-bear : f64  ;; 0.0 = no divergence, >0 = magnitude
  tk-cross-delta      : f64  ;; tenkan-kijun cross (unused here)
  stoch-cross-delta   : f64  ;; stochastic cross (unused here)
}
```

Divergence reads the two `rsi-divergence-*` fields. The other
two fields are used by `stochastic.rs` (a future arc).

## Signature

```scheme
(:trading::vocab::market::divergence::encode-divergence-holons
  (d :trading::types::Candle::Divergence)
  (scales :trading::encoding::Scales)
  -> :(wat::holon::Holons, trading::encoding::Scales))
```

Same `(Holons, Scales)` return shape as oscillators (arc 005).

## The emission rules (from archive)

| Atom | Emit when | Value |
|---|---|---|
| `rsi-divergence-bull` | `bull > 0.0` | `round-to-2(bull)` |
| `rsi-divergence-bear` | `bear > 0.0` | `round-to-2(bear)` |
| `divergence-spread` | `bull > 0.0` OR `bear > 0.0` | `round-to-2(bull - bear)` |

All three use `scaled-linear`. Each emission threads through
`Scales`; non-emission preserves the current `Scales`
untouched.

---

## The conditional-emission pattern

Wat is values-up. The archive's `facts.push(...)` conditional-
push doesn't translate directly — we need a function that takes
the current `(holons, scales)` and returns a new pair, either
with the fact appended (emission) or unchanged (skip).

**File-private helper inside divergence.wat:**

```scheme
(:wat::core::define
  (:trading::vocab::market::divergence::maybe-scaled-linear
    (should-emit? :bool)
    (name :String)
    (value :f64)
    (holons :wat::holon::Holons)
    (scales :trading::encoding::Scales)
    -> :(wat::holon::Holons, trading::encoding::Scales))
  (:wat::core::if should-emit?
                   -> :(wat::holon::Holons, trading::encoding::Scales)
    (:wat::core::let*
      (((emission :trading::encoding::ScaleEmission)
        (:trading::encoding::scaled-linear name value scales))
       ((fact :wat::holon::HolonAST) (:wat::core::first emission))
       ((next-scales :trading::encoding::Scales) (:wat::core::second emission))
       ((next-holons :wat::holon::Holons) (:wat::core::conj holons fact)))
      (:wat::core::tuple next-holons next-scales))
    (:wat::core::tuple holons scales)))
```

Then `encode-divergence-holons` threads three `maybe-scaled-linear`
steps:

```scheme
(let* ((start (tuple (vec :HolonAST) scales))
       (step-1 (maybe-scaled-linear bull-ok? "rsi-divergence-bull"
                 (round-to-2 bull) (first start) (second start)))
       (step-2 (maybe-scaled-linear bear-ok? "rsi-divergence-bear"
                 (round-to-2 bear) (first step-1) (second step-1)))
       (step-3 (maybe-scaled-linear spread-ok? "divergence-spread"
                 (round-to-2 (- bull bear)) (first step-2) (second step-2))))
  step-3)
```

**Left file-private per stdlib-as-blueprint.** When a second
conditional-emission module surfaces (likely `trade_atoms.rs`
— it has similar `.max(...)` guards that gate emission),
extract `maybe-scaled-linear` into `shared/helpers.wat`.

---

## Why `conj` works here

Arc 025 shipped `:wat::core::conj` with polymorphism — `conj`
on Vec returns a new Vec with the element appended. Values-up,
no mutation. Same helper the test retrofit in arc 003 used.

A `conj`-based threading loop is the honest wat translation of
the archive's `facts.push(...)` pattern. Conditional non-emit
simply returns `(holons, scales)` unchanged.

---

## Non-goals

- **No generalization of `maybe-scaled-linear` yet.** It's the
  first caller; it lives file-private. Second caller extracts
  to `shared/helpers.wat`.
- **No generalization of the conditional-emission framework.**
  A "fold-over-optional-emissions" stream combinator might
  emerge when three or more modules exhibit the pattern.
- **No `Option<f64>` wrapping.** The archive used `Option<f64>`
  in its `DivergenceThought` helper to pre-guard then emit.
  Wat's conditional-emit path doesn't need the Option — the
  `should-emit?` bool carries the guard directly. Simpler.
