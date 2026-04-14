# Response to the Ignorant: Hickey

The ignorant read 17 documents and emerged knowing what to delete, but
not where. That is the correct outcome from reading specifications. The
ignorant also found real problems the five voices failed to address.
Let me take these one at a time.

---

## On the unresolved contradictions

**The broker composition (remove vs gate vs keep):** The ignorant is
right that three voices said remove, one said gate, one said keep, and
nobody resolved it. I said gate. I still say gate. But here is the
thing I missed in Round 2: the disagreement does not matter for
Action 1. The broker composition is not in the surgery path. You can
delete Path B from the position observer without touching the broker
composition at all. The composition question is Action 2. It blocks
nothing. Ship Action 1 without resolving this. Resolve it in its own
proposal when the data from the fixed position observer tells you
what the broker should think about.

**The sequencing after Change 1:** Five different second priorities.
The ignorant correctly identified that the process has no mechanism
to resolve this. That is fine. The process resolved the FIRST action.
The second action should be proposed after measuring the effect of the
first. Sequencing beyond the next step is speculation. We converged on
what matters. The rest is a backlog, not a plan.

---

## On the undefined terms

The ignorant pieced together `observe_scalar`, `observe`, "reckoner",
"anomalous component", and "residual" from scattered context. That is
a failure of the proposal, not of the reader.

For the record, since the ignorant earned the definitions:

- **Reckoner**: the learning primitive. It has two modes. Discrete:
  binary classification (Up/Down, Grace/Violence) via `observe(thought,
  label, weight)`. Continuous: scalar prediction via
  `observe_scalar(thought, target_value, weight)`. Both update a
  subspace. Both can be queried for a prediction given a thought vector.

- **`observe` vs `observe_scalar`**: two methods on the same struct.
  `observe` feeds a binary label. `observe_scalar` feeds a continuous
  target. The position observer's problem is that it has BOTH being
  called -- a discrete reckoner getting Grace/Violence AND continuous
  reckoners getting optimal distances. The discrete one is the parasite.

- **Anomalous component**: what the noise subspace cannot explain. The
  subspace learns the background distribution. The anomalous component
  is the residual after projecting out the learned background. It IS
  the signal. Everything the subspace can explain is noise. Everything
  it cannot explain is structure worth attending to.

- **`compute_optimal_distances`**: a simulation function that takes a
  realized price path and sweeps candidate trail/stop distances to find
  the hindsight-best values. It is pure -- no learning, no state. It
  answers: "given what actually happened, what distances would have
  captured the most favorable excursion with the least adverse
  excursion?" The position observer trains against this oracle.

The proposal should have defined these. It did not because it assumed
its audience. The ignorant is not the assumed audience. The ignorant is
the ACTUAL audience -- the person who will implement it months later
with no memory of the debate.

---

## On the six unanswered questions

**1. What happens to confidence after Path B is removed?**

Van Tharp's formula (`1.0 / (1.0 + mean_error)`) got one vote and zero
responses. That is not consensus. Here is what I would do: the position
observer's self-assessment becomes `avg_residue` only. The
`grace_rate` field on PositionObserver becomes the broker's trade-level
grace rate, passed DOWN as a diagnostic (read-only, not learned from).
The `exit-grace-rate` atom in the self-assessment vocabulary stays -- it
is a valid fact about recent performance. But its source changes from
the position observer's own rolling window to the broker's trade
outcomes. One source of truth: the tape.

Concretely: `grace_rate` and `outcome_window` stay on PositionObserver
as diagnostic fields, but they are populated by the BROKER's
Grace/Violence outcomes, not by the rolling percentile median
comparison. The self-referential loop dies. The measurement survives.

**2. Market observer directional accuracy is never stated.**

The ignorant is right. Nobody quoted a number from data. This is
intellectual laziness from all five voices. The number exists in the
run database. Query it before implementing. If market accuracy is
genuinely 50%, the entire system has no directional edge and the
position observer fix is necessary but not sufficient. That said --
the position observer fix is necessary REGARDLESS of market accuracy.
A broken distance learner cannot help a weak direction predictor. Fix
the broken thing first. Measure the weak thing second.

