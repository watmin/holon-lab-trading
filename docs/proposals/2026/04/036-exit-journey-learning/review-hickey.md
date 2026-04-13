# Review: Hickey

Verdict: CONDITIONAL

The proposal correctly identifies a real problem: labeling every candle of a
successful runner as Grace is a lie. You are destroying information and calling
it simplicity. That diagnosis is sound. But some of the proposed remedies
introduce unnecessary complecting. Let me take the questions.

**1. Binary or continuous?**

Continuous. The error ratio is a value. A threshold is a policy decision
stapled onto a value. Let the reckoner see the value. If downstream needs
a binary gate, derive it there. Don't destroy the ratio at the source.
The reckoner already consumes weighted observations — weight IS continuous.
Use it.

**2. Threshold?**

N/A if you take my answer to (1). But if someone insists on binary: don't
pick a number. Don't pick a running median. You would be introducing a
stateful policy into what should be a pure data transformation. The whole
point of the reckoner is that IT learns the threshold from the distribution.
Feed it the ratio. Let it do its job.

**3. Consequence or geometry?**

Geometry. The consequence (residue produced) entangles the exit observer's
grade with the market observer's prediction quality and the price action.
You want the exit observer to answer one question: "were my distances
appropriate for this candle?" That is a geometric question — how far was I
from optimal? Residue tells you how the whole system performed, not how the
exit observer performed. Complecting concerns. Grade the exit observer on
what the exit observer controls.

**4. Batch weight?**

Uniform. Temporal weighting (later candles matter more) assumes later decisions
are more consequential — that is a domain assertion you have not earned.
Residue-based weighting re-introduces the consequence complection from (3).
Uniform weights let the reckoner discover which candles matter through the
geometry of the vectors themselves. Do less. Trust the algebra.

**5. Unreachable target?**

Yes, and that is fine. The optimal is a reference frame, not a goal. You are
not training a regressor to predict optimal distances. You are grading observed
behavior against a known-good baseline to produce honest labels. The reckoner
will learn the reachable subset of the space. The gap between reachable and
optimal is not a bug — it is the exit observer's permanent ignorance of the
future. That ignorance is real. The label should reflect it.

**6. Path vs bag of points?**

This is the real concern. Per-candle grading treats the journey as independent
samples. A runner that is consistently biased tight for 30 candles — surviving
only because price moved in its favor — gets 30 "close to optimal" grades
because hindsight-optimal for each candle in isolation might also be tight.
The correlation is invisible.

But: you do not need to solve this now. The per-candle grading is strictly
more honest than the current "all Grace" batch. Ship it. If correlated errors
matter, they will show up as persistent bias in the reckoner's learned
distances. You will see it in the data. That is the time to introduce
sequence-aware grading — not before you have evidence it is needed.

The proposal is sound. Feed the ratio as weight. Grade on geometry. Ship it
uniform. Measure what happens.
