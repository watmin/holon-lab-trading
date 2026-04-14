# Review: Van Tharp

I have read the proposal and the code. Let me answer each question through
the lens of R-multiples, expectancy, and position sizing.

---

## 1. Are the training labels honest?

Partially. The market observer's label is honest — directional accuracy is
a clean binary signal. But the other two are contaminated.

The **position observer** receives two kinds of labels that measure
fundamentally different things. The immediate signal (Grace/Violence from
paper outcome) is a consequence of the *combined* market+position system.
The position observer gets blamed for Violence when the market observer
predicted the wrong direction. That is not the position observer's fault.
The position observer controls *distances*, not direction. A correct
distance on a wrong direction is still Violence. This conflates two
independent errors into one label.

The deferred batch labels (journey grading) have a different problem. The
error ratio `(actual.trail - optimal.trail) / optimal.trail` measures
geometric error — how far the predicted distances were from hindsight
optimal. This is honest in principle. But labeling it Grace/Violence
relative to a rolling median is a self-referential threshold. When the
system gets uniformly better or uniformly worse, the median tracks the
distribution and the label becomes noise. More on this in question 3.

The **broker's** dollar P&L computation is honest: it accounts for fees,
uses EMA with a reasonable half-life, and the expected value formula is
correct. But the broker does not have its own learning loop — Proposal 035
stripped the reckoner. The broker is an accounting gate, not a learner.
The labels flow through it but nothing in the broker *adapts* from them.
This means the broker's EV computation is reactive (trailing average) but
not predictive. The gate opens and closes based on what already happened,
not on what the current thought-state predicts will happen.

**The R-multiple structure is absent.** None of these labels express
outcomes as multiples of initial risk. The `weight` parameter is overloaded:
for Grace it is excursion (profit), for Violence it is stop_distance (risk).
These are different units. A 5% excursion weighted at 5% and a 3% stop
weighted at 3% are not comparable. The system should define 1R as the stop
distance at entry, and express all outcomes as multiples of that R. A Grace
paper that excursed 5% with a 2% stop is +2.5R. A Violence paper that hit
a 2% stop is -1R (plus fees). This normalization is what makes expectancy
calculable across different position sizes and market conditions.

---

## 2. Is 2x weight at phase boundaries correct?

The coupling level is right: weight modulation, not direct phase input. But
2x is arbitrary and the implementation has a problem.

`phase_duration <= 5` means "we are within the first 5 candles of a new
phase." At 5-minute candles, that is 25 minutes. Every candle in that window
gets 2x weight. If papers live ~8 candles and phases last ~6, then *most*
resolutions happen near a phase boundary. The 2x weight becomes the norm,
not the exception. Run the numbers: what fraction of learn events actually
receive 1x weight? If it is less than half, the modulation is not
modulation — it is a baseline with occasional dampening.

The right question is not "which candles matter more" but "which candles
have higher information content about future direction." Phase boundaries
have high information content *if* the phase labeler is accurate. But the
labeler uses 1.0 ATR smoothing, which means the phase boundary is only
identified *after* the reversal has already exceeded 1 ATR. By the time
`phase_duration == 1`, the market has already moved. The market observer
is learning from a lagging signal about a lagging measurement.

A better modulation would be: weight proportional to the phase labeler's
*confidence* (how far the move has gone relative to ATR), not just a binary
threshold on duration. Short phases that barely crossed ATR are weak signals.
Long phases that moved 3 ATR are strong signals. The weight should reflect
this.

---

## 3. The position observer's grace_rate oscillates to 0.0

This is a grading problem, not a distance-prediction problem. The rolling
percentile median with N=200 is guaranteed to label approximately 50% as
Grace and 50% as Violence *by definition* — the median splits any
distribution in half. But you report that grace_rate collapses to 0.0,
which means the immediate signals (not the batch signals) are dominating
the self-assessment window.

Here is what is happening. The position observer's `outcome_window` (size
100) receives *both* immediate Grace/Violence from paper resolution AND
the batch journey signals. The immediate signals come from every paper
resolution. The batch signals come only from runners. If the system has
long stretches of Violence (no runners), the immediate signals overwhelm
the window. The batch signals — which are the ones with honest geometric
error labels — get diluted.

But the deeper problem is: **the position observer has 508K experience in
the core lens and is still producing distances that resolve as Violence.**
That is a learning failure. Either:

1. The reckoner is converging to distances that are locally optimal for
   the median error but globally wrong for actual trade outcomes. The
   reckoner minimizes prediction error; the paper evaluates trade outcome.
   These are different objectives.

2. The noise subspace is absorbing the signal. With 8 principal components
   and 508K observations, the subspace has learned to explain *everything*.
   The anomalous component — what the subspace cannot explain — trends
   toward zero. The reckoner gets a shrinking input signal and its
   predictions lose discrimination.

3. The wrong direction from the market observer propagates Violence to the
   position observer regardless of distance quality. If market accuracy
   is 50% (random), then at most 50% of position labels can be Grace,
   and the actual rate depends on distance quality *conditional on correct
   direction*. The position observer cannot fix the market observer's
   mistakes through distance sizing.

The fix is to **decouple position labels from direction accuracy.** The
position observer should be evaluated on: given that the direction was
correct, how much R-multiple did the distances capture? And given that the
direction was wrong, how well did the stop limit the loss? These are two
separate distributions and they should be tracked separately.

