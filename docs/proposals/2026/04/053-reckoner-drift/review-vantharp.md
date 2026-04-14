# Review: Van Tharp

Verdict: CONDITIONAL

## The position sizing read

Position sizing is the most important factor in any trading system's
performance. Not entry. Not prediction. Sizing. And sizing depends entirely
on knowing your R-multiple distribution — the ratio of profit to initial
risk on every trade. Your initial risk is set by the safety stop. Your
trailing behavior is set by the trail stop. If those distances are wrong,
your R is wrong. If your R is wrong, your position sizing is wrong. If your
position sizing is wrong, nothing else matters.

This proposal describes a system where the mechanism that DETERMINES R is
degrading over time. That is not a software bug. That is an existential
threat to the trading system's ability to size positions.

Let me be specific about the damage.

## What drift does to R-multiples

The safety stop defines 1R — the unit of risk. If the reckoner predicts a
stop distance of 2% but the optimal was 5%, the system THINKS it is risking
2% but the market requires 5%. The system will size the position as if 2% is
the risk unit, allocating 2.5x more capital than the true risk justifies.
When the stop triggers at 5%, the loss is 2.5R instead of 1R. The position
sizing model — Kelly, fixed fractional, whatever — assumed 1R losses.
Getting 2.5R losses destroys the edge.

The inverse is equally destructive. If the reckoner predicts 5% but optimal
was 2%, the system under-sizes. It survives, but it leaves compounding on
the table. Over thousands of trades, the opportunity cost is enormous.

At 722% trail error and 479% stop error, the system's R-multiple distribution
is fiction. The system is sizing positions against a fantasy risk profile. It
is taking random-sized bets while believing they are calibrated. This is worse
than no sizing at all, because the system's confidence in its sizing creates
a false sense of control.

## Answers to the five questions

### 1. Is the noise subspace the cause?

The mechanism described is plausible and specific. But plausible is not
proven. I need the ablation.

Here is why this matters from an expectancy perspective: if the noise
subspace is NOT the cause, then the reckoner itself has a sample problem.
132K observations through a 10-bucket system with 0.999 decay means an
effective window of ~1000 observations spread across 10 buckets. That is
~100 effective observations per bucket. Each bucket's prototype is the
decayed sum of ~100 recent thought vectors. The query interpolates the
top 3 buckets by raw dot product.

If the inputs are stable (raw thoughts), 100 observations per bucket may
be sufficient. If the inputs are drifting (anomalies under a moving
subspace), 100 observations per bucket is not enough to track the drift.
The prototype is always chasing a target that moved since the last
observation. The effective sample size for any given market state is
smaller than it appears.

Run the ablation. Raw thought in, measure error over time. If the error
stabilizes, the subspace is confirmed as the cause. If it still grows,
the reckoner's bucket resolution or decay rate is the problem, and the
fix is different.

### 2. Should the reckoner see the raw thought instead of the anomaly?

Yes. For a reason that is specific to position sizing and has nothing to
do with software architecture.

The purpose of exit distances is to define risk. Risk is a function of
market structure: volatility, momentum, extension. These are ABSOLUTE
properties of the market state. They are not relative to what is "normal."

Consider: ATR (Average True Range) does not care whether today's volatility
is normal for this market. It measures what the volatility IS. You set your
stop at 2x ATR because you need room for the market to breathe. Whether that
breathing room is typical or unusual is irrelevant to the sizing decision.

The noise subspace asks: "what is unusual about this candle?" That is the
right question for prediction (is this candle a signal for direction?). It
is the wrong question for risk measurement. Risk measurement asks: "what
IS this candle?" The raw thought encodes what the candle IS. The anomaly
encodes what the candle is NOT (relative to background). Distance prediction
needs IS, not IS-NOT.

There is a second, statistical argument. The raw thought is a deterministic
function of the candle data. Same candle, same thought, forever. The anomaly
is a function of the candle AND the subspace state at the time of encoding.
Two identical candles at different points in the run produce different anomaly
vectors. This means the reckoner's sample is polluted — observations that
should reinforce each other (similar market states) instead scatter across
the vector space because the subspace was in a different state when each was
observed.

This scattering reduces the effective sample size. Fewer effective
observations per bucket means noisier prototypes. Noisier prototypes mean
noisier interpolation. Noisier interpolation means noisier distance
predictions. Noisier distances mean noisier R-multiples. Noisier R-multiples
mean the position sizing model is working with garbage inputs.

Feed the raw thought to the position reckoner.

### 3. Can the reckoner realign?

The decay mechanism (0.999 per observation) gives an effective window of
~1000 observations. If the subspace were frozen, 1000 observations would be
enough to fully replace the prototypes. The problem is that the subspace is
NOT frozen — it continues to evolve during those 1000 observations. The
prototypes are always a weighted average of anomalies produced under
DIFFERENT subspace states within the window.

