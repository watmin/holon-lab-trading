# Lab arc 017 — market/price-action vocab

**Status:** opened 2026-04-24. Fourteenth Phase-2 vocab arc.
Eighth cross-sub-struct port. K=2 (Ohlcv + PriceAction).
**Biggest plain-Log surface yet** — 3 Log atoms across two
different domain shapes. **First lab consumer of substrate
`:wat::core::f64::min`** (arc 046's primitive finally finds a
caller).

**Motivation.** Port `vocab/market/price_action.rs` (52L). Seven
atoms describing candlestick anatomy, range, gaps:

```
range-ratio  gap          consecutive-up
consecutive-down          body-ratio-pa
upper-wick   lower-wick
```

Three Log + four scaled-linear (one of which clamps; three of
which guard zero-range candles).

---

## Shape

K=2 leaf-alphabetical: **O** < **P**.

```scheme
(:trading::vocab::market::price-action::encode-price-action-holons
  (o :trading::types::Ohlcv)
  (p :trading::types::Candle::PriceAction)
  (scales :trading::encoding::Scales)
  -> :trading::encoding::VocabEmission)
```

| Pos | Atom | Source | Compute | Encoding |
|---|---|---|---|---|
| 0 | `range-ratio` | PriceAction | floor 0.001, round-to-4 | plain Log (0.001, 0.5) |
| 1 | `gap` | PriceAction | `(gap / 0.05)` clamp ±1, round-to-4 | scaled-linear |
| 2 | `consecutive-up` | PriceAction | `f64::max (1 + count) 1`, round-to-2 | plain Log (1.0, 20.0) |
| 3 | `consecutive-down` | PriceAction | same shape as `consecutive-up` | plain Log (1.0, 20.0) |
| 4 | `body-ratio-pa` | Ohlcv | `if range > 0 { abs(close - open) / range } else 0.0`, round-to-2 | scaled-linear |
| 5 | `upper-wick` | Ohlcv | `if range > 0 { (high - max(open, close)) / range } else 0.0`, round-to-2 | scaled-linear |
| 6 | `lower-wick` | Ohlcv | `if range > 0 { (min(open, close) - low) / range } else 0.0`, round-to-2 | scaled-linear |

---

## Plain-Log family extends to two shapes

The "fraction-of-price asymmetric" pattern holds for `range-ratio`
— same bounds `(0.001, 0.5)` as the four prior callers (arc 013
atr-ratio, arc 015 cloud-thickness, arc 016 bb-width, plus this
one). round-to-4 substrate-discipline correction. Fourth caller
in this family.

But **`consecutive-up` / `consecutive-down` introduce a new
plain-Log domain shape**: asymmetric, lower-bounded at 1.0
(not 0.001), upper unbounded in principle but capped for
encoding. The atom value is `(1 + count).max(1.0)` —
"how many consecutive periods?" plus 1 to keep > 0 for Log.

For these two, bounds **`(1.0, 20.0)`**:
- Lower = 1.0 (no streak)
- Upper = 20.0 (significant streak; longer ones saturate)
- For crypto 5m candles, 20 consecutive moves represents a
  ~1.5-hour directional run — rare and meaningful as a saturated
  endpoint.

`round-to-2` is fine here (no floor preservation issue —
1.00 round-to-2 = 1.00). Substrate-discipline correction not
needed since the floor matches an integer.

If observation later shows `(1, 20)` is too tight (longer
streaks compress meaningfully), refine via explore-log per arc
010 reflex.

The plain-Log family now spans two shapes:
- **Fraction-of-price** `(0.001, 0.5)` — atr-ratio,
  cloud-thickness, bb-width, range-ratio.
- **Count-starting-at-1** `(1.0, 20.0)` — consecutive-up,
  consecutive-down.

Future Log atoms with new domain characteristics (rare-event
counts? duration-in-periods?) will pick their own bounds and
name them in their arc's DESIGN.

---

## First `f64::min` consumer

`lower-wick = min(open, close) - low`. Arc 046 shipped
`:wat::core::f64::min` alongside `f64::max`; lab's prior arcs
had no min callers. Arc 017 is the first.

The `body-ratio-pa` atom uses `f64::abs(close - open)` (second
abs caller after arc 014 flow); the `upper-wick` atom uses
`f64::max(open, close)` (first non-floor max caller — prior
callers were all "value floored at constant"; this one is
"max of two free f64 values").

---

## gap — first scaled-linear-with-clamp atom

The archive computes `(gap / 0.05).max(-1.0).min(1.0)` then
round-to-4. The clamp is the same bounded-normalization shape
as ichimoku's clamp ±1 atoms; just call substrate `f64::clamp`.

This is the lab's first scaled-linear atom that pre-clamps via
`f64::clamp` before threading through scaled-linear (rather
than the ichimoku pattern of clamp-then-scaled-linear-via-Bind
inline). Same shape, different position; just normal
`scaled-linear` after the clamp.

---

## Range-conditional pattern recurs (six callers now)

`body-ratio-pa`, `upper-wick`, `lower-wick` all guard against
zero-range candles via `if range > 0`. Same shape as flow.wat's
three (`buying-pressure`, `selling-pressure`, `body-ratio`).

**Six callers across two modules with the same `if range > 0`
guard shape but different numerators and (sometimes) different
defaults.** Arc 014 named the helper-extraction question; arc 017
sees the recurrence repeated. Should we extract?

Lean: **still no.** The numerator varies per atom, the default
varies per module (flow uses 0.5 / 0.5 / 0.0; price-action uses
0.0 uniformly). A shared helper would still need a closure or a
pre-computed numerator value. Let-binding `range` and
`range-positive` once per module + branching per atom remains
the local-honest form.

If a third module surfaces with the same shape and uniform
defaults, reconsider — three modules of identical conditional
shape with one uniform default would tip the scale. Until then,
stay inline.

---

## Why price-action before standard

- **Biggest Log surface** — three Log atoms of two different
  domain shapes. Names the second plain-Log domain (count-
  starting-at-1) before standard.wat's heaviest port.
- **First f64::min consumer** — closes a substrate gap that's
  been sitting since arc 046. Validates the substrate primitive
  works as expected in real use.
- **K=2 stays simple** — standard.wat will be the heavy port
  with multiple sub-structs and window-based compute. Arc 017
  keeps the K=2 rhythm going so standard.wat doesn't carry both
  arity AND complexity in one arc.

---

## Non-goals

- **Cave-quest empirical N for consecutive-up/down bounds.**
  Best-current-estimate `(1, 20)`; explore-log can refine if
  data shows otherwise.
- **Generalized `range-conditional-ratio` helper.** Six callers
  but per-atom variation continues to fight a shared shape.
- **`compute-atom` helper.** Question still open for arc 018
  (standard.wat).
- **Sweep arc 014 flow.wat to use `f64::abs` for body**.
  Already done in lab arc 015's substrate sweep; flow.wat is
  current.
