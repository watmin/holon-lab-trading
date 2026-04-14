# Response to the Ignorant: Wyckoff

The ignorant read the tape clean. Seven findings. I will address
each, then give the ordered list of changes with file paths.

---

## 1. Undefined terms

The ignorant is right. The proposal assumed its audience had read
50 prior proposals. A stranger cannot enter through the front door.
But the reviews fixed this — the ignorant says so explicitly. The
reviews are better entry points than the proposal itself. This is
not a defect to fix. This is how the process works. The proposal
asks questions. The reviews teach.

The specific terms the ignorant could not define:

**Reckoner.** The learning mechanism. A vector subspace that
accumulates weighted observations and produces predictions. Two
modes: discrete (classifies into labels like Up/Down or
Grace/Violence) and continuous (predicts a scalar value like a
distance). The interface: `observe(thought, label, weight)` for
discrete, `observe_scalar(thought, value, weight)` for continuous.
`predict(thought)` returns the prediction. `experience()` returns
how much the reckoner has learned. `query(thought)` returns the
continuous scalar readout.

**`observe_scalar` vs `observe`.** Two methods on the reckoner.
`observe` feeds a discrete label (Up, Down, Grace, Violence).
`observe_scalar` feeds a continuous value (trail distance = 0.03).
The position observer's two reckoners use `observe_scalar` — they
learn distances, not categories. The broker's reckoner uses
`observe` — it learns Grace/Violence categories. The ignorant
inferred this correctly.

**Anomalous component and residual.** The noise subspace (an
OnlineSubspace with 8 principal components) learns the background
distribution — what is normal. `anomalous_component(thought)`
returns the part of the thought the subspace cannot explain. The
residual IS the signal. What the subspace absorbed is noise. What
remains is what the reckoner should learn from. The market observer
calls this `strip_noise`. The pattern is identical across all
observers.

**`compute_optimal_distances`.** Defined in `wat/simulation.wat`.
Sweeps 20 candidate distances (0.5% to 10% in 0.5% increments)
against the realized price path. For each candidate, simulates the
trailing stop or safety stop mechanics. The candidate that produces
the maximum residue IS the optimal distance. Direction-symmetric:
for Down, the price history is inverted (1/price) so the same
logic applies. The ignorant's inference was correct.

---

## 2. Unresolved contradictions

### Broker composition: remove vs gate vs keep dormant

The ignorant correctly identified this as the one unresolved
contradiction. Three say remove, one says gate, one says keep.

I said remove. I hold that position. But the ignorant's observation
is precise — the principle is contested. Here is my resolution:

The wat specification (`wat/broker.wat`) already has no binary
Grace/Violence path flowing to the position observer. The broker's
`propagate` function returns `PropagationFacts` containing
`optimal: Distances`. The post's `post-propagate` calls
`observe-distances` on the exit observer with those optimal
distances. There is no second teacher in the wat. The lying path
exists only in the Rust implementation (`src/programs/app/
broker_program.rs`, lines 196-229) — the deferred batch training
with the rolling percentile median.

