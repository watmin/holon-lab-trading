# Review: Hickey

Verdict: APPROVED

---

## The diagnosis is correct and the framing is honest

This proposal identifies a real coupling. Two concerns that should hang
straight have been braided together: the noise subspace's evolving
definition of "normal" and the reckoner's accumulated prototypes. They
share the same vector space but evolve at different rates. That is the
textbook definition of complecting -- taking two independent things and
interleaving them so that you cannot reason about one without reasoning
about the other.

The data is unambiguous. 91% error at candle 1000, 722% at the end.
The more the system learns, the worse it predicts. That is not a tuning
problem. That is an architectural problem.

---

## The five questions

**1. Is the noise subspace the cause?**

Yes, almost certainly. But do not theorize -- measure. Run without
noise stripping and plot the error curve. If the error stabilizes, the
subspace drift is confirmed. If the error still grows, you have a
different problem (accumulator saturation, vocabulary instability,
something else). The experiment is cheap. The answer is definitive.
Run it before changing anything.

**2. Should the reckoner see the raw thought instead of the anomaly?**

Yes. This is the simplest correct answer. Here is why.

The noise subspace was designed for anomaly *detection* -- "is this
unusual?" That is a classification question. It produces a score: how
far is this observation from the learned background? That score is
useful. The anomalous *component* -- the residual vector after
projecting out the background -- was a secondary output. It was useful
for *attribution* (which fields are anomalous?) but it was never
designed to be a *stable input* to a downstream learner.

The reckoner was designed for *prediction* -- "given this thought,
what scalar?" That is a regression question. It needs stable inputs.
It needs the same market state to produce the same (or similar) vector
at candle 1000 and candle 100000. The raw thought satisfies this. The
anomaly does not.

These are two different concerns:

- **What is unusual?** (the subspace's job -- classification)
- **What value does this predict?** (the reckoner's job -- regression)

Composing them sequentially -- strip noise THEN predict -- conflates
them. The subspace's evolving opinion about what is normal becomes an
implicit input to the reckoner. The reckoner cannot distinguish "the
market changed" from "the subspace changed its mind about what normal
means." That is a loss of information, not a gain.

The raw thought is *stable*. It is deterministic given the candle data
and the vocabulary. It does not depend on the subspace's history. It
does not drift. The reckoner can learn from it without chasing a moving
target.

The noise subspace still has a job. It can score anomalousness -- a
scalar. That scalar can be *one input* to the thought (a fact, like any
other vocabulary atom). But the subspace should not *transform* the
thought vector. It should *annotate* it.

**3. Can the reckoner realign?**

Not well enough. The decay rate of 0.999 gives an effective window of
~1000 observations. But within that window, the subspace also evolved.
The prototypes accumulated during observations 9000-10000 were each
computed under a slightly different subspace state. The reckoner's
prototypes are not a snapshot of any single consistent definition of
"anomalous." They are a smear across 1000 slightly different
definitions. Decay helps with magnitude drift. It does not help with
directional drift in the input space.

You could increase the decay rate (0.99 instead of 0.999, effective
window ~100). This would reduce the smear but also reduce the learning
signal. You would be fighting two forces with one parameter. That is
a sign you are solving the wrong problem.

**4. Is this a fundamental tension between stripping and learning?**

Yes. And the proposal names it clearly.

The noise subspace *must* evolve to stay current. That is its purpose.
A frozen subspace cannot detect new kinds of anomalies. The reckoner
*must* have stable inputs to accumulate useful prototypes. These are
irreconcilable when the subspace sits between the data and the reckoner.

The engram idea -- freeze the subspace and score against the frozen
snapshot -- addresses the symptom but adds complexity. You would need
to decide when to snapshot, how long to keep snapshots, whether to
re-snapshot when the reckoner has "caught up." That is a synchronization
protocol between two components that should not need to know about each
other. Every synchronization protocol is accidental complexity unless
the synchronization is the actual problem being solved. Here, the actual
problem is simpler: do not put an evolving transform between the data
and the learner.

The simple answer: decouple them. The noise subspace and the reckoner
should not share a pipeline. The subspace sees the raw thought and
produces a score. The reckoner sees the raw thought and produces a
prediction. They are peers, not a pipeline. Two independent functions
of the same input. No coupling. No drift.

**5. Does the market observer have the same problem?**

It almost certainly does. The market observer has the same architecture:
noise subspace strips the thought, the anomaly feeds the reckoner. The
same mechanism produces the same drift. The only difference is the
measurement: the market observer's discrete reckoner has `recalib_wins /
recalib_total`, which is a rolling accuracy metric. The position
observer's continuous reckoners had no accuracy metric until this
session found the drift.

Query the market observer's accuracy over time. Partition the run into
segments. If accuracy is flat, the discrete reckoner is more robust to
input drift than the continuous one (possible -- discrete classification
is inherently less sensitive to small input perturbations than
regression). If accuracy degrades, you have the same problem in both
observers and the fix should be applied everywhere simultaneously.

---

## The deeper principle

The noise subspace is a *filter*. The reckoner is a *learner*. A filter
that evolves is a filter whose output distribution changes over time.
Feeding an evolving filter's output into a learner is asking the learner
to track two distributions simultaneously: the distribution of market
states AND the distribution of the filter's evolving opinion about those
states. The learner cannot separate these. It sees one input stream. It
does not know whether a change in its input came from the market or from
the filter.

This is a specific instance of a general principle: **do not put
adaptive components in series unless you can guarantee convergence of
the upstream component before the downstream component begins learning.**
The noise subspace does not converge. It adapts continuously. Therefore
it should not sit upstream of a learner.

The fix is architectural, not parametric. No amount of tuning decay
rates, snapshot intervals, or bucket counts will fix a serial
composition of two adaptive systems that evolve at different rates.
Decouple them. Let them both see the raw thought. Use their outputs
independently.

---

## What to do

1. Run the experiment: 100k candles without noise stripping. Measure
   the continuous reckoner error trajectory. Confirm the subspace is
   the cause.

2. If confirmed: change the position observer to feed the raw thought
   to its continuous reckoners. The noise subspace stays -- it produces
   an anomaly score that enters the thought as a vocabulary atom. But
   it does not transform the thought vector.

3. Measure the market observer's accuracy over time. If it degrades,
   apply the same fix.

4. Do not build engram snapshots for synchronization. That is solving
   the wrong problem with additional machinery. The right answer is to
   remove the coupling, not to manage it.

The simplest system has the fewest moving parts. An evolving filter
upstream of a learner is a moving part that moves the other moving
parts. Remove it from the pipeline. Keep it as a peer.
