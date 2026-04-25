# Lab arc 014 — market/flow vocab

**Status:** opened 2026-04-24. Eleventh Phase-2 vocab arc. Fifth
cross-sub-struct port. **First K=3 module** (Momentum + Ohlcv +
Persistence). Names a **substrate gap → algebraic equivalence
workaround** (`exp` is missing from `:wat::std::math::*`; the
archive's `Log(exp(x))` chain reduces to a direct Thermometer at
log-bounds). Names a **range-conditional shape** (three atoms
guard against `range > 0`).

**Motivation.** Port `vocab/market/flow.rs` (47L). Six atoms
describing volume flow and intra-bar pressure:

```
obv-slope        vwap-distance
buying-pressure  selling-pressure
volume-ratio     body-ratio
```

Four scaled-linear + two log-spaced (obv-slope, volume-ratio).
Three of the scaled-linear atoms (buying-pressure, selling-
pressure, body-ratio) guard against zero-range candles via
`if (high - low) > 0`.

---

## Shape

Three sub-structs. Alphabetical-by-leaf (arc 011): **M** < **O**
< **P**.

```scheme
(:trading::vocab::market::flow::encode-flow-holons
  (m :trading::types::Candle::Momentum)
  (o :trading::types::Ohlcv)
  (p :trading::types::Candle::Persistence)
  (scales :trading::encoding::Scales)
  -> :trading::encoding::VocabEmission)
```

Emission preserves archive order:

| Pos | Atom | Source | Value | Encoding |
|---|---|---|---|---|
| 0 | `obv-slope` | Momentum | `obv-slope-12` | log-bound Thermometer (-ln 10, ln 10) |
| 1 | `vwap-distance` | Persistence | round-to-4 raw | scaled-linear |
| 2 | `buying-pressure` | Ohlcv | `(close - low) / range` else 0.5, round-to-2 | scaled-linear |
| 3 | `selling-pressure` | Ohlcv | `(high - close) / range` else 0.5, round-to-2 | scaled-linear |
| 4 | `volume-ratio` | Momentum | `volume-accel` | log-bound Thermometer (-ln 10, ln 10) |
| 5 | `body-ratio` | Ohlcv | `abs(close - open) / range` else 0.0, round-to-2 | scaled-linear |

---

## Substrate gap: `exp` is missing

The archive applies `f64::exp` to two atoms before encoding:

```rust
obv_slope: round_to(c.obv_slope_12.exp(), 2),         // → Log
volume_ratio: round_to(c.volume_accel.exp().max(0.001), 2), // → Log
```

`:wat::std::math::*` has `ln`, `log`, `sin`, `cos`, `pi` — but
**no `exp`**. Three options surfaced:

**A. Cave-quest `exp` primitive.** One-line wat-rs addition next
to `ln`. Mirrors `f64::ln` plumbing exactly. Adds substrate cost
mid-arc.

**B. Algebraic equivalence — direct Thermometer at log-bounds.**
The archive's chain `Log(exp(x))` reduces to `Thermometer(x,
-ln(N), ln(N))` at appropriate N. The encoding is semantically
identical (multiplicative spacing around 0); the exp+round+ln
dance was just a roundabout way to encode a signed slope on a
log-spaced Thermometer.

**C. Linear encoding instead of Log.** Drops the multiplicative
semantics entirely. Lossy.

**Lean: B.** No substrate addition needed; the algebraic
equivalence is mathematically exact (modulo archive's round-to-2
quantization on the exp output, which doesn't translate cleanly
anyway). N=10 chosen to match arc 010 regime's variance-ratio
precedent — bounds (1/N, N) → log-bounds (-2.30, 2.30) covers
typical slope/ratio swings with margin for outliers.

The N=10 choice ships as best-current-estimate; if observation
data later shows the bounds need tightening, an explore-log
exercise per arc 010's pattern can refine it.

**Side benefit of skipping exp+round:** the substrate's geometric
bucketing (arc 012) operates on scaled-linear values, not Log
inputs. Plain Thermometer atoms encode the raw value directly —
the archive's pre-encoding round-to-2 was substrate-redundant
anyway under arc 012's discipline. We drop it cleanly.

---

## Range-conditional pattern

Three atoms (buying-pressure, selling-pressure, body-ratio) guard
the `(close - low) / range`-style compute against zero-range
candles. Archive shape:

```rust
buying_pressure: round_to(if range > 0.0 { (c.close - c.low) / range } else { 0.5 }, 2),
```

In wat — three callsites, same `range > 0` guard, different
numerators and defaults (0.5 / 0.5 / 0.0). Compute `range` once,
guard once (via let-bound `range-positive`), branch per atom:

```scheme
((range :f64) (:wat::core::f64::- high low))
((range-positive :bool) (:wat::core::> range 0.0))
((buying-pressure :f64)
  (:wat::core::if range-positive -> :f64
    (:trading::encoding::round-to-2
      (:wat::core::f64::/ (:wat::core::f64::- close low) range))
    0.5))
