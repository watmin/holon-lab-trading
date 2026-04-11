# Proposal 019 — The Signal Path

**Date:** 2026-04-11
**Author:** watmin + machine
**Status:** PROPOSED
**Follows:** Proposals 017 (learning loop), 018 (three learners)
**Evidence:** 30k candle run, disc_strength declining monotonically

## The evidence

```
candle  momentum  structure  volume  narrative  regime  generalist
 5000   0.00288   0.00290   0.00357  0.00346   0.00331  0.00246
10000   0.00184   0.00173   0.00241  0.00214   0.00197  0.00142
15000   0.00146   0.00135   0.00188  0.00172   0.00143  0.00109
20000   0.00244   0.00203   0.00289  0.00286   0.00245  0.00159
25000   0.00222   0.00182   0.00248  0.00264   0.00220  0.00138
```

disc_strength declines from 5k to 15k, bounces at 20k (recalibration
catches a momentary signal), then fades again. The noise subspace and
the reckoner are in a race — the reckoner tries to learn signal, the
subspace learns to strip it. The subspace wins because it updates
every candle while the reckoner recalibrates every 500.

## The signal path

A paper resolves. The broker has the full context:
- The market thought that went in (the raw thought before composition)
- The exit distances that managed the trade
- The price history of the paper's lifetime
- The outcome: Grace or Violence, weighted by residue

The broker propagates the RIGHT slice to each learner:

**To market observer:** "here is the thought YOU had. It was part of a
composition that produced Grace weighted by $50. Learn: this thought
preceded Grace." The market observer receives its OWN thought with the
outcome of the COMPOSITION.

**To exit observer:** "here is the composed thought. The optimal distances
from hindsight were trail=0.018, stop=0.035. Learn: for this context,
these distances extract value." Already correct.

**To broker's own reckoner:** "this composition produced Grace at weight
$50. My curve sharpens." Already correct.

## The blockage

The signal arrives at the market observer. The market observer:

1. Has the thought from the candle when the paper was registered
2. Has the direction label (Up/Down from the resolution)
3. Has the weight (the residue amount)

But at PREDICTION time (step 2, every candle), the market observer:

1. Encodes a thought from the current candle
2. Feeds it through the noise subspace → anomalous component
3. The reckoner predicts on the RESIDUAL, not the full thought

The noise subspace learns the 8 strongest principal components of ALL
thoughts. In markets, the strongest components ARE the signal — trend,
momentum, regime shifts. The subspace strips them. The reckoner gets
the noise floor.

At LEARNING time (propagation), the reckoner observes the thought
with a direction label. But at PREDICTION time, the reckoner predicts
on a different vector — the noise-stripped residual. The reckoner
learns from full thoughts but predicts on stripped thoughts. The
discriminant was built from one distribution. The predictions come
from a different distribution.

## The fix

Remove the noise subspace from the market observer's prediction path.
The raw thought goes directly to the reckoner. The reckoner's own
discriminant IS the noise filter — it learns which directions separate
Grace from Violence. The noise subspace is redundant with the reckoner
and actively harmful.

Two options:

**A. Remove noise subspace entirely.** The market observer encodes,
the reckoner predicts on the full thought. The reckoner IS the
discriminant. No stripping. The subspace field is deleted.

**B. Keep noise subspace but don't strip.** The subspace still learns
(it's useful for diagnostics — "what does normal look like?") but the
reckoner predicts on the full thought, not the residual. The subspace
becomes an observer, not a filter.

## The broker's noise subspace

The broker also has a noise subspace. Same problem? Maybe. The broker's
reckoner predicts Grace/Violence from the COMPOSED thought after noise
stripping. If the broker's subspace strips the composition signal, the
broker can't learn either.

Same fix: the broker's reckoner should predict on the full composed
thought, not the noise-stripped residual. The broker's subspace
becomes diagnostic, not functional.

## What we expect

With noise stripping removed, the reckoner sees the full thought at
both learning and prediction time. The discriminant is built from the
same distribution it predicts on. disc_strength should:

1. Stop declining (the subspace is no longer eroding it)
2. Start climbing (the signal is no longer stripped)
3. Stabilize at some level (the actual signal strength in the data)

If disc_strength still doesn't climb after removing noise stripping,
the signal isn't in the thoughts — it's a vocabulary problem, not a
pipeline problem. But the noise subspace must be eliminated first to
know.

## Questions

1. Remove (A) or keep-but-don't-strip (B)?
2. The broker's noise subspace — same fix?
3. What disc_strength proves the fix worked? 0.01? 0.05? 0.10?
4. How many candles before we judge? 10k? 20k? 50k?
