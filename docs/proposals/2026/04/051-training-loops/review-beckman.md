# Review: Beckman

This is not an approval or rejection. The builder asked for
mathematical criticism of six training loops. Here it is.

---

## Question 1: Are the training labels honest?

The market observer learns from **directional accuracy**: did price
move in the predicted direction between entry and resolution? This
is a well-defined binary classifier. The label is a function from
(prediction, entry_price, resolution_price) → {Correct, Incorrect}.
The function is total and deterministic. The label is honest.

The position observer learns from **distance error**: how far were
the predicted trail/stop distances from the hindsight-optimal
distances? This is also well-defined — the optimal distances are
computed by simulation over the realized price path. The label is
a function from (predicted_distances, optimal_distances, threshold)
→ {Grace, Violence}. The function is total given a threshold. The
label is honest *if the threshold is honest*. More on that below.

The broker learns from **trade outcome**: did the paper produce
residue or hit the stop? This is a function from the paper's
resolution state → {Grace, Violence}. Total, deterministic, honest.

But here is the first structural problem: **the three labels are
not independent.** The market observer's directional accuracy
determines whether the paper has *any chance* of reaching Grace.
If direction is wrong, the paper hits the stop — Violence. If
direction is right, the paper's Grace/Violence depends on the
position observer's distances. The broker's outcome is the
*composition* of the two. This means:

- The position observer is graded on a sample that is **pre-filtered
  by the market observer's accuracy**. When the market observer is
  wrong, the paper resolves as Violence regardless of distance
  quality. The position observer learns "this distance configuration
  is Violence" when in fact the distance was irrelevant — direction
  was the cause. This is **confounded labeling**.

- The broker's Grace/Violence is not a function of the broker's
  *own* contribution. It is a function of the market observer's
  direction AND the position observer's distances. The broker has
  no independent degree of freedom to optimize. It is an
  accountability *measure*, not a learner. This is fine — but then
  calling it a "training loop" is misleading. The broker's
  propagate function updates dollar P&L statistics. It does not
  update any learned model. The broker's "loop" is accounting,
  not learning.

**Recommendation:** The position observer's immediate Grace/Violence
signal should be conditioned on direction being correct. When the
market observer predicted wrong, the position observer should not
learn from that paper's outcome at all — or should learn with
zero weight. The causal path is: market predicts direction →
position predicts distances → paper resolves. Learning should
respect this causal ordering. Currently it doesn't.

---

## Question 2: Is the weight modulation (2x at phase boundaries) well-defined?

The weight modulation is a function: weight(w, phase_duration) =
2w if phase_duration ≤ 5, else w. This is total and deterministic.
It has the right *intent*: structural turns carry more information
than mid-phase candles.

But mathematically it has two problems:

**Problem A: The 2x factor is a magic constant.** Why 2, not 3, not
1.5, not a continuous function of phase_duration? If the claim is
"boundary candles are more informative," the weight should reflect
*how much* more informative, which is an empirical quantity. A
step function at duration=5 is discontinuous — candle 5 gets 2x,
candle 6 gets 1x. The information content doesn't jump like that.
A decay function (e.g., w × e^{-λ·phase_duration} + 1) would be
more honest. But this is engineering, not mathematics. The step
function is a serviceable approximation.

**Problem B: The phase labeler uses 1.0 ATR smoothing.** ATR is
itself a smoothed statistic. The phase boundaries are detected
by comparing close prices to a smoothed extreme. The "boundary"
is not an event — it is a *detection* of a change that already
happened several candles ago. So when phase_duration = 1 (the
candle that triggered the state transition), the structural turn
may have occurred 2-4 candles earlier. The market observer is
being told "this candle matters more" when in fact the *previous*
candle was the one that mattered. The weight is applied to the
right signal at the wrong time.

Whether the market observer should think about phases directly:
**no.** The current coupling is correct — the market observer
thinks about the candle through its own lens. The phase structure
modulates *how much* it learns, not *what* it sees. This is the
right level of abstraction. Direct phase exposure would conflate
the market observer's concern (direction from candle structure)
with the phase labeler's concern (macro structure from price
history). The indirection through weight is categorically cleaner
than direct composition.

---

## Question 3: The grace_rate oscillation to 0.0

This is the most important question, and the answer is: **the
rolling percentile median is not a well-defined grading threshold
for this use case.** Here is why.

The journey grading uses a rolling window of N=200 error ratios.
Each new observation is compared to the median of the window. If
the error is below the median, it's Grace. If above, Violence.
Then the observation is added to the window.

