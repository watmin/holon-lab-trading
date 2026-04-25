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

**Status: shipped 2026-04-25.** ~330 LOC delivered as
`wat/encoding/phase-state.wat` (heavier than the 200-LOC sketch
because the values-up `step` inlines the close_phase + begin_phase
state transitions explicitly rather than mutating a shared
struct). 8 tests in `wat-tests/encoding/phase-state.wat`
(planned 6; added `test-fresh-is-valley` and
`test-fresh-empty-history` separating the fresh-state
invariants). Lab wat tests 164 → 172.

**Substrate uplift forced by this slice — `:wat::core::not=` +
Enum equality.** PhaseState's boundary check `if new_label !=
current_phase_label` had two missing pieces in wat-rs:

1. **No `not=` primitive.** Wat had `=`/`<`/`>`/`<=`/`>=` but no
   inequality. Shipped Clojure-tradition `not=` (rather than
   C-style `!=`); shares `infer_polymorphic_compare` with `=` so
   the type rules are identical, runtime is a one-liner over
   `eval_eq`. Consistent with substrate's Lisp-shaped operator
   lineage.
2. **`values_equal` had no Enum arm.** `(= phase-label-a
   phase-label-b)` errored with "TypeMismatch — got: Enum" even
   though enum values are exactly the kind of thing you want to
   compare. Added an Enum arm: equal iff same `type_path`, same
   `variant_name`, structurally-equal fields. Both `=` and `not=`
   on enums work after this.

Both ship as carry-along (~50 LOC + 4 integration tests in
`wat-rs/tests/wat_not_eq.rs`); same shape as slice 1's `sort-by`
uplift.

**Divergence — `f64::NEG_INFINITY` / `f64::MAX` sentinels skipped.**
Archive seeds `high = NEG_INFINITY`, `low = f64::MAX` defensively
against an empty pre-step state. In wat the `fresh` state uses
0.0 placeholders; the first-candle branch of `step` overwrites
high/low with `close` before any comparison fires, so the
sentinels were never load-bearing. Documented in the wat file's
header comment.

**Divergence — `current_phase_label` retained.** The DESIGN
sketch's struct elided this field; the archive uses it as the
boundary anchor (`new_label != current_phase_label` is the close
trigger, distinct from `current_label` which is the per-candle
output). Faithful port keeps both fields. PhaseState struct ends
at 16 fields per the archive.

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

## Slice 3 — Simulator types + label coordinates (Chapters 55–57)

**Status: ready (no logic; types + label-builder only).**

Two files: types in `wat/sim/types.wat`, label-coordinate
machinery in `wat/sim/labels.wat`.

### `wat/sim/types.wat`

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

;; TriggerEvent now carries the surface (Chapter 55) — fed to the
;; future reckoner-backed Predictor with the back-filled label.
(:wat::core::struct :trading::sim::TriggerEvent
  (candle-i    :i64)
  (phase-label :trading::types::PhaseLabel)
  (decision    :trading::sim::Decision)
  (surface     :wat::holon::HolonAST))

(:wat::core::struct :trading::sim::LabeledTrigger
  (event       :trading::sim::TriggerEvent)
  (label       :trading::sim::TriggerLabel))

(:wat::core::struct :trading::sim::Paper ...)
;; Outcome carries the continuous paper-label per Chapter 57.
(:wat::core::struct :trading::sim::Outcome
  (paper          :trading::sim::Paper)
  (closed-at      :i64)
  (final-residue  :f64)
  (paper-label    :wat::holon::HolonAST)
  (labeled-trail  :Vec<trading::sim::LabeledTrigger>))

(:wat::core::struct :trading::sim::Aggregate ...)
(:wat::core::struct :trading::sim::Config ...)

;; Thinker (vocabulary) and Predictor (learner) — Chapter 55 split.
(:wat::core::struct :trading::sim::Thinker
  (build-surface :fn(:trading::types::Candles, :Option<trading::sim::Paper>)
                  -> :wat::holon::HolonAST))

(:wat::core::struct :trading::sim::Predictor
  (predict :fn(:wat::holon::HolonAST) -> :trading::sim::Action))
```

Plurals via typealias per arc 020's pattern:

```scheme
(:wat::core::typealias :trading::sim::Papers :Vec<trading::sim::Paper>)
(:wat::core::typealias :trading::sim::Outcomes :Vec<trading::sim::Outcome>)
(:wat::core::typealias :trading::sim::TriggerEvents :Vec<trading::sim::TriggerEvent>)
```

### `wat/sim/labels.wat` — label coordinates (Chapter 57)

Two basis atoms (`outcome-axis`, `direction-axis`) plus a label
builder. The label is a Bundle of axis-bindings with Thermometer-
encoded continuous values per Chapter 57. Range `[-0.05, +0.05]`
per sub-fog 5h.

