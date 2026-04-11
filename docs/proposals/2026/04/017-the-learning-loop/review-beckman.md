# Review — Proposal 017

**Reviewer:** Brian Beckman (information-theoretic perspective)
**Date:** 2026-04-10

## Verdict: Theory 3 is the primary bottleneck

The signal path is: candle -> thought vector -> noise-stripped residual -> reckoner -> prediction -> paper -> label -> back to reckoner. The question is where mutual information between the input (market state) and the output (correct direction) drops to zero.

**Theory 1 (label contamination):** Real but secondary. With symmetric default distances (0.015/0.030 both sides), the label is dominated by market direction. The coupling is a second-order effect that grows only after exit reckoners diverge — which they haven't, because disc_strength is 0.003. The contamination requires learning to have already occurred. It hasn't. Not the bottleneck today.

**Theory 2 (edge computation):** A bug, not a theory. Predicting on the zero vector yields zero information by construction. Fix it. But this only gates real trading — papers still run, and papers aren't learning either. Necessary fix, insufficient explanation.

**Theory 3 (noise subspace strips signal):** This is the bottleneck. Here is the argument.

The noise subspace learns the k=8 strongest principal components of all incoming thoughts. In market data, the strongest directions ARE the signal — trend, momentum, volatility regime. These are high-variance precisely because they carry information. CCIPCA doesn't distinguish signal variance from noise variance; it learns whatever has the largest eigenvalues. The anomalous component (the residual) is then the part of each thought that the subspace CANNOT explain — by construction, the lowest-variance directions. You are feeding the reckoner the least informative part of every thought.

This is a category error imported from the DDoS domain. In DDoS detection, normal traffic IS the high-variance bulk and attacks ARE anomalous deviations. The functor from (traffic space -> anomaly score) preserves information because attacks live in the residual. In markets, the situation is inverted: the predictive signal lives in the bulk (the principal components), not in the residual. The same functor applied to market data strips the very information you need. The diagram does not commute across domains.

At k=8 in a space where maybe 10-15 directions carry meaning, you are projecting away the majority of the signal. disc_strength at 0.003 is exactly what you'd expect from a reckoner trained on the noise floor.

**Theory 4 (similar thoughts):** Plausible but testable. Measure pairwise cosine between observers' thoughts. If they're >0.8, the lenses aren't differentiating. But even with perfect differentiation, Theory 3 kills the signal before it reaches the reckoner.

**Theory 5 (needs more time):** No. A system that strips signal at every step doesn't converge with more data. It converges to the wrong thing faster.

## The fix

Two options, in order of preference:

1. **Don't strip.** Feed raw thoughts to the reckoner. The reckoner's own learning (prototype accumulation, discriminant sharpening) is the noise filter. The noise subspace is redundant with the reckoner and actively harmful.

2. **Invert the projection.** Instead of using the anomalous component, use the principal component — project thoughts ONTO the subspace, not away from it. This preserves the high-information directions. The subspace becomes a dimensionality reducer, not a signal stripper.

Option 1 is cleaner. The noise subspace serves no function the reckoner doesn't already provide, and it destroys information that the reckoner needs.

## Answers to the five questions

1. Label coupling is real but dormant. Fix it later when exit reckoners actually learn.
2. k=8 isn't too aggressive — ANY k is wrong. The subspace learns signal, not noise. Remove it or invert it.
3. Warmup is irrelevant if the signal is stripped before it arrives.
4. Measure cosine similarity between raw thought and noise-stripped residual. If it's near zero, the subspace ate the thought. Then measure disc_strength with raw thoughts. If it rises, you've found it.
5. The noise subspace is the change that broke it. The architecture before didn't have one. That's your answer.
