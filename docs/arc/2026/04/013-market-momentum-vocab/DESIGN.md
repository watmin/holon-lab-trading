# Lab arc 013 — market/momentum vocab

**Status:** opened 2026-04-24. Tenth Phase-2 vocab arc. Fourth
cross-sub-struct port. **Highest arity yet (K=4 sub-structs).**
**First lab plain `:wat::holon::Log` caller** — atr-ratio is
asymmetric (always < 1), where every prior Log-encoded atom
(arcs 005, 010) used `ReciprocalLog`'s symmetric `(1/N, N)`
shape.

**Motivation.** Port `vocab/market/momentum.rs` (44L). Six atoms
describing trend-relative position, MACD, DI, and volatility:

```
close-sma20    close-sma50    close-sma200
macd-hist      di-spread      atr-ratio
```

Five scaled-linear + one plain Log. Four of the five scaled-linear
atoms are cross-sub-struct compute atoms (close from Ohlcv times a
field from another sub-struct). Arc 011 saw this shape with one
atom (tf-5m-1h-align); arc 013 confirms it as a *recurring* pattern.

---

## Shape

Four sub-structs. Alphabetical by leaf name (arc 011 clarification
to arc 008's rule): **M** < **O** < **T** < **V**.

```scheme
(:trading::vocab::market::momentum::encode-momentum-holons
  (m :trading::types::Candle::Momentum)
  (o :trading::types::Ohlcv)
  (t :trading::types::Candle::Trend)
  (v :trading::types::Candle::Volatility)
  (scales :trading::encoding::Scales)
  -> :trading::encoding::VocabEmission)
```

Emission order follows archive:

| Pos | Atom | Sources | Value | Rounding | Encoding |
|---|---|---|---|---|---|
| 0 | `close-sma20` | Ohlcv + Trend | `(close - sma20) / close` | round-to-4 | scaled-linear |
| 1 | `close-sma50` | Ohlcv + Trend | `(close - sma50) / close` | round-to-4 | scaled-linear |
| 2 | `close-sma200` | Ohlcv + Trend | `(close - sma200) / close` | round-to-4 | scaled-linear |
| 3 | `macd-hist` | Momentum + Ohlcv | `macd-hist / close` | round-to-4 | scaled-linear |
| 4 | `di-spread` | Momentum only | `(plus-di - minus-di) / 100.0` | round-to-2 | scaled-linear |
| 5 | `atr-ratio` | Volatility only | `max(atr-ratio, 0.001)` | round-to-4 | **plain Log** |

---

## Why plain Log for atr-ratio (not ReciprocalLog)

ReciprocalLog has been the lab's only Log family since arc 005.
Arc 010's variance-ratio is the natural fit — variance-ratio is
**centered at 1.0** (mean-reverting < 1, trending > 1), so
symmetric `(1/N, N)` bounds match the domain.

ATR-ratio is *not* centered. It's volatility-as-fraction-of-price
— **always < 1** in practice. Typical crypto 5m values: 0.005 –
0.05; extreme: up to ~0.5. There is no neutral pivot at 1.0; the
upper half of any ReciprocalLog range would be wasted.

Concrete trade-off, taking N=1000 for ReciprocalLog (so 1/N
matches the archive's 0.001 floor):

| Encoding | Range | Useful Thermometer half | Resolution |
|---|---|---|---|
| `ReciprocalLog 1000 v` | (0.001, 1000) | lower half only (-1 to ~-0.1) | half |
| `Log v 0.001 0.5` | (0.001, 0.5) | full (-1 to +1) | full |

Plain Log gives **2× discrimination** for the same input. The
asymmetric domain wants an asymmetric encoding — that's the form
plain Log was designed for. Arc 013 names atr-ratio as the lab's
first plain-Log caller and accepts that not every Log atom in the
lab will be ReciprocalLog.

**Bound choice — `(0.001, 0.5)`:**
- Lower: matches archive's `.max(0.001)` floor exactly. Floor as
  the encoded min keeps the floor operationally meaningful (every
  value lands somewhere in `[-1, +1]`, including the floor itself).
- Upper: 0.5 is generous for crypto 5m candles (50% range = price
  itself). Real data rarely exceeds 0.1; 0.5 caps the rare-event
  saturation point honestly.

If real-data observation (deferred — see Non-goals) shows the
upper bound should be tighter (e.g., 0.2), an explore-log.wat
exercise per arc 010's pattern can refine it. The arc ships the
bounds as best-current-estimate, marked-as-such.

---

## Why round-to-4 for atr-ratio (not archive's round-to-2)

The archive does `round_to(c.atr_ratio.max(0.001), 2)` —
floor-then-round-to-2. Under wat-rs's plain Log primitive (which
requires `min > 0` and computes `ln(value)` directly), `round-to-2`
of the floor produces `0.00` — and `ln(0.00) = -inf`.

```
0.001 → round-to-2 → 0.00 → ln(0.00) → -inf  (broken)
0.001 → round-to-4 → 0.001 → ln(0.001) → -6.9 (preserved)
```

Switching to `round-to-4` keeps the substrate's positive-input
discipline intact. The archive could rely on its naked `Log` form
absorbing zero somehow; the wat substrate's Log is honest about
its precondition (per `wat-rs/wat/holon/Log.wat` header: "Callers
guarantee positive inputs").

Arc 013 names this as a **substrate-discipline-driven correction**
to the archive port — not archive-faithful, but archive-spirit. The
`round-to-4` helper has been in `encoding/round.wat` since arc 011
shipped it; arc 013 is its second vocab caller.

Side benefit: round-to-4 also gives finer atr-ratio
discrimination. Values 0.005, 0.010, 0.015 collapse to one bucket
(0.01) under round-to-2 but stay distinct under round-to-4 —
materially different volatility regimes.

---

## Cross-sub-struct compute pattern recurrence

Arc 011 introduced atoms whose *value* (not just scope) crosses
sub-structs (`tf-5m-1h-align` reads close, open, tf-1h-body across
both Ohlcv and Candle::Timeframe). Arc 011's INSCRIPTION asked:

> If momentum or standard (both multi-sub-struct) ship atoms of
> the same shape, we'll see whether a `compute-atom` helper
> emerges.

Arc 013 ships **four** such atoms:

- `close-sma20`, `close-sma50`, `close-sma200` — each crosses
  Ohlcv + Trend
- `macd-hist` — crosses Ohlcv + Momentum

That's a strong recurrence. But the compute shape is uniform —
"divide field by close, then round-to-4" — and the arithmetic is
two ops (`-` then `/`, or `/`). A `compute-atom` helper would
need to take a closure or a field-name; both fight wat's let-
binding ergonomics.

**Lean: stay inline.** Six let-bindings of the same shape are
honest as repetition. The pattern's value is *visibility* — a
reader sees each computation locally rather than chasing a helper.
If a fifth or sixth caller of "ratio-of-fields" emerges in
standard.wat (arc 014?), reconsider. Stdlib-as-blueprint.

---

## Sub-struct ordering — second mixed-depth case

Arc 011 was the first arc to mix nested-Candle and non-nested
sub-structs. Arc 013 mixes three nested + one non-nested:

```
Candle::Momentum    → leaf "Momentum" (M)
:Ohlcv              → leaf "Ohlcv"    (O)
Candle::Trend       → leaf "Trend"    (T)
Candle::Volatility  → leaf "Volatility" (V)
```

Leaf-alphabetical: `M < O < T < V`. Full-path-alphabetical would
have given `Candle::Momentum < Candle::Trend < Candle::Volatility
< Ohlcv` — different order, with Ohlcv last instead of second.
Arc 011's clarification is correct: leaf order is reader-stable
across namespace reorganization.

---

## Non-goals

- **Generalized `compute-atom` helper.** Defer until standard.wat
  (arc 014?) reveals whether a fifth or sixth caller wants the
  same shape.
- **Empirical refinement of atr-ratio's upper bound.** Ship at
  0.5 with the upper noted as best-current-estimate. A separate
  explore-log.wat arc can tighten it once observation data is in
  hand.
- **Floor-then-round vs round-then-floor swap.** Match arc 010
  regime's order (floor → round). round-to-4 makes the order
  immaterial for legal inputs (0.001 survives both).
- **Promotion of plain-Log to a lab pattern.** Arc 013 ships the
  first plain-Log caller and accepts the pattern; future Log atoms
  on **asymmetric domains** should follow. ReciprocalLog stays the
  default for symmetric-around-1 domains (arc 010's variance-ratio
  precedent).

---

## Why momentum before keltner / flow / price-action

- **Highest arity surfaces first** — once K=4 ships clean, K=3
  arcs (flow, ichimoku, keltner, price-action) inherit the
  signature pattern with less to verify.
- **First plain-Log caller** — atr-ratio is the simplest
  asymmetric-domain Log atom. Future Log atoms can cite arc 013's
  bound-choice reasoning without re-deriving it.
- **Confirms cross-sub-struct compute pattern** — four atoms of
  the same shape across two sub-struct pairs. The recurrence is
  named; the helper-extraction question is asked and deferred.