The resolution: delete the Rust code that diverges from the wat.
The wat is the source of truth. The Rust will conform. This is not
a design decision — it is a compilation step. The composition
question (remove the broker reckoner's bundle allocation) is a
separate, lower-priority change.

### Sequencing after Change 1

Five voices, five second priorities. The ignorant is right that
this is unresolved. I do not attempt to resolve it here. Change 1
has unanimous agreement. Implement it. Measure. The data after
Change 1 will tell us what comes second — not five voices arguing
from theory.

---

## 3. Unanswered questions

### Q1: What happens to confidence and avg_residue after Path B removal?

Van Tharp proposed `calibration_confidence = 1.0 / (1.0 + mean_error)`.
Nobody else commented. Here is what happens concretely:

The position observer in Rust (`src/domain/position_observer.rs`,
lines 37-43) has `outcome_window: VecDeque<bool>`, `residue_window:
VecDeque<f64>`, `grace_rate: f64`, and `avg_residue: f64`. These
fields feed `self_assessment_facts` which encode `exit-grace-rate`
and `exit-avg-residue` as thoughts the position observer thinks
about itself (`src/vocab/exit/self_assessment.rs`).

After removing Path B: the `is_grace` parameter on
`observe_distances` ceases to be the position observer's
self-referential rolling label. It becomes the broker's trade
outcome — an external signal. The `grace_rate` and `avg_residue`
remain as diagnostic telemetry derived from broker outcomes, not
from the position observer's own rolling percentile.

Van Tharp's formula is reasonable but premature. Keep the existing
fields. Change their source from self-assessment to broker
assessment. The downstream consumers do not care where the number
came from — they care that it is honest.

### Q2: Market observer directional accuracy never stated

The ignorant is right. Nobody quoted the number from data. This
is a measurement question, not a design question. After Change 1,
the first thing to query from the run database is: what is the
actual directional accuracy per market observer lens, per 10k
candle window? If it is genuinely 50%, the position observer fix
is necessary but the system has no edge from direction. That is
a vocabulary problem — which is why I proposed volume-price
divergence atoms as Change 2. But the number must come from the
database, not from theory.

### Q3: Is Path A (continuous) already converging?

The ignorant asks the right question. If Path A is also failing,
removing Path B is necessary but not sufficient. The answer: Path A
cannot converge while Path B is actively contradicting it. Two
teachers with conflicting gradients prevent convergence in either
direction. Remove the liar first. Then measure whether the honest
teacher produces convergence. If it does not, the problem is in
the vocabulary or the encoding, not the learning mechanism.

### Q4: Division by zero when optimal distance is zero

The ignorant found a real edge case. When the market moves
immediately against the predicted direction, the optimal trailing
stop distance could theoretically be zero (no favorable excursion
at all).

In practice, `compute_optimal_distances` (`wat/simulation.wat`)
sweeps candidates from 0.5% to 10%. The "optimal" is the candidate
that produces the maximum residue. On a fully adverse move, every
candidate produces negative residue. The function returns the
least-bad candidate — the tightest stop (0.5%), which minimized
the loss. This is never zero. The sweep has a floor of 0.005.

The Rust implementation in `src/programs/app/broker_program.rs`
(line 202) guards with `optimal.trail.max(0.0001)` in the
denominator. This guard is defensive but the underlying simulation
already prevents the zero case.

The ignorant's concern is valid in principle but already handled
by the sweep floor. No code change needed.

### Q5: Sequencing after Change 1

Addressed above. The data decides.

### Q6: The 2x weight modulation

The ignorant correctly notes this was acknowledged and set aside.
I still hold that the weight should be a function of phase
duration, not a step function. But this is a refinement, not a
fix. The step function is not wrong — it is imprecise. The
imprecision costs accuracy at the margin. The lying teacher costs
everything. Fix the lie first. Refine the weight later.

### Q7: Volume-price divergence received no engagement

The ignorant is right. Four voices ignored it. I argued it is not
premature. Nobody responded. It hangs.

I will not re-argue it here. I will say this: the data after
Change 1 will show whether market directional accuracy improves
when the position observer stops corrupting the learning loop.
If directional accuracy remains at 50%, the vocabulary is the
bottleneck. Volume-price divergence atoms are the vocabulary
fix. The argument resolves itself after measurement.

---

## 4. The implementation gap

The ignorant's sharpest finding: "I know WHAT to delete. I do not
know WHERE." The reviews describe the surgery precisely but do not
hand you the scalpel or point to the operating table.

Here is the operating table.

---

## Ordered list of concrete changes

### Change 1: Remove the binary Grace/Violence learning path from the position observer

This is three deletions and one modification.

**1a. Delete the deferred batch training block in the broker program.**

File: `src/programs/app/broker_program.rs`, lines 196-229.

The block beginning with `// Deferred batch training for position
observer (runner histories)` and ending with the closing brace of
the `for` loop over `resolution.position_batch`. This is the
rolling percentile median, the `journey_errors` window, and the
binary Grace/Violence label derived from `error < median`. Delete
the entire block.

**1b. Delete the `journey_errors` field from the broker domain.**

File: `src/domain/broker.rs`, line 178 (`pub journey_errors:
VecDeque<f64>`) and line 219 (initialization). Remove the field
and its initialization. Remove the `JOURNEY_WINDOW` constant.

**1c. Remove the `is_grace` parameter from `observe_distances`.**

File: `src/domain/position_observer.rs`, line 142-171.

The `is_grace: bool` parameter drives the self-assessment window
(`outcome_window`). After Path B removal, the position observer
should not maintain its own Grace/Violence rolling window. Two
options:

- **Option A (clean):** Remove `is_grace` and `residue` parameters
  from `observe_distances`. Remove `outcome_window`,
  `residue_window`, `grace_rate`, `avg_residue` fields entirely.
  Remove `self_assessment.rs` from the vocabulary. The position
  observer becomes pure distance learning — no self-assessment.

- **Option B (preserve telemetry):** Keep `is_grace` but source it
  from the broker's trade outcome (which it already is in the
  immediate resolution path, `broker_program.rs` line 187). Remove
  only the deferred batch path. Keep `grace_rate` and `avg_residue`
  as broker-derived diagnostics.

