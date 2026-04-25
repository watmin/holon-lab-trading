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
  ;; Trigger trail — every (candle-i, label, decision) the paper
  ;; passed through. Used for retroactive labeling at resolution.
  (trail           :Vec<trading::sim::TriggerEvent>))

(:wat::core::struct :trading::sim::TriggerEvent
  (candle-i :i64)
  (label    :trading::types::PhaseLabel)
  (decision :trading::sim::Decision))   ; Hold | Exit | NotEvaluated

(:wat::core::struct :trading::sim::Outcome
  (paper          :trading::sim::Paper)
  (closed-at      :i64)
  (final-residue  :f64)
  (labeled-trail  :Vec<trading::sim::LabeledTrigger>))   ; back-filled

(:wat::core::struct :trading::sim::Aggregate
  (papers           :i64)
  (grace-count      :i64)
  (violence-count   :i64)
  (total-residue    :f64)
  (total-loss       :f64))
```

The thinker abstraction (a wat function passed in) drives gate 4
(Exit/Hold) and proposes new papers. The simulator owns lifecycle
and gates 1-3:

```scheme
(:wat::core::define
  (:trading::sim::run
    (stream      :lab::candles::Stream)
    (thinker     :fn(window :trading::types::Candles, position :Option<trading::sim::Paper>) -> :trading::sim::Action)
    (config      :trading::sim::Config)
    -> :trading::sim::Aggregate)
  ;; For each candle pulled from stream:
  ;;   1. Advance ATR + PhaseState.
  ;;   2. For any open paper:
  ;;      - if at phase trigger AND market direction against AND residue > min:
  ;;        ask thinker for Exit/Hold decision (gate 4)
  ;;        if Exit: close Grace, retroactively label trail, record Outcome
  ;;      - elif candle-i >= paper.deadline-candle:
  ;;        close Violence, retroactively label trail, record Outcome
  ;;   3. If no open paper: ask thinker for proposal.
  ;;      If Proposed Up/Down: open new paper at this candle's close.
  ;;   4. Append to trigger trail at every Peak/Valley pass.
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

### Q1 — Pull PhaseState forward, or use a placeholder?

**Forward.** A placeholder phase-trigger ("every K candles") would
let the simulator run, but every paper resolution would label its
trail with stand-in trigger events. The retroactive labeling that
the position observer eventually trains on (Proposal 055) needs
*real* trigger events to be a useful supervised signal. Shipping
PhaseState now means the trigger trail is honest from day one.

The cost is small: PhaseState is ~150 lines of pure state-machine
in the archive. Wat translation is mechanical.

### Q2 — Implement gate 4 (position observer) now, or later?

**Later.** Gate 4 is "the learned decision." The learner
(Reckoner accepting HolonAST labels per the 2026-04-25 holon-rs
update) lands in Phase 4. Until then, the simulator's gate 4
slot accepts a thinker-supplied function. v1 thinkers can be
hand-coded ("always Exit if gates 1-3 pass") — a learned thinker
plugs in without changing the simulator.

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

### Q6 — Thinker signature

Two callbacks needed:

- `(thinker/propose? window) -> Option<Direction>` — call when no
  open paper.
- `(thinker/should-exit? window position) -> bool` — call at every
  candle; gates 1-3 are arithmetic prerequisites checked by the
  simulator, gate 4 is this function.

Pass them as a record (a wat struct holding two function values)
or as two separate parameters. Lean: **record** — easier to extend
when learned thinkers add per-call state.

```scheme
(:wat::core::struct :trading::sim::Thinker
  (propose?     :fn(:trading::types::Candles) -> :Option<trading::sim::Direction>)
  (should-exit? :fn(:trading::types::Candles, :trading::sim::Paper) -> :bool))
```

### Q7 — Multi-broker support in v1?

**Single broker for v1.** Multi-broker (the actual gamification —
many thinkers competing on residue, ladder enforced by their
records) is a follow-up arc. v1 proves the simulator's lifecycle
on one thinker; multi-broker generalizes by running N simulators
in parallel and aggregating per-broker `ProposerRecord`. The
parallelism is CSP — we already have wat's `make-bounded-queue`
+ `spawn`.

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

---

## What this arc does NOT add

- **The position observer (gate 4 learner).** Phase 4. Slot's
  reserved in the simulator's thinker abstraction.
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
  the simulator with a Reckoner-driven thinker; compare residue
  to a baseline. WindowSampler port? Same. IndicatorBank port?
  Same.
- **Encoding-experiment regression detection.** Form-atoms vs
  Permute-rhythm (experiment 007's verdict) — the simulator can
  re-run the comparison on actual market data and produce a
  residue delta, not just a cosine ratio.
- **Reproducible run history.** The aggregate is deterministic
  from `(stream, thinker, config)`. Runs are comparable. Memory
  feedback_never_delete_runs holds.
- **The first real ProposerRecord trail.** Once multi-broker
  ships, trust ladder slots in cleanly.
- **Phase 5's IndicatorBank port has a head start** (ATR + Phase
  state already in wat).
