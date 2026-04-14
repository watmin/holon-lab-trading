# Response to the Ignorant: Beckman

The ignorant did exactly what it was designed to do. It read seventeen
documents as a stranger and reported where the path failed to teach.
Seven points were raised. I will address each, then provide the ordered
list of concrete changes with file paths.

---

## Addressing the seven findings

### 1. Undefined terms: reckoner, observe, observe_scalar

The ignorant is right. These terms are used fluently by all five
reviewers and defined by none.

A **reckoner** is a learning unit. It wraps an `OnlineSubspace` (a
streaming PCA that learns what "normal" looks like) and a readout
mechanism. It has two modes:

- **Discrete** (binary labels): the `observe(thought, label, weight)`
  method feeds a labeled vector into the subspace. The subspace absorbs
  the common structure. What it cannot absorb — the residual — is the
  anomalous signal. The reckoner predicts by measuring how far a new
  thought deviates from the learned normal.

- **Continuous** (scalar targets): the `observe_scalar(thought, target,
  weight)` method feeds a thought paired with a scalar value. The
  reckoner learns to associate thought-states with continuous outputs.
  This is what the position observer's trail and stop reckoners use.

The **anomalous component** is what the subspace cannot explain — the
residual after projecting onto the learned principal components. The
**residual** in the Seykota/Beckman sense is the magnitude of this
anomalous component. High residual = the thought is unlike anything
the reckoner has seen. Low residual = the thought fits the learned
pattern.

These definitions should have appeared in the proposal, not buried
across five reviews. This is a failure of the proposal document, not
of the reviewers. The ignorant caught it.

### 2. `compute_optimal_distances` and the zero-optimal edge case

The ignorant inferred correctly: this function sweeps candidate
distances against the realized price path and returns the distance
that produces maximum residue (profit). The actual implementation is
in `wat/simulation.wat` (specification) and `src/domain/simulation.rs`
(Rust). It sweeps 20 candidates from 0.5% to 10.0% in 0.5%
increments.

The ignorant's question 4 is the sharpest thing in the report:

> What geometric error does the position observer learn from a
> predicted trail of 0.03 versus an optimal of 0? The formula
> `|predicted - optimal| / optimal` is undefined when optimal is zero.

This is a genuine mathematical gap. Let me trace the actual code path.
In `src/programs/app/broker_program.rs` lines 200-204:

```rust
let trail_err = (actual.trail - optimal.trail).abs()
    / optimal.trail.max(0.0001);
let stop_err = (actual.stop - optimal.stop).abs()
    / optimal.stop.max(0.0001);
```

The `max(0.0001)` clamp prevents division by zero but introduces a
distortion: when optimal is truly zero (no favorable excursion), the
error becomes `predicted / 0.0001` — an enormous number that dominates
the rolling window and poisons the median. This is not a theoretical
concern. On wrong-direction papers where MFE is zero, the "optimal
trail" from `best_distance` is the smallest candidate (0.005), not
zero, because even the smallest trail produces the least-bad negative
residue. But if MFE is exactly zero (price never moved favorably by
even one tick), the sweep returns 0.005 and the error is well-defined.
The `approximate_optimal_distances` in the paper's tick path uses
tracked MFE/MAE extremes, which CAN be zero early in a paper's life.

The fix is already implied by the deletion of the binary path: without
the rolling median, the `max(0.0001)` clamp only affects diagnostic
telemetry, not the training signal. The continuous reckoners
(`observe_scalar`) receive `optimal.trail` and `optimal.stop` as raw
targets, not error ratios. The division-by-zero problem lives entirely
in the journey grading path that is being deleted. But the diagnostic
telemetry should still handle zero correctly. I will include this in
the change list.

### 3. Confidence replacement after Path B removal

