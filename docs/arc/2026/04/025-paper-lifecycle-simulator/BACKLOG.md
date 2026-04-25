# lab arc 025 — paper lifecycle simulator — BACKLOG

**Shape:** six slices. ATR + median window first (smallest, leaves);
PhaseState second (depends on ATR's smoothing parameter); simulator
types third (no logic, sets the API surface); simulator engine
fourth (the actual yardstick); end-to-end integration smoke fifth;
INSCRIPTION + cross-link sixth.

Each slice is independently mergeable. Slice 4 is the load-bearing
chunk; slices 1–3 enable it; slices 5–6 close it.

---

## Slice 1 — ATR (Wilder-smoothed true range) + median-week window

**Status: shipped 2026-04-25.** ~80 LOC ATR + ~75 LOC AtrWindow
delivered as `wat/encoding/atr.wat` + `wat/encoding/atr-window.wat`.
12 tests across `wat-tests/encoding/atr.wat` (6) +
`wat-tests/encoding/atr-window.wat` (6) — all green first pass after
the substrate uplift below. Lab wat tests 152 → 164.

**Substrate uplift forced by this slice — `:wat::core::sort-by`.**
AtrWindow's `median` requires sort, and wat-rs had no sort
primitive. Shipped to wat-rs as a carry-along (single primitive,
predicate-driven Common-Lisp-style `(sort-by xs less?)` — user owns
asc/desc/key via the predicate). Same shape as `string::concat`
during arc 055. Tagged "arc 056" in the wat-rs commit message but
no separate INSCRIPTION (small enough to ride as carry-along).

**Divergence from plan — `:wat::core::nth` not existing.** The
DESIGN sketched `(:nth sorted mid)` for indexed access. Substrate
provides `(:get sorted mid) -> :Option<f64>` instead — deliberate
per `feedback_shim_panic_vs_option`. Median rewrites with
match-with-impossible-None (sentinel 0.0; n>0 already gated, mid
in-range by construction). Cleaner than adding a third primitive.

**Divergence — AtrState + WilderState merged.** Archive's Rust
separates `AtrState` (a wrapper over `WilderState`) for reuse across
other indicators. wat-rs port collapses to one struct; if Phase 5's
IndicatorBank materializes multiple Wilder consumers, the
abstraction grows then.

`wat/encoding/atr.wat` — direct port of
`archived/pre-wat-native/src/domain/indicator_bank.rs:315-354`'s
`AtrState` + the Wilder helper.

```scheme
(:wat::core::struct :trading::encoding::AtrState ...)
(:trading::encoding::atr-update state high low close → state)
(:trading::encoding::atr-ready? state → bool)
(:trading::encoding::atr-value state → f64)
```

`wat/encoding/atr-window.wat` — ring-buffer of ATR values (length
2016 = 1 week of 5-min candles), `median` via sort + middle.

```scheme
(:wat::core::struct :trading::encoding::AtrWindow
  (values :Vec<f64>)        ; bounded-length 2016
  (capacity :i64))
(:trading::encoding::atr-window-push window value → window)
(:trading::encoding::atr-window-median window → :Option<f64>)   ; :None until ≥period filled
```

**Tests** (`wat-tests/encoding/atr.wat`):

1. **TR formula** — `update(state, h=110, l=100, prev_c=105)`
   produces TR = max(10, |110-105|, |100-105|) = 10.
2. **Ready gate** — `ready?` is false until `period` candles processed,
   true thereafter.
3. **Wilder convergence** — feed constant TR for 50 candles; ATR converges to TR.
4. **Median window — empty** — `median` returns `:None` on empty.
5. **Median window — odd-length** — middle value.
6. **Median window — at capacity** — oldest values evicted on push past 2016.

**Estimated cost:** ~80 LOC + 6 tests. Half a day.

---

## Slice 2 — PhaseState streaming state machine

**Status: ready (after slice 1; phase-step needs an ATR-derived
smoothing parameter).**

`wat/encoding/phase-state.wat` — direct port of
`archived/pre-wat-native/src/types/pivot.rs:95-282`'s `PhaseState`.

```scheme
(:wat::core::enum :trading::encoding::TrackingState :Rising :Falling)
(:wat::core::struct :trading::encoding::PhaseState ...)
(:trading::encoding::phase-state-fresh → state)
(:trading::encoding::phase-step state close volume candle-i smoothing → state)
```

The archive's tests in `pivot.rs:285-432` are the spec. Port them
verbatim — same scenarios, same assertions:

7. **Initial state** — fresh state has Valley label, count=0, empty history.
8. **Single step** — first candle sets Falling tracking, Valley label.
9. **Valley → Transition → Peak** — `pivot.rs:test_valley_to_transition_to_peak`.
10. **Full cycle** — `pivot.rs:test_full_cycle` — Valley → Peak → Transition-up → Valley.
11. **Peak-at-high, Valley-at-low** — `pivot.rs:test_peak_at_high_valley_at_low`.
12. **History time-trim** — phases beyond 2016 candles dropped.

**Estimated cost:** ~200 LOC + 6 tests. Day and a half.

---

## Slice 3 — Simulator types

**Status: ready (no logic; types only).**

`wat/sim/types.wat`:

```scheme
(:wat::core::enum :trading::sim::Direction :Up :Down)

(:wat::core::enum :trading::sim::PositionState
  :Active
  (Grace    (residue :f64))
  (Violence))

(:wat::core::enum :trading::sim::Decision :Hold :Exit :NotEvaluated)

(:wat::core::enum :trading::sim::TriggerLabel :Exit :Hold :Unknown)

(:wat::core::enum :trading::sim::Action
  :Hold
  (Open (direction :trading::sim::Direction))
  :Exit)

(:wat::core::struct :trading::sim::TriggerEvent ...)
(:wat::core::struct :trading::sim::LabeledTrigger ...)
(:wat::core::struct :trading::sim::Paper ...)
(:wat::core::struct :trading::sim::Outcome ...)
(:wat::core::struct :trading::sim::Aggregate ...)
(:wat::core::struct :trading::sim::Config ...)
(:wat::core::struct :trading::sim::Thinker ...)
```

Plurals via typealias per arc 020's pattern:

```scheme
(:wat::core::typealias :trading::sim::Papers :Vec<trading::sim::Paper>)
(:wat::core::typealias :trading::sim::Outcomes :Vec<trading::sim::Outcome>)
(:wat::core::typealias :trading::sim::TriggerEvents :Vec<trading::sim::TriggerEvent>)
```

**Tests** (`wat-tests/sim/types.wat`):

13. **Construction round-trips** — every struct constructible + accessible.
14. **Variant construction** — `(Grace residue=42.0)`, `(Open Up)`, etc.

**Estimated cost:** ~100 LOC + 2 tests. Half a day.

---

## Slice 4 — Simulator engine

**Status: ready (after slices 1, 2, 3).**

`wat/sim/paper.wat`:

```scheme
(:trading::sim::run stream thinker config → aggregate)

;; Internal helpers (not all public):
(:trading::sim::residue entry-price current-price direction principal fees → f64)
(:trading::sim::evaluate-gates state position config phase-label market-pred → bool)
(:trading::sim::label-trail trail outcome → labeled-trail)
(:trading::sim::tick state candle config thinker → state)
```

**Tests** (`wat-tests/sim/paper.wat`):

15. **Empty stream** — 0 candles → empty aggregate (papers=0).
16. **Always-Hold thinker** — never proposes → 0 papers.
17. **Always-Up thinker, deadline hits before any Peak** — single
    paper, Violence at deadline, retroactive labels say
    "should-have-Exited" at every Peak passed. Construct stream
    that contains no Peaks within 288 candles to force this.
18. **Always-Up thinker, Peak forms in window** — paper opens at
    candle 0, Peak forms at candle ~50, thinker says Exit at
    Peak (gates 1-3 pass) → Grace, residue = positive.
19. **Always-Down thinker, symmetric** — Down + Valley exit → Grace.
20. **Residue floor** — thinker says Exit at Peak but `residue <
    min-residue` (price moved less than fees) → simulator REFUSES
    Exit (gate 3 fails), paper stays Active until deadline.
21. **Retroactive labeling — Grace** — paper Grace'd at trigger T
    → trail's T entry labeled `:Exit`; passed-through prior triggers
    labeled `:Hold`.
22. **Retroactive labeling — Violence** — paper Violence'd at
    deadline → every passed trigger labeled `:Exit`
    (should-have-Exit'd).
23. **Aggregate accuracy** — run a known-shape stream with two
    papers (one Grace, one Violence); aggregate.papers=2,
    grace_count=1, violence_count=1, total_residue+total_loss
    matches per-paper amounts.

**Estimated cost:** ~250 LOC + 9 tests. Two and a half days.
This is the load-bearing slice.

---

## Slice 5 — Real-data integration smoke

**Status: ready (after slice 4).**

`wat-tests/sim/integration.wat` — opens
`data/btc_5m_raw.parquet` via `:lab::candles::Stream` (Phase 0
shim), runs over the first 10,000 candles with a hand-coded
thinker, asserts the simulator runs end-to-end.

```scheme
(:wat::test::deftest :trading::test::sim::integration::ten-thousand-candles
  ()
  (:wat::core::let*
    (((stream :lab::candles::Stream)
      (:lab::candles::open "data/btc_5m_raw.parquet"))
     ((thinker :trading::sim::Thinker)
      (:trading::sim::Thinker
        :propose? <always-Up>
        :should-exit? <exit-at-first-Peak>))
     ((config :trading::sim::Config)
      (:trading::sim::Config
        :deadline 288 :min-residue 0.01 :fee-bps 35.0 :atr-period 14))
     ((agg :trading::sim::Aggregate)
      (:trading::sim::run-bounded stream thinker config 10000)))   ; bounded variant
    ;; Smoke assertions only — values not predicted, just sanity.
    (:wat::core::let*
      (((_ :()) (:wat::test::assert-eq (:wat::core::> agg.papers 0) true)))
      (:wat::test::assert-eq (:wat::core::f64::is-finite? agg.total-residue) true))))
```

**Tests:** 1 (this one).

**Estimated cost:** ~50 LOC + 1 test (and add a `run-bounded`
variant of `run` that takes a max-candles parameter; ~10 LOC
addition). Half a day.

---

## Slice 6 — INSCRIPTION + cross-link

**Status: blocked on slices 1-5 shipping.**

- **INSCRIPTION.md** — record what landed where, LOC delta per slice,
  test count delta, sub-fog 5a's smoothing-warmup behavior in
  practice (does the 2016-candle warmup show up clean in the
  integration smoke?).
- **`docs/rewrite-backlog.md` cross-link.** Note in Phase 1.5's row
  that PhaseState shipped early in lab arc 025; note in Phase 5's
  IndicatorBank row that ATR + AtrWindow shipped early in lab
  arc 025. The rest of IndicatorBank's ~100 indicators still ship
  in Phase 5.
- **CLAUDE.md** — leave alone per backlog directive (Phase 5 trigger
  for CLAUDE.md refresh).

**Estimated cost:** ~1 hour. Doc only.

---

## Verification end-to-end

After all slices land, the lab can:

```scheme
(:wat::core::let*
  (((stream :lab::candles::Stream)
    (:lab::candles::open "data/btc_5m_raw.parquet"))
   ((thinker :trading::sim::Thinker) <some-thinker>)
   ((agg :trading::sim::Aggregate)
    (:trading::sim::run stream thinker default-config)))
  (... agg.papers, agg.grace-count, agg.total-residue ...))
```

That's the yardstick. Every encoding experiment, every observer
port, every parameter sweep produces an `Aggregate` and we compare
deltas. The lab moves from "vibes" to "numbers."

---

## Out of scope

- **Trust-ladder deadline scaling** (trust → 288–2016 mapping).
  v1 uses static `deadline = 288` for all thinkers. Multi-broker
  arc + ProposerRecord plumbing is the follow-up.
- **Multi-broker tournament.** v1 runs one thinker. CSP-parallel
  multi-broker is a separate arc; types and simulator structure
  generalize cleanly.
- **Position observer (gate 4 learner).** Phase 4 work. Slot's
  reserved in `Thinker.should-exit?`.
- **The remaining IndicatorBank indicators.** ATR alone for v1;
  ~100 others stay in Phase 5.
- **Real position bookkeeping.** Papers don't move capital. Real
  position type lands in Phase 5+.

---

## Risks

**State-machine edge cases at boundaries.** PhaseState's
Rising/Falling tracking has subtle behavior at smoothing-threshold
crossings. Mitigate: port the archive's tests verbatim. They
already cover the canonical cases.

**ATR smoothing warmup interaction with phase trigger.** Sub-fog
5a notes the 2016-candle warmup before median is reliable. v1
documents this; integration smoke at 10k candles is fine
(warmup ends by candle 2016). For shorter test runs, we'd need
the degraded-smoothing fallback — out of scope for v1.

**Retroactive labeling correctness.** The trail back-fill at
resolution must match the proposal's spec. Tests 21 + 22 are the
guard. Cross-check with `Proposal 055 RESOLUTION.md:60-66` if
ambiguity surfaces during implementation.

**Capacity / budget.** None expected — paper trail bounded by
deadline, history bounded by week, aggregates bounded by paper
count. No runaway state.

---

## Total estimate

- Slice 1: 0.5 day (ATR + median window)
- Slice 2: 1.5 days (PhaseState)
- Slice 3: 0.5 day (types)
- Slice 4: 2.5 days (simulator engine — load-bearing)
- Slice 5: 0.5 day (integration smoke)
- Slice 6: 1 hour (docs)

**~5.5 days end-to-end.** Slices 1–3 can ship in any order
(slice 2 depends on 1 only via the `smoothing` parameter; could
even ship 3 first since it has no logic deps). Slice 4 is the
gating chunk; once green, slices 5–6 are short.
