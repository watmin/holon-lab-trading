# Review: Proposal 025 — Brian Beckman

**Verdict:** ACCEPTED

## Assessment

The diagnosis is a training distribution mismatch that becomes a feedback loop.
Let me state it precisely.

The exit observer's reckoner is a map `R: Vector -> f64`. It learns a function
from composed thoughts to distance values. The reckoner has two components —
`trail-reckoner` and `stop-reckoner` — each implementing the bucketed
accumulator: `f: thought -> argmax_k cos(thought, prototype_k)` with soft-3
interpolation. The prototypes are formed by bundling observed thoughts,
weighted by their scalar targets.

Call the training distribution `D_train` and the inference distribution `D_inf`.
For the reckoner to generalize, `D_train` must be drawn from the same measure
as `D_inf`. Currently:

- `D_inf` = {composed thoughts at the moment of prediction} = full support over
  both Grace- and Violence-leading market conditions
- `D_train` = {composed thoughts from Grace resolutions} = a strict subset

This is not a question of sample efficiency. The two distributions are
*structurally different* because the exit observer's prototypes are only
built from Grace-generating conditions. The thought vector space has
regions — those correlated with upcoming stops — that are never observed
in training. In those regions the reckoner extrapolates from the wrong
prototype centroid. The K-bucket interpolation will find the nearest bucket,
but that bucket learned from Grace data. The interpolated distance is
therefore biased toward Grace-optimized distances even when the market is
in a Violence-leading regime.

The feedback mechanism is clear: Grace prototypes recommend tight trails.
Tight trails produce Grace resolutions. Those resolutions train the trail
prototypes to be even tighter. The system has a repeller at Violence — it
never generates training data there — and an attractor at Grace. The 99%
Grace empirical result is the fixed point of this loop, not an achievement.

The fix is algebraically correct. Every resolution, regardless of outcome,
carries `(thought, optimal_trail, optimal_stop)`. The weight carries the
outcome semantics. The reckoner does not need to know Grace from Violence.
Its job is: "given this thought, what distance would have been optimal?"
Both outcomes answer that question honestly and from different regions of
the support. The combined training distribution covers `D_inf`.

The near-zero symmetric default is also correct. The current default
`(0.015, 0.030)` is a hand-coded prior that biases the system before any
learning occurs. Near-zero defaults ensure both sides of the paper resolve
quickly, producing balanced observations from the first recalibration window.
The learned values then displace the prior entirely. This is the correct
initialization for a prior-free learner.

There is one structural property I want to name explicitly. The `observe`
call in `observe-distances` passes `weight: f64` to both reckoners. For
Grace, the weight is the excursion — "how much value the trade captured."
For Violence, the weight is the stop-distance — "how much the trade lost."
These are not on the same scale in general. However, they are on the same
*type* — both are f64 values in `(0.0, 1.0)` representing a fraction of
price. The reckoner's soft-weighting will correctly modulate the influence
of each observation. A small-excursion Grace event has low weight; a
small-stop-distance Violence event also has low weight. The signals are
comparable. The scheme composes.

One subtlety: the K=10 bucketed reckoner recalibrates its range
(bucket boundaries) every 100 observations. If Violence observations
arrive first and have small values (tight stops), the early buckets
compress into a small range. When Grace observations subsequently arrive
with large values (wide excursions), they fall outside the current range.
The recalibration corrects this, but there is a transient phase where
the range is poorly calibrated. This is not a defect in the proposal —
it is an existing property of the continuous reckoner — but the bootstrap
sensitivity is heightened when `default = 0.0001` because all papers
resolve on the first candle. The first recalibration window is populated
entirely from near-zero defaults, which compresses the initial range.
The second window will expand it. This is fine. Flag it empirically.

## Concerns

