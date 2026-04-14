# Review: Seykota

I have studied your six training loops across proposals 043 through 050.
I have read the broker program, the market observer program, the position
observer program, and the paper entry mechanics. Here is what I see.

## Question 1: Are the training labels honest?

The market observer label is almost honest. Direction correct or
incorrect — that is clean. But there is a timing lie embedded in the
system. The market observer learns from a paper that lives approximately
8 candles. The label says "was the predicted direction correct over the
paper's lifetime?" This is not the same question as "was the predicted
direction correct over the next candle" or "was the predicted direction
correct over the trend." You have chosen an arbitrary horizon — the
paper lifetime — and called it truth.

A trend follower does not ask "was I right over 8 bars." A trend
follower asks "did I catch a trend." The 8-bar horizon is too short to
capture a real trend and too long to be a clean directional signal. You
are training the market observer to predict medium-frequency noise. The
label is honest about what it measures. It is not honest about what
matters.

The position observer labels are worse. The immediate Grace/Violence
signal from the paper outcome is contaminated by the distance predictions
themselves. If the position observer sets a tight stop, more papers hit
Violence. If it sets a wide stop, more papers survive to Grace. The
position observer is learning from its own previous answers. This is a
feedback loop, not a learning signal. The observer's predictions change
the distribution of its own training labels. That is the definition of
a self-fulfilling prophecy.

The deferred batch training (journey grading) has its own problem. The
rolling percentile median converges because the errors converge. When
the reckoner starts producing consistent answers — whether good or bad
— the median tracks those answers and everything clusters around it.
The label becomes "are you more wrong than usual" rather than "are you
wrong." A system can be consistently terrible and grade itself Grace
because it is consistently terrible.

The broker labels are the most honest of the three. Grace from
excursion, Violence from stop. Dollar P&L with fees. That is close to
real accountability. But the broker has no reckoner — it is pure
accounting. The learning that matters (market direction, position
distances) happens upstream, and those labels are the ones I distrust.

## Question 2: Weight modulation at phase boundaries

The 2x weight modulation is the wrong mechanism for the right intuition.

The right intuition: phase boundaries are where the trend changes.
These are the moments that matter most for a trend follower. Getting the
direction right at a turn is worth more than getting it right in the
middle of a move.

The wrong mechanism: doubling the weight teaches the market observer
"this candle matters more" without teaching it "this is a turn." The
observer does not know WHY the weight is doubled. It cannot learn the
structure of turns because it cannot see them. It just knows that some
predictions are amplified. If the observer happens to be wrong at a
boundary — which is likely, because boundaries are where the old signal
is strongest and the new signal is weakest — the doubled weight
amplifies the wrong lesson.

Phase boundaries are where the trend follower is most likely to be
wrong. That is the nature of turns. The old trend signal persists. The
new direction has not confirmed. Doubling the weight at the moment of
maximum confusion is doubling the noise.

The market observer should see phases directly. Not as weight
modulation. As vocabulary. Let it think about "this is a transition"
and "this is a valley." The phase label is already on the candle. The
position observer already thinks about it. The market observer is the
only component that cannot see the structure it is supposedly responding
to.

Keep the weight modulation if you want, but understand what it does: it
makes the observer more sensitive to boundary candles without giving it
any information about why those candles are boundaries. That is like
turning up the volume on a radio without tuning it to a station.

## Question 3: Position observer grace_rate oscillates to 0.0

This is the feedback loop from Question 1, made visible.

The position observer predicts distances. Those distances determine
where the trail and stop triggers sit. The triggers determine Grace or
Violence. The Grace/Violence labels train the position observer.

When the reckoner starts producing consistent distance predictions, the
papers resolve predictably. The rolling percentile window fills with
similar errors. The median converges. Then any small shift in market
conditions pushes errors above the converged median, and everything
grades Violence. The grace_rate crashes to zero.

This is not a grading problem or a distance-prediction problem. It is
a self-reference problem. The position observer is being graded on
outcomes that it controls. The grading standard (median of own errors)
adapts to the observer's own behavior. When the system is stable, any
perturbation looks like Violence.

The fix is to grade distance quality against something the position
observer does not control. The simulation's compute_optimal_distances
already computes hindsight-optimal distances from the actual price path.
The label should be: "how close were your distances to the hindsight
optimal?" measured absolutely, not relative to a rolling self-referential
median.

Use a fixed error threshold, or better, grade against the distribution
of optimal distances themselves. The optimal distances are a property
of the market, not the observer. They are the ground truth. The
observer's error relative to that truth is the honest signal.

The 508K core experience and 250K full experience numbers tell me the
reckoner is consuming massive quantities of contaminated labels.
Experience without honest feedback is just practice at being wrong.

## Question 4: Paper lifetime of ~8 candles, 41% Grace

Eight candles at 5-minute resolution is 40 minutes. For BTC, 40 minutes
is intraday noise. A trend follower would call this scalping, not
trading.

The 41% Grace rate tells me 59% of papers hit their stop before the
trail crosses. That means the distances are wrong — the stop is too
tight relative to the noise, or the trail target is too ambitious
relative to the actual move. Or both.

But the deeper problem is that the paper lifecycle conflates two
separate questions: "was the direction right?" and "were the distances
right?" A paper can fail (Violence) because the direction was correct
but the stop was too tight. A paper can succeed (Grace) because the
direction was wrong but the trail was loose enough to get lucky on
a countertrend bounce.