The ignorant caught that Van Tharp's `calibration_confidence = 1.0 /
(1.0 + mean_error)` received exactly one vote and zero engagement.

I endorse this formula with one modification. The `mean_error` should
be computed from the continuous reckoners' prediction residuals, not
from the rolling window (which is being deleted). Specifically:

```
calibration_confidence = 1.0 / (1.0 + avg_trail_residual + avg_stop_residual)
```

where `avg_trail_residual` and `avg_stop_residual` are the mean
absolute prediction errors from the trail and stop reckoners
respectively. This is direction-agnostic, self-referential only in
the sense that any confidence measure must be (you measure your own
accuracy), but not self-grading (the target is the simulation's
optimal, not a rolling statistic of your own outputs).

The current `grace_rate` on the position observer (`src/domain/
position_observer.rs` line 41) is fed from `is_grace` which comes
from the broker's rolling median. After deletion, the `grace_rate`
field either dies or is replaced by `calibration_confidence` computed
from reckoner residuals. I prefer replacement — the downstream
consumers (the position observer's self-assessment facts in
`position_self_assessment_facts()`) need something to report.

### 4. Market observer directional accuracy

The ignorant notes that the actual number is never quoted from data.
This is true. The reviews say "around 50%" from memory. The correct
answer is: query the run database. The DB has `learn_up_count` and
`learn_down_count` metrics per broker per candle. The directional
accuracy is `correct_count / total_count` aggregated from the
broker snapshots.

But the ignorant's implication is correct: if market accuracy is
genuinely 50%, the direction prediction contributes zero edge. The
position observer fix is necessary but not sufficient. I stated this
in Round 2 — the continuous error signal is direction-agnostic, so
the position observer can learn even when direction prediction is at
chance. The system's profitability depends on the position observer's
distance calibration being good enough to produce asymmetric payoffs:
small losses on wrong-direction trades, large captures on right-
direction trades. This is Van Tharp's R-multiple insight. A 50%
accuracy system is profitable if avg_win > avg_loss. The position
observer IS the mechanism that creates this asymmetry.

### 5. Path A convergence

The ignorant asks: is the continuous path already converging? If Path
A is also failing, removing Path B is necessary but does not guarantee
improvement.

This is the right question, and the answer is: we do not know, because
Path B's contradictory updates make Path A's convergence unmeasurable.
Two teachers feeding the same subspace means the continuous reckoner's
trajectory is a superposition of two optimization pressures. Remove
Path B, run 100k candles, and then measure Path A's convergence. If
Path A fails on its own, the diagnosis is different — it means the
continuous reckoner's architecture (subspace + scalar readout) cannot
learn the distance mapping. That would be a substrate problem, not a
signal problem. But we cannot distinguish signal failure from substrate
failure until the signal is clean.

### 6. Unresolved: 2x weight, phase capture, volume-price divergence

The ignorant correctly identified three open items that the process
acknowledged and set aside. I agree they remain open. My position on
each:

- **2x weight modulation**: The temporal misalignment is real (I
  identified it in Round 1). The step function is crude. But it is
  not the highest leverage. After Change 1, we can measure whether
  the weight modulation helps or hurts by toggling it and comparing
  convergence rates. Empirical, not theoretical.

- **Wyckoff's volume-price divergence**: Wyckoff is right that the
  market observer without volume understanding predicts from
  incomplete data. But the market observer already has a "volume"
  lens — one of the six lenses includes volume vocabulary. The
  question is whether the vocabulary is rich enough. This is an
  enrichment of existing vocabulary, not a new learning path. It
  belongs in a separate proposal after the signal is clean.

- **Sequencing after Change 1**: Five voices, five priorities. The
  correct resolution is: implement Change 1, measure, and let the
  data determine what hurts most. The priority queue cannot be
  resolved by debate. It can only be resolved by measurement.

### 7. The broker composition: remove, gate, or keep dormant

Three voices said remove. One said gate. One said keep. The ignorant
is right that this was not resolved. My position from Round 2 holds:
remove now, file restoration as a future proposal. The composition
currently computes `bundle(market_anomaly, position_anomaly,
portfolio_biography)` every candle and nobody reads it. The broker's
reckoner exists (line 51 of `wat/broker.wat`: `[reckoner : Reckoner]
:discrete`) but the `propose` function's output is not consumed for
learning — only the `propagate` function feeds the reckoner, and it
feeds from trade outcomes, not from the composition's prediction.

The composition is not dead code — it is used in `propose()` for
the broker's Grace/Violence prediction, and that prediction feeds
the curve which determines `edge-at`. So it IS consumed. What is
dead is the learning signal: the broker learns from outcomes, and
the outcomes are contaminated by the position observer's broken
signal. Fix the inputs (Change 1), then evaluate whether the broker's
reckoner is learning anything meaningful. Do not remove the
composition — remove the expectation that it works until the inputs
are clean.

I correct my Round 2 position: the composition should stay, but the
broker's edge should not gate treasury funding until the position
observer is converging.

---

## Ordered list of concrete changes

### Change 1: Delete the binary Grace/Violence learning path from the position observer

This is the unanimous recommendation from all five voices.

**What to delete:**

1. The `is_grace: bool` and `residue: f64` fields from `PositionLearn`
   struct in `src/programs/app/position_observer_program.rs` (line 44-45).

2. The `is_grace` and `residue` parameters from `observe_distances()`
   in `src/domain/position_observer.rs` (line 142-148). The method
   keeps the `observe_scalar` calls (lines 150-151) and loses the
   rolling window updates (lines 153-170).

3. The `outcome_window: VecDeque<bool>` and `grace_rate: f64` fields
   from the `PositionObserver` struct in `src/domain/position_observer.rs`
   (lines 36, 41). Replace `grace_rate` with `calibration_confidence`
   computed from reckoner residuals.

4. The rolling percentile median computation in
   `src/programs/app/broker_program.rs` (lines 196-228) — the entire
   deferred batch training block that computes `error`, pushes into
   `journey_errors`, computes the median, derives `is_grace`, and
   sends `PositionLearn`.

5. The `journey_errors: VecDeque<f64>` field from the `Broker` struct
   in `src/domain/broker.rs` (line 178) and the `JOURNEY_WINDOW`
   constant.

6. The `is_grace` computation in the immediate resolution path in
   `src/programs/app/broker_program.rs` (line 187). The
   `PositionLearn` message keeps `position_thought`, `optimal`, and
   `weight`. It loses `is_grace` and `residue`.

**What to keep:**

- The `observe_scalar` calls in `observe_distances()` — these ARE
  the continuous learning path. They feed `optimal.trail` and
  `optimal.stop` as scalar targets to the trail and stop reckoners.
  This is Path A. It stays.

- The broker's own Grace/Violence reckoner and its `propagate`
  function in `wat/broker.wat`. The broker learns from trade outcomes.
  Its labels are honest.

- The broker's scalar accumulators (`trail_accum`, `stop_accum`) in
  `src/domain/broker.rs` (lines 445-446). These learn from optimal
  distances and serve as fallback distance sources.

**What to add:**

- `calibration_confidence` on `PositionObserver`, computed as
  `1.0 / (1.0 + mean_trail_residual + mean_stop_residual)` where
  residuals come from the continuous reckoners' prediction error
  against the most recent N optimal targets. This replaces
  `grace_rate` in `position_self_assessment_facts()`.

**Wat specification update:**

- The wat source of truth does not currently specify the rolling
  median or journey_errors — those live only in Rust. But
  `wat/broker.wat` line 63 (`[scalar-accums : Vec<ScalarAccumulator>]`)
  and the `propagate` function (lines 168-221) need review to ensure
  the specification matches the simplified propagation.

**Measurement:** Run 100k candles before and after. Compare trail and
stop reckoner experience growth curves. After the change, the
continuous reckoners should show monotonic error reduction (or at
least no oscillation). Query from the run DB, not from logs.

### Change 2: Replace `grace_rate` self-assessment with `calibration_confidence`

Depends on Change 1.

**Files:**

- `src/domain/position_observer.rs`: replace `grace_rate` field with
  `calibration_confidence`. Add a method that computes it from the
  trail and stop reckoners' recent prediction residuals.

- `src/programs/app/position_observer_program.rs`: update
  `position_self_assessment_facts()` (around line 157-159) to use
  `calibration_confidence` instead of `grace_rate`.

**Formula:**

```
let trail_residual = self.trail_reckoner.mean_residual();
let stop_residual = self.stop_reckoner.mean_residual();
self.calibration_confidence = 1.0 / (1.0 + trail_residual + stop_residual);
```

This requires the continuous reckoner to expose a `mean_residual()`
method. If it does not currently, add one that returns the mean
absolute error over the last N predictions. This is a holon-rs
substrate change — it lives in the `holon-rs` crate, not in the
trading lab.

**Measurement:** Does `calibration_confidence` correlate with actual
distance accuracy? Query the DB for papers where predicted distances
were close to optimal versus far from optimal. The confidence should
be higher for the former.

### Change 3: Add concordance atom to broker portfolio biography

Independent of Changes 1-2. Can be done in parallel.

**Files:**

- `src/programs/app/broker_program.rs`: where the portfolio biography
  facts are computed (around the `portfolio_ast` construction), add
  a scalar atom:
  ```
  concordance = market_conviction / (trail_distance + stop_distance).max(0.001)
  ```
  Encode as `ThoughtAST::Scalar("concordance", concordance,
  ScalarEncoding::Log)`.

- `wat/broker.wat` or `wat/proposal.wat`: add `concordance` to the
  portfolio biography specification if it is enumerated there.

**Measurement:** Telemetry. Log concordance per broker per resolution.
Query whether high concordance predicts Grace at the broker level.

### Change 4: Normalize broker outcomes to R-multiples

Depends on Change 1 being implemented and measured.

**Files:**

- `src/domain/broker.rs`: on paper resolution, compute
  `r_multiple = excursion / stop_distance_at_entry`. Add fields
  `avg_win_r` and `avg_loss_r` (exponential moving averages or
  rolling windows).

- `src/programs/app/broker_program.rs`: where `expected_value` is
  computed, replace with `expected_r = grace_rate * avg_win_r -
  violence_rate * avg_loss_r`.

- Treasury funding logic (when implemented): read expected R-multiple
  instead of raw expected value.

**Measurement:** 100k candles. Compare cross-broker R-distributions.
The variance should be lower than raw P&L variance because R-multiples
normalize for volatility regime.

### Change 5: Clean up the zero-optimal diagnostic path

Small but necessary. Independent of the other changes.

**File:** `src/programs/app/broker_program.rs`, lines 200-204.

The `max(0.0001)` clamp in the error ratio computation is a silent
distortion. After deleting the journey grading path (Change 1), this
code is removed. But if any diagnostic telemetry retains the error
ratio computation, replace the clamp with an explicit guard:

```rust
let trail_err = if optimal.trail > 0.001 {
    (actual.trail - optimal.trail).abs() / optimal.trail
} else {
    0.0  // optimal is zero — no meaningful error to report
};
```

Zero optimal means there was no favorable excursion to trail. The
error is not "infinite" — it is "not applicable." Reporting 0.0 is
more honest than reporting `predicted / 0.0001`.

---

## The invariant

Write into `wat/GUIDE.md`:

> **No learner shall be graded against a statistic derived from its
> own output distribution.** The benchmark must be external: the
> market, the simulation, a frozen threshold, another observer's
> measurement. Any rolling window of the learner's own errors, used
> as a grading threshold, will produce a limit cycle. This is a
> theorem, not a guideline.

Proof sketch: let $e_t$ be the learner's error at time $t$, $m_t$
the rolling median of $\{e_{t-N}, \ldots, e_t\}$. The label is
$\ell_t = \mathbf{1}[e_t < m_t]$. The learner updates parameters
$\theta$ to increase $P(\ell_t = \text{Grace})$. After successful
learning, $e_{t+1} < e_t$. But $m_{t+1} \leq m_t$ because the
window now includes the lower error. The threshold contracts. The
learner must produce $e_{t+2} < m_{t+1} < m_t$. The fixed point
is $e_t = m_t$ for all $t$, at which point the label is determined
by noise and the grace rate converges to $\frac{1}{2}$ in
expectation. Finite-window autocorrelation produces the observed
oscillation between long Grace runs and long Violence runs. QED.

This is Seykota's principle. I provided the proof. It applies to
every reckoner in the system, present and future.
