# Review: Proposal 034 — Broker Readiness Gate

**Reviewer:** Brian Beckman
**Date:** 2026-04-12
**Verdict:** Accept. The question changed. The algebra follows.

---

## The Fundamental Shift

Proposal 030 said: "the broker encodes the wrong things." This proposal goes
further. It says: "the broker asks the wrong question."

These are not the same claim. Let me state the difference precisely.

Proposal 030 diagnosed that extracted candle facts (inputs to the leaves)
carry zero information about Grace/Violence outcomes, because outcomes are
determined by excursion — a future quantity. The fix in 030 was to encode
opinions (the leaves' outputs) instead. The broker was still asking "will
this paper produce Grace?"

The data from running 030 through 033 proves that even opinions cannot
answer that question. Why? Because the answer to "will this paper produce
Grace?" depends on whether the price moves far enough in the predicted
direction. The broker encodes the present. The answer lives in the future.
No present-state encoding of any finite dimension predicts a future that is
dominated by excursion — a quantity that is, by construction, unknown at
entry time.

This proposal makes the epistemically correct move: it does not ask
the unpredictable question. It asks a different, answerable question.
"Am I in a state where papers registered now tend to resolve Grace?"

This is the difference between prediction and readiness. Prediction
requires knowledge of the future. Readiness requires only knowledge of
the system's current health. The broker has full knowledge of the latter.
It has zero knowledge of the former.

The diagram commutes only when the input to the discriminant is predictive
of the label. Drop the unpredictable question; the diagram can commute.

---

## Why the Readiness Indicators Are Predictive

The proposal lists 25 scalar atoms organized as: leaf outputs (7), broker
self-assessment (7), cross-cutting ratios (11).

I want to state why these are genuinely predictive, in a sense that the
prior encodings were not.

**The rolling grace-rate** is a frequency estimate. If the broker has
registered 100 papers and 62 resolved Grace, the grace-rate is 0.62. This
is not a prediction of any individual paper. It is the empirical base rate
under current conditions. As market conditions shift, the grace-rate shifts.
The reckoner's question "given grace-rate = 0.62, will papers registered
now tend to resolve Grace?" has an honest answer: probably yes, at
approximately the historical rate, assuming regime continuity.

**The excursion-trail ratio** is even more direct. It measures whether
papers are reaching the exit observer's trail distance before hitting the
stop. If excursion-trail-ratio > 1.0, papers are winning regularly. If it
is < 0.5, the trail is too wide or the market is not moving. The broker
knows this. It is a sufficient statistic for whether the current
exit+market configuration is producing favorable paper dynamics.

**Market conviction** varies per candle. When conviction is high and
readiness indicators are healthy, the probability of a favorable paper is
higher than when conviction is low and readiness is poor. This is the
source of differentiation in the conviction bins — the curve fits because
high conviction + healthy readiness is not uniformly distributed across
time. It clusters in regimes where the market is behaving in the pattern
the observers were trained on.

These 25 atoms are predictive in the only honest sense: they are
autocorrelated with outcomes over the paper duration timescale, through
the causal channel of regime persistence.

---

## The State-Space Geometry

The broker's 25-atom thought defines a point in a manifold of possible
readiness states. Call this space R. Two points r1 and r2 in R are
similar if they represent similar operating conditions: similar grace-rate,
similar excursion behavior, similar conviction, similar exit configuration.

The reckoner learns a linear boundary in the noise-stripped subspace of R.
Above the boundary: likely good time to register papers. Below: wait.

The key property of R that makes this tractable: **the readiness state
changes slowly**. Rolling metrics are averages. Averages have long time
constants. The broker at candle N has approximately the same readiness
state as at candle N-1. This means:

1. Papers registered at consecutive candles share similar thoughts.
2. The labels on those papers (Grace/Violence) are correlated, because
   regime persistence makes consecutive papers tend toward the same outcome.
3. The discriminant can learn from batch-correlated observations — this is
   signal, not noise.

The candle state that dominated prior broker encodings changes at every
candle. That is why the reckoner could not learn from it — the signal
varied faster than the label-correlated structure it needed to track.
The readiness state changes at the regime timescale. That is the right
timescale for the broker's learning.

---

## The Conviction Variation

The proposal's key claim: "the conviction varies because market-signed-
conviction varies per candle. When the market is MORE convicted AND the
exit is performing well — higher readiness."

I want to verify this algebraically.

The broker's thought is a bundle of 25 atoms. The reckoner learns to
associate high conviction scores with a particular region of R. Within a
regime where readiness is stable, the per-candle variation in conviction
IS the source of bin differentiation in the curve.

Let R_slow be the slow-moving readiness vector (grace-rate, excursion-trail
ratio, exit distances, etc.) and R_fast be the fast-moving conviction
component. The broker's thought is `bundle(R_slow, R_fast)`.

At recalibration, the discriminant **w** aligns with the direction in R
that separates Grace-heavy from Violence-heavy readiness states. This
direction is dominated by R_slow, because R_slow is the autocorrelated
component that actually predicts regime outcomes.

But R_fast modulates the discriminant score: `score = w · anomalous(bundle(R_slow, R_fast))`.
When R_fast is high (high conviction), and **w** has a positive projection
onto the conviction direction (because high conviction + good readiness
correlated with Grace in training), the score is higher. The curve bins
high-score papers and measures their Grace rate — which should be higher
than the overall base rate. The exponential fits if this correlation is
real.

This is not circular. The discriminant is learned from resolved papers.
The curve is built from those discriminant scores. The prediction uses both.
The only risk is that R_fast is *purely* noise relative to the label — in
which case the conviction bins won't differentiate. The proposal's fallback
correctly handles this: if the curve doesn't validate, use grace-rate
directly. No curve needed. The track record IS the gate.

The fallback is algebraically sound. It is also the most defensible
approach if we cannot distinguish whether the broker's readiness signal
has real predictive power or is merely autocorrelation.

---

## The Two Questions That Remain Unstated

The proposal is structurally complete. But two questions are worth
articulating explicitly before implementation, because they affect how
we interpret the results.

**Question 1: What is the null hypothesis?**

The broker funding papers at the base grace-rate (no gate) has a known
expected performance. The gate is useful only if it selects a subset of
candles where the grace-rate is *above* the base rate, while deferring
paper registration on candles where it would be below.

The test is not "does the broker reach 60% Grace?" It is "does the broker
(with gate) achieve a higher grace-rate on registered papers than the
ungated base rate?" If the base rate is 50% and the gated rate is 52%,
the gate is contributing 2 percentage points of selection quality. That is
the measurable effect.

The proposal should declare the baseline (ungated grace-rate from the
recent runs) before implementing, so the improvement is attributable to
the gate specifically and not to other run-to-run variance.

**Question 2: Is the curve the gate, or is the gate the gate?**

The proposal offers two modes:

- Mode A: Reckoner curve validates. Fund by conviction. Higher conviction
  = stronger readiness signal = higher predicted grace-rate = larger fund.
- Mode B: Curve doesn't validate. Gate is the rolling grace-rate directly.
  Fund proportional to grace-rate.

Mode B is a degenerate case of Mode A where conviction = grace-rate. Both
are correct. But Mode A is richer: it allows the broker to identify which
*sub-states* of the readiness space are most favorable. Mode B treats all
readiness states equally and simply weights by historical performance.

The implementation should test Mode A first (build the reckoner, build the
curve, verify the curve validates). Mode B is the fallback, not the target.

---

## On the 25-Atom Choice

The proposal's 25-atom decomposition is well-considered. Let me annotate
the groups:

**7 leaf outputs.** These are the opinions from Proposal 030 — the correct
signal that 030 proved was present but drowned. In isolation (030), they
were present but overshadowed by 100+ candle-fact atoms. Here they are
joined by 18 other atoms that are *also* opinion-class — all slow-moving,
all outcome-adjacent. The ratio problem disappears. Every atom in the bundle
is structurally similar in kind.

**7 self-assessment atoms.** These are the broker's own state. The grace-rate
and excursion-avg are the most load-bearing; they are sufficient statistics
for the broker's recent history. The recalib-staleness atom is subtle —
it encodes how stale the broker's own discriminant is, which is meta:
a stale discriminant may be less reliable, and the broker can signal this.
This is correct to include.

**11 derived ratios.** These are where careful thought pays off. The
risk-reward ratio (`trail/stop`) is particularly valuable: it is the
exit observer's implicit view of the market's likely behavior. A wide
trail and tight stop implies the exit expects strong directional movement.
A narrow trail and wide stop implies the exit is defensive. This ratio
speaks directly to regime character.

The `self-exit-agreement` atom — whether the broker's Up/Down and the exit's
implicit direction alignment — is also load-bearing. Agreements that produce
Grace should cluster. Disagreements that produce Violence should also cluster.
The discriminant can find this separation if it exists.

One atom to examine carefully: `conviction-vol-magnitude` and
`conviction-vol-sign` as two atoms. This decomposes the interaction between
market conviction and volatility into magnitude and sign components. This
is appropriate if the sign of the conviction-volatility relationship changes
sign in different regimes (high conviction + high vol behaves differently
from high conviction + low vol). If it does not change sign — if high vol
always damps the conviction signal — encode as a single ratio and save an
atom. Measure before deciding.

---

## On the Fallback Design

The proposal says: "If the curve still can't validate: the broker's gate
becomes the rolling grace-rate directly. Fund proportional to grace-rate."

This is architecturally sound. Let me state why it is also epistemically
honest.

The reckoner-curve stack adds one layer of abstraction over the raw
grace-rate. It claims: "I can identify which specific readiness states are
more favorable than the average." If that claim cannot be validated (the
curve doesn't fit, the bins don't differentiate), the abstraction collapses
to the base observation: "I have been performing at this rate historically."