```scheme
;; Basis atoms — the coordinate system's axes.
(:wat::core::define :trading::sim::outcome-axis
  (:wat::holon::Atom (:wat::core::quote :outcome)))

(:wat::core::define :trading::sim::direction-axis
  (:wat::holon::Atom (:wat::core::quote :direction)))

;; Continuous label builder — (residue, price-move) → coordinate.
;; Used at paper resolution to capture the actual magnitudes.
(:wat::core::define
  (:trading::sim::paper-label
    (residue    :f64)        ; signed: + Grace, - Violence
    (price-move :f64)        ; signed: + Up, - Down
    -> :wat::holon::HolonAST)
  (:explore::force
    (:wat::holon::Bundle
      (:wat::core::vec :wat::holon::HolonAST
        (:wat::holon::Bind :trading::sim::outcome-axis
          (:wat::holon::Thermometer residue    -0.05 0.05))
        (:wat::holon::Bind :trading::sim::direction-axis
          (:wat::holon::Thermometer price-move -0.05 0.05))))))

;; Reference corner labels — the four (±0.05, ±0.05) extremes.
;; v1's hand-coded Predictor (Q8) cosines a surface against these
;; for argmax-style classification. The reckoner-backed successor
;; Predictor will learn from continuous labels directly; corners
;; remain as reference points for human-readable queries.
(:wat::core::define :trading::sim::corner-grace-up
  (:trading::sim::paper-label  0.05  0.05))
(:wat::core::define :trading::sim::corner-grace-dn
  (:trading::sim::paper-label  0.05 -0.05))
(:wat::core::define :trading::sim::corner-violence-up
  (:trading::sim::paper-label -0.05  0.05))
(:wat::core::define :trading::sim::corner-violence-dn
  (:trading::sim::paper-label -0.05 -0.05))
```

**Tests** (`wat-tests/sim/types.wat` + `wat-tests/sim/labels.wat`):

13. **Construction round-trips** — every struct constructible + accessible.
14. **Variant construction** — `(Grace residue=42.0)`, `(Open Up)`, etc.
15. **TriggerEvent carries surface** — field round-trips an arbitrary HolonAST.
16. **Thinker + Predictor records constructible** — both wrap functions cleanly.
17. **`paper-label` round-trip** — magnitude flows through Thermometer
    encoding; `cosine(paper-label(0.04, 0.03), corner-grace-up)` is
    higher than `cosine(paper-label(0.04, 0.03), corner-violence-dn)`.
18. **Label structural similarity (Chapter 56)** — `cosine(corner-grace-up,
    corner-grace-dn) > cosine(corner-grace-up, corner-violence-dn)` because
    they share `outcome-axis` bind.

**Estimated cost:** ~150 LOC + 6 tests. ~Three quarters of a day.

---

## Slice 4 — Simulator engine

**Status: ready (after slices 1, 2, 3).**

`wat/sim/paper.wat`:

```scheme
;; Now takes Thinker + Predictor (Chapter 55 split).
(:trading::sim::run stream thinker predictor config → aggregate)

;; Internal helpers (not all public):
(:trading::sim::residue entry-price current-price direction principal fees → f64)
(:trading::sim::price-move entry-price current-price direction → f64)
(:trading::sim::evaluate-gates state position config phase-label → bool)
(:trading::sim::label-trail trail outcome → labeled-trail)
(:trading::sim::tick state candle config thinker predictor → state)
```

The engine's per-candle loop:

1. Advance ATR + PhaseState.
2. Build surface: `(thinker.build-surface window position)`.
3. Ask Predictor for Action: `(predictor.predict surface)`.
4. Append `(candle-i, phase-label, decision, surface)` to any open
   paper's trail at every Peak/Valley pass.
5. Apply Action against gates:
   - Action == `Exit` AND gates 1-3 pass → close Grace, build
     paper-label from (residue, price-move), back-fill trail.
   - Deadline reached → close Violence, build paper-label
     (negative outcome, signed price-move), back-fill trail.
   - Action == `(Open dir)` AND no open paper → open new paper.
   - Otherwise → continue.

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
24. **Surface recorded in trail (Chapter 55)** — verify each
    TriggerEvent's `surface` field carries the thinker's actual
    HolonAST output at that candle. Round-trip through resolution.
25. **Continuous paper-label at resolution (Chapter 57)** — Grace
    paper with `residue=$0.40` on `$10` principal → paper-label's
    outcome-axis Thermometer at +0.04. Direction-axis at the
    actual `(final-entry)/entry` magnitude.
26. **Predictor swap is the seam** — same Thinker, different
    Predictor function (e.g., always-Up vs cosine-vs-corners) →
    different Aggregate (different paper counts and outcomes).
    Proves the Chapter 55 split is real and the thinker doesn't
    leak prediction logic.

**Estimated cost:** ~300 LOC + 12 tests. Three days.
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
        :build-surface <surface-builder-fn>))
     ((predictor :trading::sim::Predictor)
      (:trading::sim::Predictor
        :predict <cosine-vs-corners-fn>))           ; Q8 hand-coded v1
     ((config :trading::sim::Config)
      (:trading::sim::Config
        :deadline 288 :min-residue 0.01 :fee-bps 35.0 :atr-period 14))
     ((agg :trading::sim::Aggregate)
      (:trading::sim::run-bounded stream thinker predictor config 10000)))   ; bounded variant
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

- Slice 1: 0.5 day (ATR + median window) — **shipped 2026-04-25**
- Slice 2: 1.5 days (PhaseState)
- Slice 3: 0.75 day (types + label coordinates)  — was 0.5 day; +0.25 day for label-builder + corner refs + 4 added tests (Chapters 55–57)
- Slice 4: 3 days (simulator engine — load-bearing)  — was 2.5 days; +0.5 day for Predictor wire-up + continuous label construction at resolution + 3 added tests
- Slice 5: 0.5 day (integration smoke)
- Slice 6: 1 hour (docs)

**~6.25 days end-to-end** (was 5.5 pre-Chapter-55–57 absorption).
Slice 1 already shipped. Slices 2–3 can ship in any order; slice
4 is still the gating chunk. The +0.75 day delta over the
original estimate is the price of absorbing the BOOK chapters'
recognitions before slice 4 writes against the wrong shape — a
strictly cheaper move than reshaping post-slice-4.