Think of it as a moving average applied to a non-stationary signal. The
moving average will always lag. The lag IS the drift error. You could shorten
the window (increase the decay rate), but then each bucket has fewer
effective observations and the prototypes become noisier. Shorter window
reduces drift but increases variance. You cannot win both.

The engram snapshot approach is the synchronization solution. Freeze the
subspace, let the reckoner learn under the frozen reference frame, then
periodically update both together. This is mechanically sound. It
eliminates the drift because the reckoner and its reference frame are
locked together.

But it introduces a new problem: the engram snapshot is stale. The further
you get from the snapshot, the less representative it is of the current
"normal." You need to re-snapshot periodically, and each re-snapshot
invalidates the reckoner's prototypes (they were learned under the old
snapshot). You are back to the same problem at a coarser timescale.

The fundamental issue is that continuous regression needs a stable input
space. Either give it one (raw thoughts) or accept the complexity of
managing synchronized snapshots. I recommend the former.

### 4. Is this a fundamental tension between stripping and learning?

Yes. It is a specific instance of a general problem: non-stationary
feature engineering coupled with stationary-assumption learners.

The noise subspace performs online PCA — a continuously updating linear
transformation. The anomaly is the residual after projecting onto the
learned principal components. As the components change, the residual
space rotates. Any learner that accumulates statistics in the residual
space (prototypes, bucket centers, nearest-neighbor structures) is
accumulating in a rotating coordinate system.

For discrete classification (the market observer), this rotation is
tolerable. The boundary between Up and Down rotates with the space. As
long as the rotation is slow relative to the reckoner's recalibration
interval, the boundary tracks. For continuous interpolation, the rotation
is destructive. The interpolation depends on distances and angles between
prototypes and queries. Rotation changes both.

The resolution depends on the task:
- **Classification (direction):** noise stripping helps. The anomaly
  concentrates discriminative signal. The rotation is tolerable. Keep it.
- **Regression (distances):** noise stripping hurts. The regression needs
  geometric stability. The rotation destroys it. Remove it.

This is not a universal truth. It is a property of the coupling between
a non-stationary transform and the downstream task's sensitivity to the
transform's evolution. Know which task needs which input.

### 5. Does the market observer have the same drift?

It may, but the impact on position sizing is indirect. The market observer
predicts direction — Up or Down. If direction accuracy degrades, the system
takes more wrong-direction trades. But the R-multiple distribution is still
honest: each trade's risk is correctly sized (assuming exit distances are
correct). The win rate drops, but the R per trade remains calibrated. The
expectancy (win% x avgWin - loss% x avgLoss) drops because win% drops, not
because the R-multiples are lying.

The position observer's drift is more dangerous because it corrupts the
R-multiples themselves. A 722% error on trail distance means the system
does not know what 1R is. If you do not know what 1R is, you cannot compute
expectancy. If you cannot compute expectancy, position sizing is random.

That said: measure the market observer's accuracy over time. If it degrades,
the direction predictions are also drifting, and the expectancy calculation
is wrong from both sides — wrong win rate AND wrong R-multiples. That would
be a compounding error.

## The prescription

**Condition 1:** Run the ablation. Position observer with raw thought input,
no noise stripping on the exit reckoners. Measure trail error and stop error
at 1K, 5K, 10K, 50K, 100K candles. If the error stabilizes (does not grow
with experience), the subspace drift is confirmed as the cause.

**Condition 2:** If confirmed, remove noise stripping from position observers
permanently. The reckoners that predict distances see the raw thought. The
noise subspace stays on market observers where it serves direction prediction.

**Condition 3:** After the fix, re-measure the R-multiple distribution. Plot
predicted stop distance vs actual stop distance over time. The correlation
should be stable. If the predicted stop is a reliable estimate of actual
risk, the position sizing model can trust its inputs.

**Condition 4:** Measure the market observer's accuracy curve over time.
Even if it is not urgent, document whether the discrete reckoner is robust
to subspace drift. This is a property of your system that you need to know
for all future observers.

The noise subspace may be adding genuine signal to direction prediction. But
it is adding noise — measured, growing, 7x noise — to distance prediction.
A position sizing model cannot tolerate uncertain risk. The risk unit must
be honest. Remove the uncertainty from the risk measurement pipeline. Leave
the signal extraction where it helps.

Expectancy is win rate times average win minus loss rate times average loss.
If your average loss is a fiction because your stop distances are a fiction,
your expectancy is a fiction. Fix the distances first. Everything else —
direction accuracy, edge calculation, capital allocation — depends on
knowing what 1R actually is.