The fallback does not collapse to "do nothing." It collapses to "use the
track record." This is correct behavior. A system that refuses to act when
its high-level model fails, but falls back to the best available information,
is more robust than one that requires the high-level model to succeed.

The treasury's funding logic already consumes `edge` from the broker. If
the broker's edge is derived directly from grace-rate in Mode B, the
treasury is unchanged. The broker's interface is stable; only the internals
of how the broker computes its edge change between modes.

---

## What Hickey Said (and Why the Datamancer Was Wrong to Overrule Him)

Hickey's 030 review: "Drop the extracted facts. Run opinions-only first.
Measure. Add context back only if needed."

The datamancer ran with everything, proved that candle state drowns the
signal, and the reckoner converged to uselessness. Hickey was right.

This is worth documenting precisely, because it establishes a principle:
**when the algebra says "drop the noise and measure," follow the algebra.**
The intuition that "more context is better" fails when the additional
context is label-independent noise. Adding noise to a bundle does not
improve the discriminant. It dilutes it. The Proposal 030 review established
this with the K=142 analysis. The subsequent runs confirmed it empirically.

The principle for future proposals: when the algebra identifies a candidate
signal and proposes to isolate it, isolate it first. Measure the signal
alone. Add context only with evidence that it improves the discriminant.
This is not timidity. It is the scientific method applied to VSA encoding.