---

## 4. Papers live ~8 candles and resolve 41% Grace

Eight candles at 5-minute intervals is 40 minutes. This is a scalping
timeframe. 41% Grace means 59% Violence, which at first glance looks
bad. But expectancy depends on the *R-multiple distribution*, not the
win rate.

With the current structure: Grace amount = excursion, Violence amount =
stop_distance. If average excursion on Grace is 3% and average stop on
Violence is 2%, then:

    Expectancy = 0.41 × 3% - 0.59 × 2% = 1.23% - 1.18% = +0.05% per trade

That is barely positive and fees destroy it. The system needs either:
- Higher win rate (better direction prediction), or
- Higher R-multiples on wins (let runners run longer), or
- Lower R-multiples on losses (tighter stops — but this lowers win rate)

The 8-candle lifecycle is a consequence of the distance settings, not a
design choice. If trail=2% and stop=3%, the paper resolves when price
moves 2-3% from entry, which at BTC 5-minute volatility takes roughly
8 candles. This is a natural timescale, not a parameter to tune directly.

**The real question is: should runners run longer?** Currently, a Grace
signal at trail-crossing starts runner accumulation, and the runner
resolves when price retraces past the trailing stop. If the trailing stop
is too tight relative to the phase structure, runners get stopped out
during normal retracements within a phase. The position observer should
learn to widen the trail during trending phases and tighten it during
choppy phases. This is exactly what it is supposed to do. That it does
not suggests the learning loop (question 3) is broken.

The hold architecture (Proposal 038) would help only if the problem is
that papers expire too early. But papers do not expire — they resolve
on triggers. Making them live longer means wider stops, which means
larger R-risk per trade. Without a corresponding increase in R-reward,
this worsens expectancy.

---

## 5. Should the broker think about phases directly?

No. The broker's job is accountability: did this (market, position) pairing
produce value? The broker should not have its own phase atoms because that
creates a third opinion about market structure that nobody is accountable
for. The portfolio biography is the correct level — it describes the *shape
of the broker's own experience* (how many papers, their duration, their
spacing relative to phases), not the phases themselves.

However, the composition `market_anomaly + position_anomaly +
portfolio_biography` has a problem. The broker does not learn from this
composition — it just gates on EV. The composition exists but nothing
reads the signal. If you add a broker reckoner back (undoing Proposal 035),
the composition becomes meaningful: the broker can learn which thought-
states produce Grace vs Violence at the pair level. Without a reckoner,
the composition is unused computation.

The broker's current role is pure accounting with an EV gate. This is fine
if the observers are learning well. But they are not (question 3). The
broker is the only entity that sees the full picture — market prediction,
position distances, and trade outcome together. If it cannot learn from
that picture, the system has no joint optimization. Each observer optimizes
independently, and nobody closes the loop on the *interaction* between
direction and sizing.

---

## 6. What's missing?

Three things.

**First: R-multiple normalization.** Every outcome should be expressed as
a multiple of the initial risk (stop distance at entry). This is not a
cosmetic change. Without it, the system cannot compute expectancy correctly,
cannot compare brokers across different risk levels, and cannot size
positions by edge. The `weight` field currently carries raw percentages.
It should carry R-multiples: `excursion / stop_distance` for Grace,
`-1.0` (or `-actual_loss / stop_distance`) for Violence. This single
change would make the expected value computation meaningful and would
give the position observer a proper loss function.

**Second: the position observer needs a separate label for direction-
conditional performance.** Right now it gets Grace/Violence from the
combined system. It should get two signals:
- When direction was correct: R-multiple captured (continuous label)
- When direction was wrong: R-multiple lost (continuous label, always
  negative)

These are two different distributions. The reckoner should learn to
maximize the first and minimize the magnitude of the second. Currently
both are collapsed into a single binary Grace/Violence label, which
destroys information.

**Third: there is no position sizing signal.** The proposal describes
learning loops for direction (market observer) and distances (position
observer). But position sizing — how much capital to allocate to a
trade — is missing entirely. The treasury "funds proportionally to edge"
but is not yet implemented. When it arrives, it needs its own feedback
loop: did the position size match the quality of the edge? The Kelly
criterion says optimal sizing is `edge / odds`. The edge is the
broker's expected R-multiple. The odds come from the broker's R-multiple
distribution. Neither of these exists yet because R-multiples are not
tracked.

The entire architecture — six observers, N×M brokers, treasury — is a
position sizing machine that does not yet speak the language of position
sizing. Direction prediction is step 1. Distance estimation is step 2.
But the payoff comes from step 3: sizing each trade proportional to the
quality of the signal. That step requires R-multiples as the unit of
account, expectancy as the objective function, and the Kelly fraction
as the output. None of these exist in the current training loops.

---

## Summary

The infrastructure is sound. The separation of concerns (direction vs
distance vs accountability) is correct. But the labels conflate
independent errors, the R-multiple structure is absent, the position
observer's grading is self-referential, and the position sizing signal
does not exist. The system learns to predict but not yet to profit.

The single highest-leverage change: normalize everything to R-multiples.
Define 1R = stop_distance at entry. Express all outcomes, all weights,
all expected values in R. This gives the position observer an honest
loss function, gives the broker a meaningful EV computation, and gives
the (future) treasury a sizing signal.
