# Review: Hickey

I have read Proposals 043 through 050, the guide, the programs, the
domain structs, and the propagation paths. Here is what I see.

---

## Question 1 — Are the training labels honest?

The market observer's label is the most honest thing in the system.
Directional accuracy is a pure measurement: price went up or price
went down. The observer predicted one; reality answered. The label
is a value derived from the world, not from the system's own
accounting. Good.

The position observer's label is where I start to worry. It receives
two kinds of signal through the same channel:

1. **Immediate resolution:** `is_grace` from trade outcome.
2. **Deferred batch:** `is_grace` from `error < median` of a rolling
   window of error ratios.

These are different questions. The first asks "did this trade make
money?" The second asks "was this distance prediction better than
the broker's recent average?" The position observer's reckoner
receives both through `observe_distances` with no distinction. The
reckoner treats them identically — same function, same weight
parameter, same effect on the discriminant.

This is complected. Two different judgments — outcome quality and
prediction accuracy — are braided into one learning signal. The
position observer cannot distinguish "this distance was good because
the trade profited" from "this distance was good because it was
closer to optimal than my recent median." Those are different claims
about the world. One is about the market. The other is about the
observer's own trajectory.

The broker's label is absent. Proposal 035 removed the broker's
reckoner. The broker tracks cumulative Grace/Violence and computes
expected value via EMA, but it does not learn in the reckoner sense.
This is fine — the broker is an accountant, not a predictor. But the
proposal asks if the broker's training signal is right. There is no
training signal. There is bookkeeping. Be honest about that
distinction. Bookkeeping is not learning.

## Question 2 — Phase weight modulation

The 2x weight at phase boundaries is the right level of coupling.
Here is why: the market observer's job is to predict direction from
the candle. It thinks about the candle through its lens. If you made
it think about phases directly, you would be giving it two jobs —
predict direction AND understand phase structure. Two concerns in
one entity. The weight modulation keeps the concerns separate. The
phase labeler measures structure. The weight modulation says "this
candle matters more." The market observer does not know why it
matters more. It just learns harder from it. That is composition
without complection.

However. The `near_phase_boundary` check lives in the broker program,
not in the phase labeler or the candle. `phase_duration <= 5` is a
magic number embedded in the broker program body. It should be a
value on the candle — the phase labeler already knows about phase
duration. Let the labeler decide what "near boundary" means. The
broker should read a boolean, not derive one from a threshold. The
broker is not a phase expert. It is an accountability unit.

## Question 3 — The position observer's grace_rate oscillates to 0.0

This is a direct consequence of the complection I identified in
Question 1, combined with a statistical trap.

The rolling percentile median grading works as follows: maintain 200
error ratios, compute the median, label anything below median as
Grace. By definition, roughly half the observations will be below
the median. So the deferred batch training produces approximately
50% Grace labels — but only when the window is full and the error
distribution is stable.

The problem: when the position observer improves, the errors cluster.
The median drops. But then NEW observations, produced by the improved
observer, have errors that are clustered around the new median. The
observer is chasing its own tail. Every improvement redefines what
"good" means. The median is a place, not a value. It moves as the
observer moves. This is the classic problem of self-referential
grading: the observer's output changes the grading curve that
evaluates the observer.

The immediate resolution signal has the opposite problem. During a
losing streak, every resolution is Violence. The position observer
learns "this distance was bad" even when the distance was fine and
the direction was wrong. The position observer is being punished for
the market observer's mistakes. The is_grace from trade outcome
conflates direction quality with distance quality.

Two signals, both dishonest in different ways, flowing through one
channel. Of course grace_rate oscillates to 0.0.

The fix: separate the concerns.

- The position observer should learn distances from ONE signal:
  the error between predicted distance and optimal distance. Not
  Grace/Violence. Not outcome. Geometric error. "You said trail
  should be 0.03, the market said 0.018. Learn." That is the honest
  label for a distance predictor. The continuous reckoners already
  learn from `optimal.trail` and `optimal.stop` via
  `observe_scalar`. The Grace/Violence overlay on top is a second
  opinion that contradicts the first.

- The self-assessment (grace_rate, avg_residue) should be computed
  from a SEPARATE accounting path — the broker's track record, not
  the position observer's own rolling window. The position observer
  should not grade itself. That is the broker's job.

## Question 4 — Paper lifecycle

Papers live ~8 candles and resolve 41% Grace. The question is whether
this is the right lifecycle.

The lifecycle is determined by the distances — trail and stop. Wide
distances → longer life. Narrow distances → shorter life. 8 candles
at 5-minute intervals is 40 minutes. For BTC, that is short enough
to be noise and long enough to catch a micro-trend.