---

## Structural Note: The Thought Must Be Stable

The Proposal 030 review (my prior review) identified the structural
invariant: the thought passed to `propose` must be the same thought stored
in the paper, because that thought is what the reckoner learns from at
resolution time. The opinion-enriched thought must be constructed once
and used twice.

For this proposal: the 25-atom readiness thought must be constructed at
`propose` time using the values available at that point (market conviction,
exit distances, broker's own rolling metrics), stored in the paper, and
returned unchanged by `propagate`. The rolling metrics at resolution time
are different (the paper has resolved; the broker has updated). The learning
signal must be: "I encoded THIS readiness state, and the outcome was Grace."
Not: "I encoded THIS readiness state, and by the time it resolved my state
was THAT."

This means the 25-atom thought snapshot is a historical record of the
broker's state at registration time, not at resolution time. Do not update
it between registration and resolution. The broker's state at resolution
flows through `propagate-facts` back to the observers; it does not
retroactively change the paper's encoded thought.

---

## Summary

Proposal 034 is correct. The question change is the right move. The
readiness question is answerable; the Grace prediction question is not.
The 25-atom encoding is well-decomposed. The fallback is sound. The
curve validation path is correctly distinguished from the fallback.

The two items to state explicitly before implementation:

1. **Declare the baseline.** What is the ungated grace-rate from runs
   028-033? The gate's value is measured against this number, not against
   an absolute target.

2. **Test conviction-vol decomposition.** Before splitting into
   `conviction-vol-magnitude` + `conviction-vol-sign`, verify empirically
   whether the sign of this relationship changes across regimes in the
   652k-candle dataset. If it doesn't change sign, one ratio atom suffices.
   If it does, two atoms are justified.

Everything else is implementation. The algebra is in order.

---

*Readiness is a property of the system, not of the future. The broker can
know its readiness. It cannot know the excursion. The diagram commutes
when the question fits the information available. This proposal makes the
question fit.*