By definition, the median of a sample splits it 50/50. In steady
state, approximately half of new observations will fall below the
current median and half above. This means **the grace_rate of the
deferred batch training should converge to approximately 0.5.**
If it oscillates to 0.0, something else is happening.

I see what it is. Look at the code path:

```rust
// Push into rolling window, pop front if at capacity.
if broker.journey_errors.len() >= JOURNEY_WINDOW {
    broker.journey_errors.pop_front();
}
broker.journey_errors.push_back(error);

// Median of the window
let mut sorted: Vec<f64> = broker.journey_errors.iter().copied().collect();
sorted.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
let median = sorted[sorted.len() / 2];

let is_grace = error < median;
```

The observation is added to the window **before** the median is
computed. So the median includes the current observation. For a
batch of K observations from a single runner history, each
observation shifts the window, and each subsequent observation
is compared to a median that includes all previous batch
observations.

This creates a **batch autocorrelation problem.** If a runner
accumulates 50 candles of history, those 50 observations arrive
in sequence. They likely have correlated errors (the runner was
following one price trajectory). If the errors are uniformly
high (the position observer was systematically wrong during this
runner), the first few push the median up, and then the rest
fall below the new median — Grace. If the errors are uniformly
low, the opposite happens. The batch is fighting its own shadow.

But worse: the position observer's grace_rate is computed from
a *different* rolling window (the outcome_window on the
PositionObserver struct, N=100). The *grading* window is on the
broker (N=200). The *self-assessment* window is on the position
observer (N=100). These two windows are coupled but asynchronous
— the broker grades, the position observer counts. There are
N×M=24 brokers feeding 4 position observers. Each broker has its
own journey_errors window. The position observer's grace_rate
blends signals from 6 different brokers with 6 different median
thresholds.

When the position observer is systematically wrong (large errors
everywhere), all 6 brokers' windows fill with large errors. The
medians rise. Then the position observer learns and improves
slightly. Now errors are slightly below the elevated medians —
everything is Grace. The position observer's grace_rate spikes.
The improved observer now produces lower errors. The medians
drop. Now the errors are above the lowered medians — everything
is Violence. grace_rate crashes to 0.0.

**This is a limit cycle.** The system oscillates because the
threshold tracks the learner's output. The learner optimizes
against the threshold. The threshold adjusts to the new output.
The learner's previous good performance becomes the new baseline
it must exceed. This is the Red Queen effect: you must keep
improving just to stay in the same place.

**The fix is to decouple the threshold from the learner's current
output.** Options:

1. **Frozen threshold.** Compute the median from the first 200
   observations, then freeze it. The threshold is a property of
   the environment, not of the learner.

2. **Dual-track threshold.** Maintain a slow-moving threshold
   (EMA with very small alpha, or expanding window) and a fast
   window. Grade against the slow threshold. The fast window is
   for diagnostics only.

3. **Absolute threshold.** Define Grace as error < 1.0 (actual
   was within 100% of optimal). This is ugly but stable.

4. **Quantile regression.** Instead of a binary Grace/Violence
   label, learn the continuous error directly. The position
   observer already has continuous reckoners. The binary label
   is only needed for the self-assessment grace_rate, which is
   a diagnostic — not a training signal.

Option 4 is the cleanest. The binary label is a vestige of the
market observer's categorical label (Up/Down). The position
observer predicts continuous values. Its training signal should
be continuous too. The grace_rate oscillation is a symptom of
forcing a continuous learning problem into a binary grading
framework.

---

## Question 4: Paper lifecycle (~8 candles, 41% Grace)

This is not a mathematical question — it's an empirical parameter.
8 candles at 5-minute resolution is 40 minutes. 41% Grace means
the trail-to-stop ratio favors stops. The relevant mathematical
constraint is:

**Grace_rate × avg_grace_value > (1 - Grace_rate) × avg_stop_value**

This is the Kelly criterion in disguise. If this inequality holds,
the system has positive expected value. 41% Grace is fine if
avg_grace_value > (0.59/0.41) × avg_stop_value ≈ 1.44 ×
avg_stop_value. The question is not whether 41% is too low but
whether the average Grace capture exceeds 1.44× the average
Violence loss.

The lifecycle length affects the position observer's ability to
learn. Longer trades produce more deferred batch observations
(one per candle). Shorter trades produce more immediate signals
but fewer batch observations. The batch training is where the
position observer gets dense feedback. 8 candles means at most
8 batch observations per runner (minus the ones filtered by the
10% change threshold). This is thin.

---

## Question 5: The composition market + position + portfolio

