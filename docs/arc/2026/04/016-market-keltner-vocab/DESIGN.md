# Lab arc 016 — market/keltner vocab

**Status:** opened 2026-04-24. Thirteenth Phase-2 vocab arc.
Seventh cross-sub-struct port. K=2 (Ohlcv + Volatility) — first
arc to ship under the post-arc-046 substrate discipline cleanly
from the start (arc 015 was the migration arc; arc 016 is just a
straightforward port using substrate primitives directly).

**Motivation.** Port `vocab/market/keltner.rs` (45L). Six atoms
describing Bollinger / Keltner channel positions and squeeze:

```
bb-pos   bb-width   kelt-pos
squeeze  kelt-upper-dist   kelt-lower-dist
```

Five scaled-linear + one plain Log (bb-width — third plain-Log
caller after arc 013 atr-ratio and arc 015 cloud-thickness; same
asymmetric-domain pattern).

---

## Shape

K=2 leaf-alphabetical: **O** < **V**.

```scheme
(:trading::vocab::market::keltner::encode-keltner-holons
  (o :trading::types::Ohlcv)
  (v :trading::types::Candle::Volatility)
  (scales :trading::encoding::Scales)
  -> :trading::encoding::VocabEmission)
```

| Pos | Atom | Source | Compute | Encoding |
|---|---|---|---|---|
| 0 | `bb-pos` | Volatility | round-to-2 raw | scaled-linear |
| 1 | `bb-width` | Volatility | floor 0.001, round-to-4 | plain Log (0.001, 0.5) |
| 2 | `kelt-pos` | Volatility | round-to-2 raw | scaled-linear |
| 3 | `squeeze` | Volatility | round-to-2 raw | scaled-linear |
| 4 | `kelt-upper-dist` | Ohlcv + Volatility | `(close - kelt-upper) / close` round-to-4 | scaled-linear |
| 5 | `kelt-lower-dist` | Ohlcv + Volatility | `(close - kelt-lower) / close` round-to-4 | scaled-linear |

Two cross-sub-struct compute atoms (kelt-upper-dist +
kelt-lower-dist), same "field divided by close" shape as arc 013
momentum's close-sma* family.

---

## bb-width — third plain-Log caller

bb-width is "Bollinger band width as fraction of price" — same
asymmetric domain shape as arc 013 atr-ratio (volatility as
fraction of price) and arc 015 cloud-thickness (cloud width as
fraction of price). Always between 0 and ~0.5; no natural
"around 1.0" pivot for ReciprocalLog.

Plain Log with bounds **(0.001, 0.5)** matches the precedent
arcs set:
- Lower bound = archive's `.max(0.001)` floor.
- Upper bound = 0.5 (generous; bb-width as 50% of price is
  pathological).

`round-to-4` (not archive's `round-to-2`) preserves the floor for
plain Log's positive-input precondition. Same substrate-discipline
correction as arcs 013 + 015.

The "asymmetric-domain plain-Log" pattern is now confirmed across
three indicator families (volatility, cloud, channel-width). Future
fraction-of-price atoms inherit this shape without re-deriving.

---

## Substrate primitives — straight consumption

Lab arc 015 sweeps closed; arc 016 is the first vocab arc to be
born under the new substrate discipline. The bb-width floor uses
`:wat::core::f64::max` directly (no shared/helpers.wat load
needed). No clamp call sites in this module (no atoms wanting
bounded normalization).

---

## Why keltner before price_action / standard

- **K=2, simple.** 7 cross-sub-struct atoms across the corpus now
  (3 close-sma* + 1 macd-hist + 1 tk-spread + 2 kelt-dist).
  Pattern is settled. Keltner doesn't add new shape to learn.
- **Third plain-Log caller** confirms the asymmetric-domain
  pattern as the lab's standard for fraction-of-price atoms.
- **Pure substrate-direct port** — the first vocab arc to ship
  cleanly using the new substrate primitives without any cross-
  arc cleanup. Calibration check that arc 015's sweep landed.

---

## Non-goals

- **Cave-quest empirical N for bb-width Log bounds.** Same
  best-current-estimate as arc 013/015; if observation later
  shows the upper should tighten, separate explore-log arc.
- **`compute-atom` helper.** Question stays open for arc 017
  (standard.wat, heaviest). Two more cross-sub-struct atoms
  here doesn't move the needle on the helper-extraction
  question — the recurrence is real but the per-atom variation
  remains the obstacle.