**3. Is Path A (continuous) already converging?**

This is the best question in the report. Nobody asked it. We all
assumed removing Path B would let Path A work. What if Path A is also
failing? The answer is: measure it. After implementing Change 1, run
100k candles and query the continuous reckoner's prediction error over
time. If it is not converging, the problem is deeper than Path B
contamination -- it might be the encoding, the reckoner configuration,
or the vocabulary. But you cannot diagnose Path A while Path B is
poisoning the self-assessment that rides inside the thought. Remove the
poison first. Then measure.

**4. Division by zero when optimal distance is zero.**

This is a real bug. The ignorant found it from the formula alone. On a
wrong-direction trade with zero favorable excursion, `optimal.trail` is
zero. The geometric error `|predicted - optimal| / optimal` divides by
zero. The current code uses `optimal.trail.max(0.0001)` as a floor
(line 201 of `broker_program.rs`). That is a band-aid, not a fix. The
`0.0001` floor means a predicted trail of 0.03 on a zero-optimal path
produces an error of 300 -- an outlier that dominates the rolling
median and biases the window.

The fix: when `optimal.trail` is zero, the error IS the predicted
value itself. `|0.03 - 0| = 0.03`. No division. The position observer
predicted some favorable excursion; there was none. The absolute error
is the prediction itself. Use absolute error when optimal is zero,
geometric error when optimal is positive. This is not a new idea. It
is how you handle a zero reference in any error metric.

But -- this entire branch is inside the rolling percentile median
computation, which is being deleted. The division-by-zero only matters
for the CONTINUOUS reckoners' `observe_scalar` path, where the broker
program sends `optimal.trail` directly (not a ratio). The continuous
reckoner learns `optimal.trail = 0.0` as a valid target. No division.
The bug lives in the code being removed. Delete the code, delete the
bug.

**5. Sequencing after Change 1.** Already addressed above. Not a
problem. A backlog.

**6. The 2x weight modulation and volume-price divergence.** The
ignorant correctly noted these were acknowledged and set aside, not
resolved. They remain open. They are not in the surgery path. They
belong in future proposals, each with their own ignorant reader.

---

## The concrete changes -- ordered, with file paths

### DELETE (Action 1 -- the surgery)

1. **Delete the rolling percentile median and `journey_errors` window
   from the broker program.**

   File: `src/programs/app/broker_program.rs`, lines 196-229.
   The entire block starting at `// Deferred batch training for position
   observer` through the end of the `for` loop over `resolution.position_batch`.
   This is the Path B pipeline: it computes geometric error, pushes it
   into `journey_errors`, computes the median, derives `is_grace` from
   `error < median`, and sends a `PositionLearn` with that
   self-referential label.

   Also delete: `journey_errors: VecDeque<f64>` from the Broker struct
   (`src/domain/broker.rs`, line 178) and its initialization
   (`src/domain/broker.rs`, line 219). The `JOURNEY_WINDOW` constant
   dies with it.

2. **Delete `is_grace` from the `PositionLearn` signal.**

   File: `src/programs/app/position_observer_program.rs`, line 44.
   Remove the `is_grace: bool` field from `PositionLearn`. The position
   observer does not need to know the outcome. It needs to know the
   optimal distances (already there) and the weight (already there).

   The immediate resolution path in `broker_program.rs` (lines 186-194)
   also sends `is_grace`. Remove that field from the send. The position
   observer learns calibration, not outcome.

3. **Remove `outcome_window` from PositionObserver.**

   File: `src/domain/position_observer.rs`.
   Delete: `outcome_window: VecDeque<bool>` (line 37), the
   `push_back(is_grace)` / `pop_front()` logic in `observe_distances`
   (lines 154-157), and the `grace_count` recomputation (lines 164-167).

   The `observe_distances` method signature loses the `is_grace`
   parameter. It becomes:
   `fn observe_distances(&mut self, position_thought: &Vector, optimal: &Distances, weight: f64, residue: f64)`