41% Grace means 59% of papers hit the stop before the trail crosses.
This is asymmetric — and it should be, because the stop is a hard
boundary (price drops X%) while the trail cross requires the price
to move favorably by the trail distance AND THEN reverse by the
trail distance. The trail cross is harder to achieve than the stop
fire. 41% Grace with favorable asymmetry (Grace amounts > Violence
amounts) is a viable system. The question is not the rate — it is
whether the distances are being learned fast enough to improve the
rate.

With 508K core experience and grace_rate oscillating to 0.0, the
position observer is not improving the distances. The lifecycle is
fine. The learning signal is not.

## Question 5 — Broker composition

The broker composes `market_anomaly + position_anomaly + portfolio_biography`
into one thought. This composition is used for... nothing. The broker
has no reckoner (removed in Proposal 035). The composed thought is
stored on the paper and returned in the Resolution, but the broker
does not predict from it.

So the composition exists for the paper's stashed thought — which
is then routed back to the market observer and position observer at
resolution time. But the market observer learns from `market_thought`
(its own anomaly) and the position observer learns from
`position_thought` (its own encoded facts). Neither learns from the
composed thought.

The composed thought is a vestige. It was meaningful when the broker
had a reckoner. Without one, it is dead code that allocates vectors
every candle. The portfolio biography atoms are computed every candle,
encoded, bundled — and nobody learns from the bundle. The telemetry
records `portfolio_fact_count` and `thought_ast`, but these are
observations of a value that flows nowhere.

Either restore the broker's reckoner (give it a job that needs the
composed thought) or remove the composition. A value that nobody
consumes is not a value — it is waste.

As for whether the broker should think about phase structure directly:
the broker should think about whatever predicts Grace. If phase
structure predicts Grace, it should be in the broker's thought. But
the broker has no reckoner to learn from. The question is premature
until the broker can learn again.

## Question 6 — What's missing

Three things.

**First: a direction-independent distance signal.** The position
observer learns distances, but the training data is contaminated by
direction outcomes. When a trade hits the stop because the market
observer predicted the wrong direction, the position observer learns
"bad distance" when the real lesson was "bad direction." The distance
might have been perfect — a 2% stop on a 3% adverse move is
exactly right. But it is labeled Violence because the entry was
wrong. The position observer needs a signal that measures distance
quality INDEPENDENT of direction quality. The simulation's
`compute_optimal_distances` already knows this — it computes what
the distances SHOULD have been. The error between predicted and
optimal is the honest signal. It exists in the code. It is used for
the deferred batch grading. It should be the ONLY signal, not a
supplement.

**Second: a temporal feedback path.** The market observer predicts
direction from a single candle (through a window). The prediction
resolves ~8 candles later. But the market observer does not know HOW
LONG its prediction took to be right or wrong. A prediction that was
correct after 2 candles and a prediction that was correct after 20
candles are both labeled "correct" with the same weight (modulo
phase). Duration should modulate the signal. A quick confirmation
teaches more than a slow one — the thought was more predictive of
the immediate future. The market observer should learn harder from
fast resolutions.

**Third: cross-observer feedback.** The N market observers and M
position observers learn independently. No observer knows what the
other observers are seeing. The broker knows — it sees the
composition of market + position. But the broker cannot learn
(no reckoner). This means no entity in the system learns from the
COMBINATION of direction and distance. The broker was designed to be
this entity. Its reckoner was removed (Proposal 035) because it was
not working. But the absence of cross-observer learning means the
system cannot discover that certain (market_lens, position_lens)
pairs are complementary or redundant. The expected_value accounting
measures this after the fact, but nothing learns from it in the
reckoner sense.

The broker reckoner should come back — but with a cleaner signal.
Not Grace/Violence from paper outcomes. Grace/Violence from whether
the PAIR produced better outcomes than either observer alone would
predict. The broker's job is to evaluate the team, not the trade.

---

## Summary of complections

1. **Two learning signals (immediate outcome + deferred batch grading)
   braided into one channel** for the position observer. Separate them.

2. **Direction quality and distance quality conflated** in the
   Grace/Violence label sent to the position observer. The position
   observer is punished for the market observer's mistakes.

3. **Composed thought computed but not consumed.** The broker
   allocates it every candle. Nobody learns from it. Either use it
   or remove it.

4. **Phase boundary detection logic in the wrong place.** The broker
   program derives `near_phase_boundary` from a magic number. The
   phase labeler should derive it.

5. **Self-referential grading.** The rolling percentile median
   redefines "good" as the observer improves, creating an
   oscillating target. Grade against an external reference, not
   against the observer's own recent performance.

The architecture is sound. The separation of market observers,
position observers, and brokers is clean. The message protocol
(thought, prediction, edge) is a good abstraction. The problem is
not the structure — it is the signals flowing through the structure.
The pipes are right. Some of the water is dirty.