I recommend **Option A**. The self-assessment facts
(`exit-grace-rate`, `exit-avg-residue`) feed back into the position
observer's own encoding. This is a weaker form of the same
self-referential loop — the observer thinks about its own rolling
accuracy while learning. Remove the mirror entirely. The broker's
curve measures the position observer's quality. The position
observer does not need to know its own score.

If Option A proves too aggressive (the self-assessment facts were
contributing signal), restore them in a future proposal with the
source changed to broker-derived metrics.

**1d. Update the immediate resolution path.**

File: `src/programs/app/broker_program.rs`, lines 186-194.

The immediate resolution signal (lines 186-194) sends
`is_grace` and `residue` to the position observer. If Option A:
remove these fields from `PositionLearn` and from
`observe_distances`. If Option B: keep as-is — this path is
already honest (the broker determines Grace/Violence from the
trade outcome, not from the observer's own window).

**1e. Update callers and tests.**

Files:
- `src/programs/app/position_observer_program.rs` — remove
  references to `grace_rate`, `avg_residue`, self-assessment facts
  (lines 157-159, 284, 295-296).
- `src/vocab/exit/self_assessment.rs` — delete file (Option A) or
  keep (Option B).
- `src/domain/ledger.rs` — remove `grace_rate` column from
  position observer snapshots (line 33, 97, 104).
- `src/bin/wat-vm.rs` — remove `grace_rate` references (lines
  780, 784).
- `src/types/log_entry.rs` — remove `grace_rate` field from the
  relevant `LogEntry` variant (line 83).

### Change 2: Measure before proposing

Not a code change. A query.

After Change 1, run the standard 100k candle benchmark. Query the
database for:

- Per-market-observer directional accuracy by lens, per 10k window.
- Position observer continuous reckoner convergence: does
  `experience()` grow and do predictions approach optimal distances?
- Broker Grace rate by slot.

The answers determine what comes next. If directional accuracy is
at 50%, the vocabulary needs volume-price divergence atoms. If
the continuous reckoner converges, the position observer is fixed.
If it does not converge, the problem is deeper than the label.

### Change 3: Remove dead composition (conditional)

File: `src/domain/broker.rs` — the composed thought allocation.
File: `wat/broker.wat` — the `propose` function already computes
the composition for the broker's own reckoner prediction. This
stays. The question is whether the broker reckoner itself should
be removed.

This change is gated on Change 1 being measured. If the broker's
Grace/Violence reckoner is not contributing signal (its curve is
flat, its edge is zero), remove the reckoner allocation. Keep the
portfolio biography for telemetry. File a restoration proposal
gated on clean inputs.

### Change 4: Volume-price divergence atoms (conditional)

Files (new or modified):
- `wat/candle.wat` or a new `wat/vocab/phase-volume.wat` — define
  the cross-phase volume comparison atoms.
- `src/vocab/` — implement `volume_valley_trend`,
  `volume_peak_trend`, `volume_effort_ratio` as facts on the candle.
- `wat/post.wat` — wire the new atoms into market lens facts.

This change is gated on the measurement from Change 2 showing that
market directional accuracy is the bottleneck.

---

## Summary

The ignorant found the gap between description and implementation.
The five voices agreed on WHAT to do. Nobody said WHERE. The
operating table is the broker program's deferred batch training
block, the position observer's self-assessment fields, and the
`journey_errors` window on the broker domain. Three files hold the
lie. Delete the lie. Measure the truth. Then decide what comes next.

The tape is waiting.
