# Lab arc 007 — market/fibonacci vocab

**Status:** opened 2026-04-23. Fifth Phase-2 vocab arc. Clean
leaf — single sub-struct, oscillators-pattern.

**Motivation.** Port `vocab/market/fibonacci.rs` (72L). Eight
atoms derived from range-position data: three raw positions over
12/24/48-candle windows, plus five Fibonacci-retracement
distances (0.236, 0.382, 0.500, 0.618, 0.786) computed from the
48-window position.

---

## Shape

Single sub-struct. Takes `:trading::types::Candle::RateOfChange`
(same sub-struct `market/oscillators` uses for its ROC atoms —
but from different fields: `range-pos-*` rather than `roc-*`).

Signature:
```scheme
(:trading::vocab::market::fibonacci::encode-fibonacci-holons
  (r :trading::types::Candle::RateOfChange)
  (scales :trading::encoding::Scales)
  -> :trading::encoding::VocabEmission)
```

Eight scaled-linear atoms; no conditional emission, no Log.

| Position | Atom | Value |
|---|---|---|
| 0 | `range-pos-12` | `round-to-2(range_pos_12)` |
| 1 | `range-pos-24` | `round-to-2(range_pos_24)` |
| 2 | `range-pos-48` | `round-to-2(range_pos_48)` |
| 3 | `fib-dist-236` | `round-to-2(range_pos_48 - 0.236)` |
| 4 | `fib-dist-382` | `round-to-2(range_pos_48 - 0.382)` |
| 5 | `fib-dist-500` | `round-to-2(range_pos_48 - 0.500)` |
| 6 | `fib-dist-618` | `round-to-2(range_pos_48 - 0.618)` |
| 7 | `fib-dist-786` | `round-to-2(range_pos_48 - 0.786)` |

All eight thread `Scales` values-up through sequential
scaled-linear calls. Returns `VocabEmission` (arc 006).

---

## Why this is the next obvious leaf

- Same sub-struct as oscillators (clean, known pattern).
- No ReciprocalLog — no Log at all.
- No conditional emission.
- No window — per-candle computation.
- Zero cross-sub-struct fog.

Expected ship time: ~20 minutes including tests + INSCRIPTION.

---

## Non-goals

- **No shared helper for the sequential scaled-linear threading.**
  Arc 005 (oscillators) and arc 007 (here) share an 8-step
  scaled-linear sequence pattern. A helper macro
  `scaled-linear-many` might be worth it. Defer until a third
  caller surfaces (regime likely will). Stdlib-as-blueprint.
- **No Fibonacci-specific scale adjustment.** The `fib-dist-*`
  values sit in roughly [-0.8, +0.8] given `range_pos_48` is
  typically [0.0, 1.0]. Standard scaled-linear handles the range.