Papers should live longer. The hold architecture in Proposal 038 is the
right direction. But longer papers need wider stops, and wider stops
need larger moves to justify them. The entire distance structure needs
to scale with the paper horizon.

The every-candle registration (Proposal 043) means you are creating
overlapping papers with the same direction prediction over multiple
candles. Each paper sees a slightly different entry price. This is not
wrong — it is a form of dollar-cost averaging into a prediction. But
it means your Grace/Violence statistics are not independent observations.
They are correlated samples from the same prediction. Your 41% Grace
rate is not 41% of independent trials. It is 41% of overlapping windows
over the same price path.

For a trend follower, the right paper lifecycle is: enter on signal,
exit on counter-signal or trailing stop. The paper lives as long as
the trend. That could be 2 candles or 200 candles. A fixed-horizon paper
is a options contract, not a trend trade.

## Question 5: Broker composition

The broker composes market + position + portfolio biography into one
thought. This is three signals collapsed into one vector. The reckoner
sees the bundle, not the components.

The portfolio biography is the right idea — the broker should know its
own track record. But the biography rides inside the composed thought,
which means it influences the distance predictions and the direction
predictions through the broker's downstream effects.

The broker should think about phases directly. The portfolio biography
includes phase trend atoms (valley-trend, peak-trend, regularity,
entry-ratio, avg-spacing), which is good — that is the broker seeing
the market structure through the lens of its own positions. But those
atoms are summaries. The broker does not see the current phase label.
It does not know "right now we are in a transition" or "right now the
phase duration is 2 candles."

The broker's composition is also the input to the broker's propagation
logic. The broker decides Grace/Violence, then sends the same composed
thought to the observers for learning. The thought contains the
portfolio biography, which is the broker's own track record. The
observers are learning from thoughts contaminated by the broker's
history. When the broker has a good run, the portfolio biography
changes, the thought changes, and the observers learn different
lessons from the same market condition. The market did not change. The
broker's biography changed. The observers should not learn from the
biography.

Separate the market thought and position thought for learning (which
you already do — Proposals 024 and 026). But audit whether the
portfolio biography leaks into the anomaly vectors that the position
observer extracts market facts from. If the broker composes before
sending, and the position observer decomposes after receiving, the
biography contaminates the extraction.

## Question 6: What's missing

**A regime filter.** The system has no sense of "the market is trending"
versus "the market is ranging." A trend follower's first question is
always "is there a trend?" The phase labeler classifies local structure
(valley, peak, transition) but does not classify the regime. The
vocabulary modules include regime atoms, but there is no regime-level
learning loop. The observers learn the same way in trending and ranging
markets. They should learn differently — or at least weight differently
— based on whether the market is offering trends to follow.

**A time-of-day signal.** BTC on 5-minute candles has strong intraday
patterns. Asian session, European open, US open, US close. These
sessions have different volatility profiles, different trend
characteristics, different mean-reversion properties. The system treats
every 5-minute candle as identical. A candle at 3am UTC is not the
same as a candle at 2pm UTC.

**Conviction-weighted position sizing.** The market observer produces
conviction (from the reckoner). The position observer produces
distances. But I do not see conviction flowing into the distance
calculation or into the paper's effective size. A trend follower sizes
proportionally to conviction. High conviction, full size. Low
conviction, reduced size or no trade. The architecture has the
conviction signal. It is not using it.

**A cooldown after Violence.** When a paper resolves Violence, the
system immediately registers a new paper on the next candle. After a
stop-out, a trend follower pauses. Not because of emotion — because
the market just proved the hypothesis wrong. Re-entering immediately
means entering with the same (just-disproven) signal. The system should
wait for the signal to change before re-entering. The direction flip
logic (close runners when direction changes) is the right idea applied
only to runners. It should also apply to fresh entries after Violence.

**Cross-broker learning.** Each broker is independent. Broker slot 0
learns nothing from broker slot 7. But they are all trading the same
asset. When the momentum-volatility broker gets stopped out, the
structure-regime broker should know about it. Not to copy — to
diversify. The enterprise has a natural experiment running (N x M
brokers with different lenses), but it throws away the cross-broker
information.

**The missing feedback loop: distance quality over time.** The position
observer learns distances, but nobody measures whether those distances
are improving. The grace_rate oscillates to zero, which means the
distance predictions are not getting better. There is no meta-learning:
no signal that says "your distances used to be good and now they are
bad." The broker's expected value captures this partially through
dollar P&L, but the position observer cannot see the broker's EV. The
learning chain is broken between the quality measure (broker EV) and
the learner (position observer).

**The fundamental missing signal: trend strength.** Every trend follower
measures the strength of the current trend. ADX, moving average slope,
price above/below key levels. The system has oscillators and flow in
its vocabulary, but I do not see a clean trend-strength scalar that
modulates everything downstream. When the trend is strong, the trail
should be wide. When the trend is weak, the trail should be tight or
the system should be flat. This one scalar — trend strength — should
flow from the phase labeler through every observer and into every
distance calculation. It does not.

---

The system has sound architecture and honest infrastructure. The wiring
is correct. The labels are not. Fix the self-referential grading in
the position observer. Let the market observer see phases. Separate
the broker's biography from the thoughts that observers learn from.
Then the architecture can do what it was built to do.

The trend is your friend until it ends. Right now, your system cannot
tell the difference.