**The `scalar-accumulator` asymmetry (Question 3).** The scalar accumulators
on the broker already receive both Grace and Violence observations. The
`observe-scalar` function matches on `outcome` and routes to `grace-acc` or
`violence-acc`. The `extract-scalar` function then sweeps candidates against
`grace-acc` — the value closest to the Grace centroid. This means Violence
observations *do* reach the scalar accumulator, but they are not used in
extraction. The accumulator has two halves; extraction reads one. This is
not a bug introduced by this proposal — it pre-exists — but the proposal's
principle "every learned value needs both sides" applies here. The scalar
accumulator sees Violence but suppresses it at extraction. If you want the
scalar accumulator to use Violence data to refine the Grace estimate (via
contrast), you need a different extraction function — one that finds the
value *close to Grace and far from Violence*. This is proposal-worthy on its
own. Do not couple it to this one.

**The `approximate_optimal_distances` approximation.** In `tick-papers`,
the optimal distances are computed from `(buy-extreme, sell-extreme)` — the
running extremes tracked on the paper. This is a lower bound on the
simulation-based `compute-optimal-distances`. A paper that exits after 3
candles has only 3 candles of history; the simulation would sweep those 3
candles. Both give the same answer here because the paper tracks the actual
extremes. But the simulation in `compute-optimal-distances` uses a sweep of
20 candidates from 0.5% to 10%. The `approximate_optimal_distances` derives
a single value from the extreme. The approximation is coarser. This means
the distances the continuous reckoner learns from paper resolutions are
estimated by a different method than the distances available at runner
closure (which use the full suffix-max sweep). The reckoner is learning
from two differently-calibrated teachers. This is not fatal — both are
honest signals — but the variance in the optimal values is higher. The
reckoner's prototypes will be noisier. Accept this cost.

**Propagation cost at near-zero defaults (Question 2).** With `trail =
0.0001`, any 0.01% price movement fires the trailing stop. Five-minute
BTC candles routinely move 0.5–2%. Every paper resolves on the first
candle. With N×M brokers and a paper per broker per candle, the resolution
queue at candle 1 is `N×M × 2` (both buy and sell sides, both resolve
immediately). For N=6, M=4 this is 48 resolutions. Each resolution calls
`post-propagate`, which is sequential. At 100k candles, the bootstrap phase
is the first ~100 candles. The total extra cost is bounded: `100 × 48 = 4800`
propagations above the steady state. This is negligible. The cost is bounded.

## On the questions

**Question 1: Should Violence weight differ from Grace weight?**

Both are on the same type — f64 fraction of price — and both are honest
measurements of the same physical quantity. The reckoner's job is to learn:
"how large should the distance be, given this thought?" Grace says: "the
trail let the price run this far" (excursion). Violence says: "the stop
caught the price this far from entry" (stop-distance). These are answers
to slightly different questions, but both inform the optimal distance.
Do not impose a separate scaling coefficient. The weight already carries
the magnitude of the outcome. Adding a separate multiplier introduces
a hyperparameter that would need calibration — which defeats the purpose
of a self-organizing system. Leave it. The difference in scale between
Grace (excursion can be large) and Violence (stop-distance is typically
small) is signal, not noise. It will naturally weight Grace observations
more heavily during profitable periods and Violence observations more
during drawdowns. That is correct behavior.

**Question 2: Is the propagation cost bounded with near-zero defaults?**

Yes. Answered above. The bootstrap phase is `O(N×M×window_size)` extra
resolutions, where `window_size` is the number of candles before the
reckoner accumulates enough observations to produce non-default distances.
With K=10 buckets and `experience > 0.0` threshold, this is reached after
the first bucket fills — approximately 10 observations. For N=6, M=4,
this is 10 candles × 48 resolutions = 480 extra propagations. Negligible.

**Question 3: Should scalar accumulators also receive Violence observations?**

They already do — `observe-scalar` routes by `outcome`. The gap is in
`extract-scalar`, which ignores the Violence accumulator. The proposal's
principle applies, but the fix is in extraction, not observation. That is
a separate proposal. Do not include it here — the change to extraction
semantics is non-trivial and orthogonal to the routing fix this proposal
makes. File it separately.
