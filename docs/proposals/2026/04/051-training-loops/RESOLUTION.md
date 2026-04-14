# Resolution: Proposal 051 — Training Loops

**Decision: APPROVED. Delete the binary path. Keep the continuous reckoners.**

Five voices. Two rounds. One ignorant. Twenty-two files of debate.
One answer.

## Change 1: Delete the binary Grace/Violence learning path

The position observer receives two contradictory teachers:

**Path A (stays):** `observe_scalar(reckoner, thought, optimal, weight)`.
The continuous reckoners learn: "for THIS thought, the optimal
trail was X." The simulation provides the optimal. The reckoner
accumulates. This is the honest teacher.

**Path B (deleted):** The journey grading. Error ratio against a
rolling percentile median. Binary Grace/Violence label. Feeds
`outcome_window` and `residue_window`. Produces `grace_rate` and
`avg_residue` atoms that loop back into the next thought encoding.
The Red Queen. The limit cycle. grace_rate → 0.0.

### The surgery

**`src/programs/app/broker_program.rs`:**
- Delete the deferred batch training loop (the journey grading
  section that computes error ratios and sends ExitLearn with
  is_grace/residue). Lines ~196-229 approximately.
- Keep the immediate resolution signal that sends optimal
  distances to the position observer.
- Remove `journey_errors: VecDeque<f64>` usage (already on Broker).

**`src/domain/broker.rs`:**
- Remove `journey_errors: VecDeque<f64>` field from Broker.

**`src/programs/app/position_observer_program.rs`:**
- Remove `is_grace` and `residue` fields from `PositionLearn`.
- Update `drain_position_learn` to not pass them.

**`src/domain/position_observer.rs`:**
- Remove `outcome_window: VecDeque<bool>`.
- Remove `residue_window: VecDeque<f64>`.
- Remove `grace_rate: f64` and `avg_residue: f64` fields.
- Remove lines 153-170 from `observe_distances` (the self-
  assessment window update). Keep lines 150-151 (the continuous
  reckoner observe_scalar calls).

**`src/vocab/exit/self_assessment.rs`:**
- Remove `grace_rate` and `avg_residue` atoms. Or remove the
  entire file if nothing else uses it.

**`src/domain/lens.rs`:**
- Remove `position_self_assessment_facts` call (or update it
  to not include grace_rate/avg_residue).

**`src/types/log_entry.rs`:**
- Remove `grace_rate` and `avg_residue` from
  PositionObserverSnapshot. Or keep as 0.0 placeholders until
  a replacement metric is designed.

### What stays

- `observe_scalar(trail_reckoner, thought, optimal_trail, weight)`
- `observe_scalar(stop_reckoner, thought, optimal_stop, weight)`
- The continuous reckoners accumulating from honest signal
- The market context atoms (regime, time, phase)
- The trade atoms (excursion, retracement, age, etc.)
- The phase series (Sequential encoding)
- The noise subspace (stripping normal from signal)

### What this fixes

1. The Red Queen limit cycle — no rolling median, no self-reference
2. Direction contamination — removed. The continuous reckoners
   learn from simulation-optimal distances, not trade outcomes
3. The contradictory teachers — one path, one signal
4. grace_rate oscillating to 0.0 — the oscillation source is gone

### What comes after (empirical, not this proposal)

- Measure: run 10k, query DB, does the position observer converge?
- R-multiple normalization (Van Tharp)
- Broker reckoner restoration with clean signals
- Phase boundary weight scaling
- Volume-price divergence atoms (Wyckoff)

### The principle (Seykota)

Never give a continuous learner a binary teacher.

### The invariant (Beckman)

No learner shall be graded against a statistic derived from
its own output distribution.
