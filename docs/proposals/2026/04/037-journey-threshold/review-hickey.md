# Review: Hickey

Verdict: CONDITIONAL

The EMA is the right shape. One value, one update rule, no auxiliary data structures. It threads through the fold as a value. That part is simple. But the proposal has a complecting problem and the questions reveal it.

## Answers

**1. EMA vs running median.** EMA. The median requires a sorted buffer — that's a place, not a value. You'd need to maintain a ring, sort or partition on every observation, decide on a buffer size. The EMA is a fold over a scalar. It is strictly simpler. The objection that it's "sensitive to outliers" is a feature: if the exit observer produces outlier errors, the threshold should reflect that. You're measuring what the observer actually does, not some robust statistic of what it usually does.

**2. Per-broker vs per-exit.** Per-broker. The proposal already states the answer and then second-guesses it with "sample size says per-exit." Sample size is a statistical concern. Isolation is an architectural concern. Architecture wins. Each broker is the accountability unit — the proposal's own parent says so. If a broker doesn't have enough observations for its EMA to converge, that's information: it hasn't been tested. Don't paper over it by pooling with brokers that have different histories.

**3. Fixed or learned alpha.** Fixed. The proposal asks whether to learn the alpha, but learning a learning rate is a recursion with no ground. Pick 0.01, ship it. If you want regime sensitivity, that belongs in the vocabulary (the observers' job), not in the grading mechanism. The grading mechanism should be boring. It should be the last thing you tune.

**4. Initial value.** The 0.5 seed is fine. It's wrong and it knows it's wrong. After 100 observations at alpha=0.01, the seed contributes less than 37% of the value. After 200, less than 14%. The alternative — "seed from first N observations" — requires you to define N, buffer N observations, and handle the pre-N regime differently. That's three decisions to avoid one that solves itself.

## The condition

The `set!` in the pseudocode. The EMA is described as a value threading through a fold but implemented as mutation. Make it a fold accumulator: the EMA is part of the state that the batch-processing function carries forward and returns. The broker already owns scalar accumulators. This is one more. No `set!`. No place. A value.

Do that and this is approved.
