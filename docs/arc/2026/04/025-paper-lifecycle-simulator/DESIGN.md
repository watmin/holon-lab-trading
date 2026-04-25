# lab arc 025 — Paper Lifecycle Simulator (the yardstick)

**Status:** opened 2026-04-25.

**Scope:** medium. Three slices: ATR + PhaseState ports (pulls Phase
1.5's deferred state machine + a Phase 5 indicator forward), then
the simulator itself (cross-Phase 5/9 territory, justified below).

Builder direction:

> "i want to build the yardstick now... we measure who is strongly
> labeled and make predictions... do you understand?... go study
> the 055 or 056 proposals for more context"

> "describe A in an arc - i'll get it built"

This arc opens the lab's first **measurement** layer. Every Phase
4–9 port needs a yardstick to tell us whether it's correct. Today
nothing does.

Cross-references:
- [`docs/proposals/2026/04/055-treasury-driven-resolution/RESOLUTION.md`](../../proposals/2026/04/055-treasury-driven-resolution/RESOLUTION.md) — the four-gate Grace/Violence model this simulator implements.
- [`docs/proposals/2026/04/049-phase-labeler/`](../../proposals/2026/04/049-phase-labeler/) — the PhaseState semantics (Peak/Valley/Transition; smoothing = 2× ATR median).
- [`docs/proposals/2026/04/021-reward-cascade/PROPOSAL.md`](../../proposals/2026/04/021-reward-cascade/PROPOSAL.md) — the three-event learning cascade (market obs / exit obs / broker each labeled at distinct moments).
- [`docs/rewrite-backlog.md`](../../rewrite-backlog.md) — Phase 1.5 (PhaseState deferred to Phase 5), Phase 5 (`simulation.rs`, `indicator_bank.rs`).
- [`archived/pre-wat-native/src/types/pivot.rs`](../../../archived/pre-wat-native/src/types/pivot.rs) — `PhaseState` reference impl (~150L state machine).
- [`archived/pre-wat-native/src/domain/indicator_bank.rs:325-354`](../../../archived/pre-wat-native/src/domain/indicator_bank.rs) — `AtrState` reference impl (Wilder-smoothed true range, period 14).
- [`BOOK.md` Chapter 55 — The Bridge](../../../BOOK.md) — two oracles (cache + reckoner); thinker reshapes from prediction-emitter to AST-builder.
- [`BOOK.md` Chapter 56 — Labels as Coordinates](../../../BOOK.md) — labels live in a coordinate system; two construction styles (implicit AST, explicit axis-bindings).
- [`BOOK.md` Chapter 57 — The Continuum](../../../BOOK.md) — every binary distinction is the discretization of a continuum the substrate already encodes; v1 labels ship Thermometer-encoded axes from day one.

---

## Architecture absorbed from BOOK Chapters 55–57

Three recognitions landed mid-arc, before slices 2-6 wrote against
the old shape. They reshape the simulator's external contract;
internal mechanics (lifecycle, gates, deadline, retroactive
labeling) are unchanged.

### From Chapter 55 — Thinker reshape

The thinker stops emitting `Up | Down`. It emits a *surface AST*
— a thought with concrete values plugged in. The simulator hands
that surface to a separate **Predictor** which returns the Action
(Open Up / Open Down / Hold / Exit). The thinker is a vocabulary;
the predictor is the learner. v1 ships a hand-coded predictor;
a successor arc swaps in a reckoner-backed one once labels
accumulate.

### From Chapter 56 — Labels as coordinates

Labels are positions in a coordinate system, not discrete tokens.
Style B (explicit axis-bindings) is what the substrate naturally
encodes. The Predictor's `label-set` is `:Vec<HolonAST>` of
coordinate-bundles.

### From Chapter 57 — Continuous axes

Each axis is a Thermometer-encoded continuous value, not a
discrete atom. The 2×2 grid `(:Grace :Up)` etc. is just the four
extreme corners of a 2D continuous plane. v1 ships **two axes**
(outcome × direction) over `[-0.05, +0.05]` each — the honest
band for 5-min crypto candles. The third+ axes (duration,
phase-count, excursion) defer to a successor arc when sample
efficiency justifies them.

The four corner labels are derived references for argmax queries;
the *training* labels are continuous Thermometer positions
captured at exact resolution magnitudes.

---

## Why this arc, why now

The rewrite-backlog has Phases 4–9 marked **foggy**: the learning
machinery (Reckoner, OnlineSubspace, WindowSampler), the domain
layer (observers, broker, treasury, IndicatorBank), and the
integration tests are all "scoped but unbuilt." Each one will be
ported, ward-checked, and shipped — but until something measures
whether the port produces the *same residue trajectory* the
archive did, every slice is parity-by-faith.

The yardstick this arc ships is the substitute for that faith.
Given:

- a candle source (Phase 0's `:lab::candles::Stream`, shipped),
- a thinker — any wat function `(window → :Up | :Down)` —,
- a deadline + minimum-residue config,

the simulator runs the four-gate paper lifecycle from Proposal 055
and reports `(grace_count, violence_count, total_residue)` per
broker over arbitrary stretches of the 6-year BTC parquet. That
number is the comparable thing — the floor every encoding
experiment, observer port, and parameter sweep can be measured
against.

A side effect: the simulator forces us to land **PhaseState** and
**ATR** in wat now (rewrite-backlog deferred PhaseState to Phase
5 with IndicatorBank). Pulling those forward isn't a violation of
the leaves-to-root order — it's recognizing that a working
yardstick is a leaf the rest of the rewrite *depends on* for
correctness validation. Phase 5's IndicatorBank port re-uses the
exact same PhaseState + ATR implementations when it ships; this
arc's work isn't thrown away, it's the IndicatorBank's first
piece arriving early because a downstream consumer needs it.

---

## What ships

Three modules in `wat/`, then the simulator:

### 1. `wat/encoding/atr.wat` — Wilder-smoothed true range

```scheme
(:wat::core::struct :trading::encoding::AtrState
  (period      :i64)
  (value       :f64)     ; current Wilder-smoothed ATR
  (prev-close  :f64)
  (count       :i64)     ; for ready? gate at first `period` candles
  (started     :bool))

(:wat::core::define
  (:trading::encoding::atr-update
    (state :trading::encoding::AtrState)
    (high :f64) (low :f64) (close :f64)
    -> :trading::encoding::AtrState)
  ;; True range: max(high-low, |high-prev_close|, |low-prev_close|)
  ;; Wilder smoothing: SMA over first `period`, then EMA(α=1/period)
  ;; Values-up: returns updated state.
  ...)

(:wat::core::define
  (:trading::encoding::atr-ready?
    (state :trading::encoding::AtrState)
    -> :bool)
  ...)
```

Direct port of `archived/pre-wat-native/src/domain/indicator_bank.rs`
`AtrState` (lines 315-354) + the Wilder helper. ~50 lines of wat.

### 2. `wat/encoding/phase-state.wat` — the streaming state machine

```scheme
(:wat::core::enum :trading::encoding::TrackingState
  :Rising :Falling)

(:wat::core::struct :trading::encoding::PhaseState
  (tracking          :trading::encoding::TrackingState)
  (current-label     :trading::types::PhaseLabel)
  (current-direction :trading::types::PhaseDirection)
  (extreme           :f64)
  (extreme-candle    :i64)
  (current-start     :i64)
  (count             :i64)
  ;; Phase-record accumulators (close-sum, volume-sum, high, low,
  ;; open-close, last-close) — all f64. Closed phases append to
  ;; phase-history (Vec<PhaseRecord>); trimmed by age (2016-candle
  ;; window).
  (phase-history     :trading::types::PhaseRecords)
  (generation        :i64))

(:wat::core::define
  (:trading::encoding::phase-step
    (state     :trading::encoding::PhaseState)
    (close     :f64)
    (volume    :f64)
    (candle-i  :i64)
    (smoothing :f64)             ; 2 × ATR-week-median per Proposal 052
    -> :trading::encoding::PhaseState)
  ;; The label state machine — rising/falling track + Peak/Valley
  ;; classification at half-smoothing of the extreme. On label
  ;; change: close the old phase into a PhaseRecord, push to
  ;; history, trim history older than 2016 candles, begin new phase.
  ...)
```

Direct port of `pivot.rs` (the `PhaseState` impl, lines 95-282).
The types (`PhaseLabel`, `PhaseDirection`, `PhaseRecord`) already
shipped in Phase 1.5 (`wat/types/pivot.wat`). `TrackingState` is
new (it's internal to PhaseState in the archive — `pub(crate)`-ish).

### 3. `wat/encoding/atr-window.wat` — median-ATR over a buffer

A small piece needed for `smoothing = 2 × median_atr_week`.
~30 lines: ring-buffer of ATR values (length 2016 = 1 week of
5-min candles), `median` via sort + middle pick. Could use
`:Vec<f64>` directly with an append-and-trim pattern.

### 4. `wat/sim/paper.wat` — the simulator

The lifecycle, deadline, four gates, retroactive labeling.

```scheme
(:wat::core::enum :trading::sim::Direction :Up :Down)

(:wat::core::enum :trading::sim::PositionState
  :Active
  (Grace   (residue :f64))
  (Violence))

(:wat::core::struct :trading::sim::Paper
  (id              :i64)
  (direction       :trading::sim::Direction)
  (entry-price     :f64)
  (entry-candle    :i64)
  (deadline-candle :i64)
  (state           :trading::sim::PositionState)
  ;; Trigger trail — every (candle-i, phase-label, decision, surface)
  ;; the paper passed through. Used for retroactive labeling at
  ;; resolution. The `surface` field carries the thought-AST the
  ;; thinker built at that candle (per Chapter 55) — fed to the
  ;; reckoner with the back-filled label.
  (trail           :Vec<trading::sim::TriggerEvent>))

(:wat::core::struct :trading::sim::TriggerEvent
  (candle-i    :i64)
  (phase-label :trading::types::PhaseLabel)
  (decision    :trading::sim::Decision)   ; Hold | Exit | NotEvaluated
  (surface     :wat::holon::HolonAST))    ; thinker's surface AST at this candle

(:wat::core::struct :trading::sim::Outcome
  (paper          :trading::sim::Paper)
  (closed-at      :i64)
  (final-residue  :f64)
  (paper-label    :wat::holon::HolonAST)   ; continuous label, per Ch.57
  (labeled-trail  :Vec<trading::sim::LabeledTrigger>))   ; back-filled

(:wat::core::struct :trading::sim::Aggregate
  (papers           :i64)
  (grace-count      :i64)
  (violence-count   :i64)
  (total-residue    :f64)
  (total-loss       :f64))
```

Per Chapter 55 the thinker emits a *surface AST*; a separate
**Predictor** turns the surface into an Action. The simulator
owns lifecycle, gates 1-3, and the trail-back-fill at resolution.

```scheme
(:wat::core::define
  (:trading::sim::run
    (stream      :lab::candles::Stream)
    (thinker     :trading::sim::Thinker)        ; surface builder (vocabulary)
    (predictor   :trading::sim::Predictor)      ; surface → Action (learner slot)
    (config      :trading::sim::Config)
    -> :trading::sim::Aggregate)
  ;; For each candle pulled from stream:
  ;;   1. Advance ATR + PhaseState.
  ;;   2. Build surface for this candle: (thinker.build-surface window position).
  ;;   3. Ask predictor for Action: (predictor.predict surface).
  ;;   4. For any open paper:
  ;;      - if at phase trigger AND market direction against AND residue > min:
  ;;        if Action == Exit: close Grace, retroactively label trail, record Outcome
  ;;      - elif candle-i >= paper.deadline-candle:
  ;;        close Violence, retroactively label trail, record Outcome
  ;;   5. If no open paper and Action == (Open dir):
  ;;      open new paper at this candle's close.
  ;;   6. Append (candle-i, phase-label, decision, surface) to trigger trail
  ;;      at every Peak/Valley pass.
  ;; At resolution: build paper-label from (residue, price-move) per Ch.57;
  ;; back-fill trail with retroactive trigger labels per Proposal 055.
  ;; Returns aggregate stats over the whole run.
  ...)

(:wat::core::struct :trading::sim::Config
  (deadline      :i64)        ; v1: static 288 candles (1 day)
  (min-residue   :f64)        ; v1: 0.01 (1% — clears 0.7% round-trip cost floor)
  (fee-bps       :f64)        ; v1: 35 (0.35% per swap, per memory)
  (atr-period    :i64))       ; v1: 14 (Wilder convention)
```

`trading::sim::Action` is one of:
- `(Open dir)` — propose a new paper
- `Hold` — stay flat or stay in current paper
- `Exit` — close current paper if eligible

---

## Decisions resolved

**Q1–Q9 below.** Q10–Q14 resolved later (mid-slice-5 design pause)
and live in their own doc:
[`slice-4-5-design-questions.md`](slice-4-5-design-questions.md) —
corner→Action map, surface basis, v1 thinker vocabularies, slice 5
test scope, `Option<Paper>` use. Read both for the full design
ledger.

### Q1 — Pull PhaseState forward, or use a placeholder?

**Forward.** A placeholder phase-trigger ("every K candles") would
let the simulator run, but every paper resolution would label its
trail with stand-in trigger events. The retroactive labeling that
the position observer eventually trains on (Proposal 055) needs
*real* trigger events to be a useful supervised signal. Shipping
PhaseState now means the trigger trail is honest from day one.

The cost is small: PhaseState is ~150 lines of pure state-machine
in the archive. Wat translation is mechanical.

### Q2 — Implement gate 4 (the learned decision) now, or later?

**Later — but cleanly slotted.** Per Chapter 55, gate 4 is the
**Predictor's** job. The Predictor takes a surface AST and returns
an Action. v1 ships a hand-coded Predictor (e.g., cosine-against-
four-corner-references; argmax). Surfaces and continuous labels
get recorded for every paper; the future reckoner-backed Predictor
trains on accumulated `(surface, label)` pairs and swaps in at the
same call site without re-architecting the simulator. The slot is
typed (`:trading::sim::Predictor`), so the swap is one struct
substitution.

### Q3 — Static deadline, or trust-scaled?

**Static for v1, trust-scaled later.** Proposal 055 specifies the
ladder: untrusted brokers cap at 288 candles (1 day); fully
trusted reach 2016 candles (1 week); position in the ladder
derives from `ProposerRecord`. The ladder requires `ProposerRecord`
plumbing across multiple papers, which is its own piece of work.
v1 ships static `deadline = 288` for everyone; the ladder is a
follow-up slice.

### Q4 — Where does the simulator live in the wat tree?

**`wat/sim/`.** New top-level subtree. Justified because the
simulator isn't a vocab module (Phase 2), an encoder (Phase 3), a
learner (Phase 4), or a domain entity (Phase 5) — it's a
*measurement instrument*. Sibling to `wat/encoding/` /
`wat/vocab/` / `wat/types/`.

This subtree will grow. A natural Phase 9 follow-up is per-broker
aggregation, a multi-broker tournament runner, and ledger output
for run history.

### Q5 — Bound on memory?

The simulator buffers (a) the candle window the thinker reads
from, (b) any open paper's trigger trail, (c) per-broker
aggregates. (a) is bounded by the thinker's window size (small).
(b) is bounded by the deadline (288 candles max for v1) ×
fraction-of-candles-that-are-triggers (~5% empirically; ~14
events per trail). (c) is one struct per broker.

All bounded. No runaway state. The simulator can run the full
6-year stream without buffering the whole stream.

### Q6 — Thinker + Predictor signatures (Chapter 55)

The thinker is a vocabulary; the predictor is the learner. Two
structs, two responsibilities. They evolve independently —
vocabularies get added freely; predictors swap from hand-coded →
reckoner-backed once labels accumulate.

```scheme
;; The vocabulary — given a window + optional open paper, build
;; a thought-AST with concrete values. Stateless about outcomes.
(:wat::core::struct :trading::sim::Thinker
  (build-surface :fn(:trading::types::Candles, :Option<trading::sim::Paper>)
                  -> :wat::holon::HolonAST))

;; The learner — given a surface, return the Action. v1 is
;; hand-coded (e.g., cosine-vs-corner-references); a successor
;; arc replaces with reckoner-backed.
(:wat::core::struct :trading::sim::Predictor
  (predict :fn(:wat::holon::HolonAST) -> :trading::sim::Action))
```

Style B label coordinates and the `paper-label` helper land in
slice 3 alongside these. The Predictor's `label-set` (when the
reckoner-backed version arrives) consumes those coordinates
directly.

### Q7 — Multi-broker support in v1?

**Single broker for v1.** Multi-broker (the actual gamification —
many thinkers competing on residue, ladder enforced by their
records) is a follow-up arc. v1 proves the simulator's lifecycle
on one thinker; multi-broker generalizes by running N simulators
in parallel and aggregating per-broker `ProposerRecord`. The
parallelism is CSP — we already have wat's `make-bounded-queue`
+ `spawn`.

### Q8 — How does v1 ship without the reckoner?

**Hand-coded Predictor; surfaces and labels recorded for the
future reckoner.** Three concrete v1 Predictors that prove the
shape:

- **`always-Up`** — predict opens always-Up; Exit at first phase
  trigger (gates 1-3 willing). Baseline.
- **`always-Hold`** — predict never opens. Empty aggregate.
  Sanity check.
- **`cosine-vs-corners`** — given a surface, cosine against the
  four reference corner labels (Style B coordinate corners at
  `(±0.05, ±0.05)`). Argmax → Action via a small lookup table.
  Closest thing to "real" without a learner.

In all three v1 cases, the simulator records `(surface,
continuous-label)` pairs for every resolved paper. The successor
arc that ships the reckoner-backed Predictor reads that recorded
data and trains; the swap happens without changing the simulator
or the Thinker.

### Q9 — How many label axes for v1? (Chapter 57)

**Two: outcome × direction.** Both Thermometer-encoded over
`[-0.05, +0.05]`:

- **outcome-axis** — `residue / principal`, signed. Positive
  Grace, negative Violence. Range based on the empirical band of
  5-min crypto papers within a 1-day deadline (rare to clear ±5%).
- **direction-axis** — `(final_close - entry_close) / entry_close`,
  signed. Positive Up, negative Down. Same range justification.

Third+ axes (duration / phase-count / max-favorable-excursion)
are deliberately deferred. The substrate handles N dimensions
identically; the bottleneck is *sample efficiency* — joint cell
count grows multiplicatively, and v1 needs to prove the 2D plane
populates cleanly before adding more dimensions. Successor arc
adds the third axis when a query against it has a real caller.

---

## Implementation sketch — slice-by-slice

### Slice 1 — ATR + median window

`wat/encoding/atr.wat` + `wat/encoding/atr-window.wat`. ~80 lines.
Tests: deterministic, ready? gate, true-range computation,
Wilder smoothing convergence over period candles, median-of-2016.

### Slice 2 — PhaseState

`wat/encoding/phase-state.wat`. ~200 lines (substantial; mirrors
`pivot.rs` structure). Tests: initial state, single-step, valley→
peak transition (canonical case from `pivot.rs:test_full_cycle`),
peak-at-high-valley-at-low correctness, history time-trim. Use
the archive's tests as the spec.

### Slice 3 — Simulator types

`wat/sim/types.wat`. The types (`Direction`, `PositionState`,
`Paper`, `TriggerEvent`, `Outcome`, `Aggregate`, `Config`,
`Thinker`). ~100 lines. No logic; just type defs.

### Slice 4 — Simulator engine

`wat/sim/paper.wat`. The actual `(:trading::sim::run ...)` function.
~250 lines. Tests:

1. Empty stream → empty aggregate.
2. Always-Hold thinker → 0 papers, 0/0 grace/violence.
3. Always-Up thinker over 1 day → exactly one paper, deadline hit
   at 288 → Violence (Up didn't trigger Grace conditions, gate 1
   needs Peak which a constant-Up doesn't reach).
4. Up-thinker that exits at first Peak after entry → some Grace
   if a Peak forms within the deadline; verify residue computed
   correctly.
5. Down-thinker with same dynamics on the symmetric side.
6. Retroactive labeling — verify trail labels match paper outcome
   (Grace at T → T labeled Exit; Violence after passing through
   T → T labeled "should-have-Exited").

### Slice 5 — End-to-end smoke against real data

A `wat-tests/sim/integration.wat` test that opens
`data/btc_5m_raw.parquet`, runs an "always-Up at every candle,
exit at every Peak" thinker over the first 10,000 candles, asserts
aggregate.papers > 0, aggregate.total_residue is finite. No
correctness assertion on the *value* — just that the simulator
runs end-to-end against real BTC without crashing.

### Slice 6 — INSCRIPTION + cross-link

INSCRIPTION.md + cross-references update in `rewrite-backlog.md`:

- Phase 1.5's PhaseState deferral → "shipped early in arc 025"
- Phase 5's `AtrState` from `indicator_bank.rs:315` → "shipped
  early in arc 025"
- Note that the rest of `indicator_bank.rs` (the other 100+
  indicators) still ships in Phase 5.

---

## Tests — total budget

~25 tests across slices 1-5. Phase 1.5 currently tests three
PhaseState behaviors at the wat level (none yet — types only); 25
new tests grow lab wat-test count from 152 (today, including the
candle stream smoke test) to ~177. Self-imposed budget: every
slice green on first pass before moving to the next.

---

## Sub-fogs

### 5a — Smoothing parameter source for v1

PhaseState's `smoothing` parameter is `2 × ATR-week-median`. Until
1 week of data is consumed (2016 candles), the median window isn't
full and `smoothing` is degenerate. Options:

- Wait for the median window to fill before any phase trigger
  fires. Simulator skips trigger logic for the first 2016 candles.
- Use a degraded smoothing (e.g., `2 × current ATR` if median
  unavailable). Less honest but lets the simulator run from candle
  ~14 (when ATR is ready).

**Decision: Wait.** Honest. The 2016-candle warmup is small
relative to the 652k-candle dataset. Documented as a parameter.

### 5b — ATR period default

Wilder convention is period 14. The archive uses 14. Lock.

### 5e — Substrate gap surfaced by slice 1: sort-by missing

**Resolved 2026-04-25 (during slice 1).** wat-rs had no sort
primitive. AtrWindow's `median` needs a sort. Substrate uplift
shipped: `:wat::core::sort-by xs less?` — single predicate-driven
form (Common Lisp tradition; user picks asc/desc/key by which way
the predicate compares). Wraps Rust's `Vec::sort_by`; two-sided
predicate test for stable-sort semantics. Same carry-along pattern
as `string::concat` during arc 055.

This is the kind of gap arc 025 was always going to surface —
"every Phase 4–9 port can be measured" relies on the substrate
having the verbs the simulator needs. Sort, concat, and recursive
patterns landed in three days. Future slices may surface more.

### 5i — Substrate gaps surfaced by slice 2: `not=` + Enum equality

**Resolved 2026-04-25 (during slice 2).** PhaseState's boundary
check `if new_label != current_phase_label` exposed two missing
pieces:

1. **`:wat::core::not=`** — no inequality primitive in wat. Shipped
   Clojure-tradition `not=` (over C-style `!=`) consistent with the
   substrate's Lisp-shaped operator lineage. Shares
   `infer_polymorphic_compare` with `=`; runtime is `not(=)`.
2. **Enum equality** — `values_equal` (the runtime kernel for `=`)
   had arms for primitives, Vec, Tuple, Option, Result, Vector,
   Struct — but not Enum. Two `Value::Enum`s comparing errored with
   "TypeMismatch — got: Enum." Added an Enum arm: equal iff same
   `type_path`, same `variant_name`, structurally-equal fields. Both
   `=` and `not=` on enums work after this.

Both ship as carry-along uplifts in wat-rs (parallel to slice 1's
`sort-by` and arc 055's `string::concat`). Same rhythm: arc 025
forces gaps the substrate had; gaps fill on demand; the lab keeps
moving.

### 5f — `:wat::core::nth` doesn't exist; `:get` returns Option

Substrate's design philosophy (`feedback_shim_panic_vs_option`):
lookups return `:Option<T>`, not bare `T`. The DESIGN sketched
`(:nth sorted mid)` for indexed access; AtrWindow's median uses
`(:get sorted mid) -> :Option<f64>` instead, with match-with-
impossible-None (sentinel; the call site has already gated `n > 0`
and `mid ∈ [0, n)`). Same shape will recur across slices 2–4 for
trail back-fill / phase-history access; standardize the pattern.

### 5c — Fee model granularity

v1 uses a single `fee-bps` parameter (35 bps = 0.35% per swap,
matching the project_venue_costs.md memory). Round-trip cost is
2 × fee-bps = 0.7% of principal. `min-residue` must clear that —
v1 default is 1% per discussion.

Future: per-pair fee curves, slippage modeling, MEV factors. Not
v1's problem.

### 5d — Retroactive labeling — what label set?

Per Proposal 055: triggers labeled at resolution as `Exit` (the
right call, taken or could-have-been-taken) or `Hold` (the right
call, kept). v1 ships a 3-variant label:

```scheme
(:wat::core::enum :trading::sim::TriggerLabel
  :Exit       ; took the exit at this trigger and Grace'd; OR held but should-have-Exit'd (deadline came)
  :Hold       ; held through this trigger and later Grace'd
  :Unknown)   ; trail of an unresolved/active paper — not yet labelable
```

Refinement: split `:Exit` into "took it" vs "missed it" if needed
for the position observer's training. Defer until the learner
slice surfaces a need.

### 5g — Cache wire-up (Chapter 55) — successor arc

The substrate's "have I proven this surface terminates?" cache
(per Chapter 55) is an *optimization*, not a correctness
mechanism. The simulator runs without it. A successor arc wires
wat-lru into the substrate's encode path, keyed by simhash, so
hot surfaces share termination proofs across thinkers. Out of
scope for arc 025; named here so the v1 simulator's encode calls
go through the substrate's standard path (which the cache will
later transparently absorb).

### 5h — Continuous label range — `[-0.05, +0.05]`

Two empirical justifications for the band:

- **5-min BTC candles rarely move >5% within 288 candles** (the
  v1 deadline = 1 day). Outliers exist; the Thermometer clamps at
  the edges. The vast majority of papers fall in the middle of
  the range, where the encoding has full resolution.
- **Round-trip venue cost is 0.7%** (per the project_venue_costs
  memory). `min-residue` is set at 1% to clear the cost floor.
  A label at `outcome = +0.01` (1%) is the v1 threshold; labels
  inside `±0.005` are sub-floor noise. The band gives ~10× the
  noise-floor resolution.

If real data shows the band is wrong (e.g., 5min papers cluster
inside `±0.01`, wasting 80% of the Thermometer range on outliers
that never appear), the band tightens. v1 ships `±0.05` as a
defensible first guess; the sim records actual magnitudes, so we
have the data to revise from the first run.

---

## What this arc does NOT add

- **Reckoner-backed Predictor.** v1 ships a hand-coded Predictor
  (Q8). Successor arc swaps in reckoner-backed once labels
  accumulate from resolved papers. Slot is typed, swap is one
  struct substitution.
- **Cache wire-up (Chapter 55).** The substrate's termination
  cache via wat-lru is a successor arc (5g). v1 simulator runs
  through the standard encode path; cache will absorb it
  transparently.
- **Third+ label axes.** Two axes for v1 (outcome × direction);
  duration / phase-count / excursion deferred (Q9).
- **The trust ladder / ProposerRecord.** Static deadline for v1.
  Ladder is a follow-up.
- **Multi-broker tournament.** Single broker for v1. Multi is
  CSP-parallel; the simulator generalizes naturally.
- **Real treasury rebalancing.** Papers are bookkeeping only — no
  USDC or WBTC moves. RealPosition (capital actually committed)
  is Phase 5/post arc territory.
- **Slippage / MEV / venue routing.** v1's `fee-bps` is a single
  parameter. Modeling venue dynamics is a separate concern.
- **The remaining 100+ indicators in `indicator_bank.rs`.** Only
  ATR ports here. The rest stay in Phase 5.
- **A learned thinker.** v1 ships hand-coded thinkers (always-Up,
  always-Down, simple-MA-crossover) for testing. Learned thinkers
  are Phase 4 work.
- **Paper proposing logic for the broker.** v1's thinker is asked
  by the simulator. A real broker proposes opportunistically; v1
  is "ask every candle." Convergence later.

---

## Non-goals

- **Performance optimization.** v1 prioritizes correctness; the
  6-year stream is ~650k candles, so even a naive simulator at
  ~10k candles/sec finishes in ~65s. Optimize when a hot path
  surfaces.
- **Streaming output.** v1 returns the aggregate at end of run.
  Per-paper streaming (for live observation) is follow-up.
- **GUI / viz.** Out of scope. The yardstick is a number-emitter;
  visualization comes later.
- **Cross-pair simulation.** v1 simulates one pair (BTC). Multi-
  pair (the BOOK Chapter "deeper pool") is post-Phase-5.

---

## What this unblocks

- **Every Phase 4–9 port can be measured.** Reckoner port? Run
  the simulator with a Reckoner-driven Predictor; compare residue
  to a baseline. WindowSampler port? Same. IndicatorBank port?
  Same.
- **Trail-as-training-data (Chapter 55).** Every resolved paper
  produces a labeled `(surface, continuous-label)` sequence —
  the future reckoner-backed Predictor consumes this directly.
  No extra plumbing needed when the swap arrives.
- **Predictor swap.** Hand-coded → reckoner-backed is a one-struct
  substitution at the simulator's call site. The Thinker (the
  vocabulary) doesn't change; only the learner does.
- **Continuous label space (Chapter 57).** v1 ships continuous
  axes from day one. Future axes (duration, phase-count, etc.)
  layer in via `paper-label`'s parameter list — the substrate's
  Bundle absorbs new axis-bindings without re-architecture.
- **Encoding-experiment regression detection.** Form-atoms vs
  Permute-rhythm (experiment 007's verdict) — the simulator can
  re-run the comparison on actual market data and produce a
  residue delta, not just a cosine ratio.
- **Reproducible run history.** The aggregate is deterministic
  from `(stream, thinker, predictor, config)`. Runs are
  comparable. Memory feedback_never_delete_runs holds.
- **The first real ProposerRecord trail.** Once multi-broker
  ships, trust ladder slots in cleanly.
- **Phase 5's IndicatorBank port has a head start** (ATR + Phase
  state already in wat).