4. **Change `grace_rate` source on PositionObserver.**

   The `grace_rate` field STAYS. But it is no longer computed from
   `outcome_window`. It becomes a write-only field set by the broker
   program when propagating trade outcomes. The broker already computes
   `grace_rate` from `grace_count / trade_count` (broker_program.rs
   line 298). Pass this down through the `PositionLearn` signal as a
   diagnostic value OR compute it at the broker level and send it once
   per resolution.

   Keep `avg_residue` and `residue_window` -- these are honest
   measurements of geometric distance, not self-referential.

5. **Update the self-assessment vocabulary.**

   File: `src/vocab/exit/self_assessment.rs`.
   The `exit-grace-rate` atom stays -- it is a legitimate fact about
   the observer's recent trade-level performance. But its semantics
   change: it now reflects the broker's trade outcomes, not the
   observer's own rolling window comparison. The code does not change.
   The data source changes (step 4 above). Document this in a comment.

6. **Update tests.**

   File: `src/domain/position_observer.rs`, test `test_self_assessment_window`.
   Remove assertions about `outcome_window` and `grace_rate` recomputation
   from `observe_distances`. Add a test that `observe_distances` no longer
   takes `is_grace`.

   File: `src/programs/app/broker_program.rs` -- any test that constructs
   `PositionLearn` with `is_grace` needs updating.

7. **Update the wat specification.**

   File: `wat/broker.wat`. The propagation logic references
   Grace/Violence for the position observer. Update to reflect that
   position learning receives only optimal distances and weight.

   The broker's own reckoner (`Discrete '("Grace" "Violence")` at
   line 85) stays -- the broker IS the accountability unit. Grace/Violence
   is the broker's vocabulary, not the position observer's.

### KEEP (do not touch)

- The market observer's training loop. It is honest. Binary direction
  prediction deserves a binary label.
- The broker's Grace/Violence reckoner. The broker measures team
  performance. That is its job.
- The broker's `grace_count`, `violence_count`, EV computation. These
  are honest tape-derived statistics.
- The continuous reckoners (`trail_reckoner`, `stop_reckoner`) and
  their `observe_scalar` path. This IS Path A. It stays and becomes
  the sole training signal.
- The `avg_residue` and `residue_window` on PositionObserver. Honest
  measurement of prediction quality.
- The `exit-grace-rate` and `exit-avg-residue` vocabulary atoms. They
  are facts, not labels.
- The broker composition (`bundle(market_anomaly, position_anomaly,
  portfolio_biography)`). Leave it for a separate proposal.

### WRITE (new -- one principle, one fix)

8. **Add the design invariant to the guide.**

   File: `wat/GUIDE.md`.
   Add to the principles section: "No learner shall be graded against
   a statistic derived from its own output distribution." Credit
   Seykota for the principle, Beckman for the proof.

9. **Fix the division-by-zero floor.**

   File: `src/programs/app/broker_program.rs`, line 201.
   The `optimal.trail.max(0.0001)` floor is in code being deleted
   (the journey_errors path). But the SAME pattern may exist in the
   simulation's `compute_optimal_distances` or wherever optimal
   distances reach the continuous reckoner. Audit the continuous path
   for the same 0.0001 floor. If found, replace with: when optimal
   is zero, error = |predicted|. When optimal > 0, error = |predicted
   - optimal| / optimal. This is a separate commit.

---

## On what the ignorant taught the five voices

The ignorant asked: "Is Path A already converging?" None of us asked
that. We assumed removing Path B was sufficient. It is necessary. It
may not be sufficient. The correct response to implementing Action 1
is not celebration. It is measurement: run 100k candles, query the
continuous reckoner's error trajectory, and look at whether removal of
the self-referential grace_rate atom from the position thought actually
lets the continuous subspace converge.

The ignorant also identified the implementation gap precisely: the
documents describe the surgery but do not hand you the scalpel. This
response hands you the scalpel. Nine steps. Seven deletions. One
principle. One audit.

Simplicity is achieved not when there is nothing more to add, but when
there is nothing left to take away. The position observer has something
left to take away.