The broker composes: `bundle(market_anomaly, position_anomaly,
portfolio_biography)`. In VSA, bundling is superposition — the
three vectors are summed (with normalization). This is a
**coproduct** in the vector space: the composed thought is the
join of three independent signals.

Is this a proper product? No, and it shouldn't be. A categorical
product would require projection morphisms — the ability to
recover each component from the composition. VSA bundling is
lossy. You cannot cleanly extract market_anomaly from the
composed bundle. This is the right structure: the broker should
think about the *gestalt*, not the components. If the broker
needed to reason about components independently, the composition
would be wrong.

But there is a subtlety. The portfolio_biography includes phase
trend atoms: valley-trend, peak-trend, regularity, entry-ratio,
avg-spacing. These are computed from the paper queue and phase
history. The market_anomaly is the noise-stripped market thought.
The market thought's encoding already includes phase_label and
phase_duration (via the candle). So **phase information appears
twice in the composition**: once through the market anomaly
(indirectly, via the candle encoding) and once through the
portfolio biography (directly, via phase trend scalars).

This is not necessarily wrong — the two phase signals are
different. The market anomaly's phase content is "what phase is
the market in right now." The portfolio biography's phase content
is "what is this broker's relationship to recent phases." These
are distinct facts about different entities (market vs portfolio).
The duplication is semantic, not structural. It's fine.

Should the broker have its own phase atoms? No. The broker
already sees phases through two channels. Adding a third would
not add information — it would add noise. The broker's concern
is accountability (did this pairing work?), not phase analysis.
Phase analysis belongs to the observers. The broker synthesizes
their outputs.

---

## Question 6: What's missing?

Three things are mathematically absent.

**1. Causal isolation in learning signals.** As noted in Question
1, the position observer is graded on outcomes that include the
market observer's errors. The learning signals are confounded.
The missing structure is a **causal filter**: when direction was
wrong, the position observer should receive no learning signal
from that paper. When direction was right but distances were
wrong, the market observer should receive a partial signal (it
was right, but the system still lost — this is not the market
observer's fault, but it is information). The current system
treats each observer's learning as independent, but the outcomes
are coupled through the paper. Independence of learning requires
conditioning on the other observer's contribution.

**2. A convergence criterion for the rolling median.** The
journey grading window (N=200) has no notion of convergence.
It starts empty, fills, and then rolls. But the position
observer's learning rate doesn't account for the window's
state. During fill-up (first 200 observations), the median
is unstable — it can swing wildly as new observations arrive.
The missing structure is a **warm-up gate**: don't use the
journey grading label until the window is full. During warm-up,
use the immediate Grace/Violence signal only. After warm-up,
blend immediate and journey-graded signals.

**3. A feedback loop from the broker to the observers about
the COMPOSITION's quality.** Currently: market observer learns
direction. Position observer learns distances. No one learns
"this pairing of direction + distances was good/bad." The
broker tracks this (expected_value, grace_rate) but doesn't
propagate a composition-quality signal back to the observers.
The observers optimize their individual metrics in isolation.
The missing structure is a **joint gradient**: when the
composition produces Grace, both observers should be reinforced
proportionally to their contribution. When the composition
produces Violence, the observer whose component was more
anomalous (further from the learned normal) should receive
more of the correction. This is credit assignment — the
fundamental problem in multi-agent learning. The current
system avoids it by treating each observer as independent.
This is simpler but leaves value on the table.

---

## Summary of mathematical findings

1. **Labels are well-defined but confounded.** Each label is a
   total function. But the position observer's label depends on
   the market observer's prediction. The labels are not
   independent. This is the most important structural defect.

2. **Weight modulation is serviceable but temporally misaligned.**
   The phase boundary detection lags the structural turn by the
   ATR smoothing window. The 2x step function is crude but
   directionally correct.

3. **The rolling median threshold creates a limit cycle.** The
   threshold tracks the learner's output. The learner optimizes
   against the threshold. The result is oscillation, not
   convergence. The grace_rate going to 0.0 is the expected
   behavior of this coupled system, not a bug in the position
   observer.

4. **The composition is a coproduct, not a product.** This is
   correct — the broker should see the gestalt, not the parts.
   Phase information appears twice through different channels.
   This is semantic duplication (different facts about different
   entities), not structural redundancy.

5. **Three structures are missing:** causal isolation in learning
   signals, a convergence criterion for the journey window, and
   a joint credit assignment mechanism for the composition.

The most actionable finding is #3. The limit cycle in the journey
grading is a mathematical certainty given the current design. The
fix is to either freeze the threshold, decouple it from the
learner's output, or abandon binary grading in favor of continuous
error learning.