;; ... selling-pressure analogous (numerator high - close, default 0.5)
;; ... body-ratio analogous (numerator abs(close - open), default 0.0)
```

Pattern hasn't recurred enough across the corpus to extract a
helper. Three callsites in **one module** with **different
defaults** would force a closure-passing helper, fighting wat's
let-binding ergonomics. Stay inline per stdlib-as-blueprint.

If standard.wat (arc 015?) adds a fourth same-shape caller,
reconsider extracting `range-conditional-ratio` to
`shared/helpers.wat`.

---

## abs(close - open) — third inline-clamp-shape

Body-ratio's numerator is `abs(close - open)`. Wat doesn't have
a built-in `f64::abs`; the inline pattern is two-arm `if`:

```scheme
((body :f64) (:wat::core::f64::- close open))
((abs-body :f64)
  (:wat::core::if (:wat::core::>= body 0.0) -> :f64
    body
    (:wat::core::f64::- 0.0 body)))
```

Single use in this module. Matches arc 011's signum-of-f64 inline
pattern (and arc 009's clamp). Stay inline; if a third caller
surfaces, extract to `shared/helpers.wat`.

---

## Why N=10 for log-bound Thermometer

obv-slope-12 and volume-accel are both signed-slope-style values
centered at 0. The archive's `f64::exp` lift gives positive
values centered at 1.0 — a standard ReciprocalLog domain.

Arc 005 oscillators uses ReciprocalLog 2.0 for ROC atoms (per-1%
near 1.0, conservative). Arc 010 regime uses ReciprocalLog 10.0
for variance-ratio (per-10% near 1.0, wider domain).

For obv-slope and volume-ratio:
- OBV slope can swing widely in volatile periods; 10× resolution
  matches the "is the trend turning?" semantic intent.
- Volume can spike to 10× baseline easily on news events; same
  N=10 feel.

Pick N=10 for both. Document as best-current-estimate; defer
empirical refinement to its own arc per arc 010's pattern.

In wat:

```scheme
((ln-N :f64) (:wat::std::math::ln 10.0))
((neg-ln-N :f64) (:wat::core::f64::- 0.0 ln-N))
((h1 :wat::holon::HolonAST)
  (:wat::holon::Bind
    (:wat::holon::Atom "obv-slope")
    (:wat::holon::Thermometer obv-slope-12 neg-ln-N ln-N)))
```

`ln(10)` evaluated at runtime (negligible cost; constant per
call). `neg-ln-N` is the standard wat negation pattern (no
literal negative numbers).

---

## Why flow before keltner / ichimoku / price_action

- **K=3 is the next-up arity** after arc 013's K=4. Going down
  from 4 to 3 keeps the cross-sub-struct rule visible (three
  parameters demonstrate alphabetical sort across more cases).
- **Substrate-gap arc** — the missing `exp` discovery and the
  algebraic-equivalence pivot are durables future readers will
  want.
- **First K=3 module** — arc 011 INSCRIPTION named flow as the
  first K=3 vocab arc post-013. Inheriting the leaf-alpha rule
  + the multi-Log-form precedent (arc 013's plain Log).

---

## Non-goals

- **Cave-quest `exp` primitive.** Path B's algebraic equivalence
  is mathematically exact and ships without substrate change.
  Stays open for a later arc if observation shows the bounds we
  pick need refinement.
- **Empirical refinement of N=10 bounds.** Best-current-estimate;
  separate explore-log arc.
- **Generalized `range-conditional-ratio` helper.** Three
  callsites in one module with different defaults — stay inline.
- **Generalized `f64::abs`.** Single use; inline.
