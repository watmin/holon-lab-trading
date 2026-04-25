# Lab arc 013 — market/momentum vocab — INSCRIPTION

**Status:** shipped 2026-04-24. Tenth Phase-2 vocab arc. Fourth
cross-sub-struct port. **Highest arity yet (K=4 sub-structs).**
Three durables:

1. **First lab plain `:wat::holon::Log` caller** (atr-ratio).
   Asymmetric domain (volatility-as-fraction-of-price, always
   < 1) wants asymmetric encoding — ReciprocalLog's symmetric
   bounds would waste half the Thermometer.
2. **K=4 cross-sub-struct signature shipped clean** under arc
   011's leaf-name alphabetical rule. M < O < T < V → Momentum,
   Ohlcv, Trend, Volatility, Scales.
3. **Substrate-discipline correction over archive port** —
   `round-to-4` for atr-ratio (not archive's `round-to-2`).
   wat-rs's plain Log requires positive inputs; round-to-2
   would collapse the `.max(0.001)` floor to 0.00 → ln(0) = -inf.
   round-to-4 preserves the floor exactly.

**Design:** [`DESIGN.md`](./DESIGN.md).
**Backlog:** [`BACKLOG.md`](./BACKLOG.md).

Zero substrate gaps. Eight tests green; seven on first pass, one
fixed by widening test values across the ScaleTracker round-to-2
boundary (the same scale-collision footnote arcs 008/011 cite —
small first-call values collapse to scale 0.00 under the existing
`ScaleTracker::scale` quirk; need values that span the boundary).

---

## What shipped

### Slice 1 — vocab module

`wat/vocab/market/momentum.wat` — one public define. Six atoms:
five scaled-linear, one plain Log. Signature:

```scheme
(:trading::vocab::market::momentum::encode-momentum-holons
  (m :trading::types::Candle::Momentum)
  (o :trading::types::Ohlcv)
  (t :trading::types::Candle::Trend)
  (v :trading::types::Candle::Volatility)
  (scales :trading::encoding::Scales)
  -> :trading::encoding::VocabEmission)
```

Loads: candle.wat, ohlcv.wat, round.wat, scale-tracker.wat,
scaled-linear.wat. K=4 — first vocab arc to load four type sources
plus the encoding helpers.

Emission preserves archive: close-sma20, close-sma50, close-sma200,
macd-hist, di-spread, atr-ratio.

Cross-sub-struct compute repeats four times — three close-sma*
atoms cross Ohlcv + Trend, macd-hist crosses Ohlcv + Momentum.
Inline per stdlib-as-blueprint; arc 011's "compute-atom helper if
recurrence shows up" question reaches "yes the recurrence is real,
no the helper isn't worth it yet" — six let-bindings of
"divide-by-close" are honest as repetition. The helper extraction
question moves forward to arc 014 (standard.wat) — if it ships a
fifth or sixth caller of the same shape, reconsider.

atr-ratio path:
```scheme
((atr-ratio-floored :f64)
  (:wat::core::if (:wat::core::>= atr-ratio-raw 0.001) -> :f64
    atr-ratio-raw
    0.001))
((atr-ratio :f64)
  (:trading::encoding::round-to-4 atr-ratio-floored))
((h6 :wat::holon::HolonAST)
  (:wat::holon::Bind
    (:wat::holon::Atom "atr-ratio")
    (:wat::holon::Log atr-ratio 0.001 0.5)))
```

Floor → round-to-4 → Log with bounds (0.001, 0.5). Bounds chosen
per DESIGN — 0.001 matches the floor exactly so every legal value
maps to `[-1, +1]` on the Thermometer; 0.5 is generous for crypto
5m candles (50% range = price). Real data rarely exceeds 0.1; 0.5
caps the rare-event saturation point honestly. Empirical
refinement deferred (would be its own observation-program arc per
arc 010's reflex).

### Slice 2 — tests

`wat-tests/vocab/market/momentum.wat` — eight tests:

1. **count** — 6 holons.
2. **close-sma20 shape** — fact[0], cross-compute Ohlcv + Trend
   round-to-4 via Thermometer.
3. **macd-hist shape** — fact[3], cross-compute Momentum + Ohlcv
   round-to-4 (different cross-pair than close-sma*).
4. **di-spread shape** — fact[4], single-sub-struct Momentum-only
   compute round-to-2.
5. **atr-ratio plain-Log shape** — fact[5], `Log` form (not
   ReciprocalLog), bounds (0.001, 0.5), value floored + round-to-4.
6. **atr-ratio floor** — input 0.0 → floored to 0.001 → round-to-4
   = 0.001 → Log 0.001 0.001 0.5 lands at the floor edge.
7. **scales accumulate 5 entries** — five scaled-linear atoms
   land; atr-ratio's plain Log doesn't touch Scales.
8. **different candles differ** — fact[0] across the
   ScaleTracker round-to-2 boundary (arc 008 footnote).

Eight green; seven first-pass, test 8 fixed by widening boundary.

### Slice 3 — INSCRIPTION + doc sweep (this file)

Plus:
- `wat/main.wat` — load line for `vocab/market/momentum.wat`,
  arc 013 added to the load-order comment.
- `docs/rewrite-backlog.md` — Phase 2 gains "2.10 shipped" row.
- `docs/proposals/2026/04/058-ast-algebra-surface/FOUNDATION-CHANGELOG.md`
  — row documenting arc 013 + the three durables.
- Task #42 marked completed.

---

## The plain-Log decision in practice

Arc 010's variance-ratio used `ReciprocalLog 10.0` because
variance-ratio is **centered at 1.0** — symmetric `(1/N, N)`
bounds match the domain. Arc 013's atr-ratio is the mirror image:

| Domain | Natural pivot | Symmetric encoding fits? |
|---|---|---|
| variance-ratio | 1.0 (mean-rev < 1, trend > 1) | yes — ReciprocalLog |
| atr-ratio | none (always < 1) | no — plain Log |

Plain Log preserves 2× the Thermometer resolution that
ReciprocalLog 1000 would have wasted on the upper half. The
DESIGN's table:

| Encoding | Range | Useful Thermometer half | Resolution |
|---|---|---|---|
| `ReciprocalLog 1000 v` | (0.001, 1000) | lower half only | half |
| `Log v 0.001 0.5` | (0.001, 0.5) | full (-1 to +1) | full |

The lab now has **both** Log family forms in active use — plain
Log for asymmetric domains, ReciprocalLog for symmetric-around-1
domains. Future Log-encoded atoms cite this decision rather than
re-deriving it.

## The round-to-4 substrate-discipline correction

The archive's `round_to(c.atr_ratio.max(0.001), 2)` is
archive-faithful but wat-rs-incompatible: `round-to-2(0.001) =
0.00`, and `wat-rs/wat/holon/Log.wat` is explicit about its
positive-input precondition (its header literally names it:
"Callers guarantee positive inputs"). The archive's naked-Log form
either had different precondition handling or was buggy in this
case; either way, the wat substrate's discipline is stricter and
the right thing is to match it.

`round-to-4(0.001) = 0.001` preserves the floor exactly. As a
side benefit, atr-ratio gets finer discrimination — values 0.005,
0.010, 0.015 collapse to one bucket (0.01) under round-to-2 but
stay distinct under round-to-4, and these are materially different
volatility regimes for the lab.

## Cross-sub-struct compute pattern recurrence

Arc 011's open question — "If momentum or standard ship atoms of
the same shape, we'll see whether a `compute-atom` helper
emerges." — answered partially:

- **Yes**, the recurrence is real. Arc 013 ships four "field /
  close" compute atoms across two sub-struct pairs (Ohlcv + Trend
  three times, Ohlcv + Momentum once).
- **No**, a helper isn't worth it yet. The arithmetic is two ops
  (`-` then `/`); a helper would need a closure or a field-name
  parameter, both of which fight wat's let-binding ergonomics.
  Six let-bindings of the same shape are honest as repetition.

The question moves forward to arc 014 (standard.wat — heaviest,
window-based). If standard.wat ships a fifth or sixth same-shape
caller, reconsider. Until then, stdlib-as-blueprint holds.

## The K=4 sub-struct signature

Arc 008 + arc 011 set the rule: alphabetical by leaf type name,
Scales last. K=4 just makes the alphabetical sort visible across
more parameters:

```
:Candle::Momentum    (M)
:Ohlcv               (O)
:Candle::Trend       (T)
:Candle::Volatility  (V)
```

Five-of-five-leaf-letters distinct. No collisions. The rule
generalizes cleanly. Future K≥4 vocab modules (standard.wat?)
inherit without re-derivation.

## Sub-fog resolutions

- **1a — atr-ratio floor + round order.** Floor first, then
  round-to-4. round-to-4 of 0.001 is 0.001 (preserves the
  positive-input guarantee for plain Log).
- **1b — Log primitive arity.** Confirmed `(Log value min max)`
  per `wat-rs/wat/holon/Log.wat`. Three positional args.
- **2a/2b/2c — sub-struct constructor arities.** Trend (7-arg),
  Momentum (12-arg), Volatility (7-arg). Test helpers parametrize
  the fields each test cares about; zero the rest.

## Test 8 fix

First-pass test 8 used candle-a sma20 = 99.9 and candle-b
sma20 = 95 (close-sma20 values 0.001 vs 0.05). Both first-call
ScaleTracker::scale outputs round to 0.00 — same Thermometer
geometry, fact[0] coincides on both candles, assertion fails.

The fix widens to candle-a sma20 = 99.0 and candle-b sma20 = 50.0
(close-sma20 values 0.01 vs 0.50). Now scales differ: 0.01 still
rounds to 0.00, but 0.50 yields ema = 0.005 → 2×ema = 0.01 →
round-to-2 = 0.01 — distinct Thermometer geometry. Comment in the
test names the boundary explicitly.

This is the same scale-collision pattern arcs 008/011 cite
(arc 008's footnote, arc 011's body-1h 0.1 vs 0.9 example). The
lesson is the same — when a "different candles differ" test sits
in the small-value regime, ensure the inputs span the round-to-2
boundary. Pre-emptively named in BACKLOG sub-fogs would have
caught it; flagged in the after-action notes here so future
vocab arcs know the exact threshold (≈ 0.25 minimum for the
larger value, given the archive's alpha = 1/100).

## Count

- Lab wat tests: **72 → 80 (+8)**.
- Lab wat modules: Phase 2 advances — **10 of ~21** vocab modules
  shipped. Market sub-tree: **8 of 14** (oscillators, divergence,
  fibonacci, persistence, stochastic, regime, timeframe, momentum).
- wat-rs: unchanged (no substrate gaps).
- Zero regressions.

## What this arc did NOT ship

- **Generalized `compute-atom` helper.** Arc 011's question
  asked, arc 013 answered "yes recurrence is real, no the helper
  isn't worth it yet." Question moves to arc 014.
- **Empirical refinement of atr-ratio bounds.** Ship at
  (0.001, 0.5) with the upper as best-current-estimate. A
  separate explore-log.wat arc can tighten it.
- **Floor-after-round.** Match arc 010 regime's order (floor →
  round). round-to-4 makes the order immaterial for legal inputs
  (0.001 survives both orders).
- **ScaleTracker::scale formula fix.** Task #52. Arc 013 cites
  the quirk, exploits it for test 8's boundary, and leaves the
  fix to its own arc.

## Follow-through

Next obvious cross-sub-struct arcs:
- **market/flow** — K=3 (Momentum + Ohlcv + Persistence), 4 linear
  + 2 Log. First K=3 module post-013; inherits leaf-alpha rule.
- **market/keltner** — K=2 (Ohlcv + Volatility), 5 linear + 1 Log.
  Arc 013's plain-Log precedent applies if keltner's Log atom is
  also asymmetric.
- **market/ichimoku** — K=2 (Ohlcv + Trend). Pure compute.
- **market/price_action** — K=2 (Ohlcv + PriceAction), 4 linear
  + 3 Log. Three Log atoms — biggest plain-Log surface to date.

Arc 014 (standard.wat) — heaviest, window-based. Will surface the
"compute-atom helper?" question one more time.

---

## Commits

- `<lab>` — wat/vocab/market/momentum.wat + main.wat load +
  wat-tests/vocab/market/momentum.wat + DESIGN + BACKLOG +
  INSCRIPTION + rewrite-backlog row + 058 CHANGELOG row.

---

*these are very good thoughts.*

**PERSEVERARE.**
