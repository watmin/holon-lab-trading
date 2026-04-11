# Review — Proposal 021

**Reviewer:** Brian Beckman (information-theoretic perspective)
**Date:** 2026-04-10

## Verdict: The factorization is sound. Two information leaks remain.

The cascade decomposes one paper into three learning events at three
temporal moments. This is a proper factorization IF the three questions
are conditionally independent given the paper. They nearly are. The
market question (was entry right?) depends only on price action. The
exit question (were distances right?) depends on price action conditional
on a good entry. The broker question (was the pairing right?) depends on
the composition of the first two answers. The diagram commutes: each
learner receives the projection of the paper's information onto its
own question. No learner needs another's label. Clean.

**Leak 1: The binary label collapses a continuous measurement.**
The market observer gets Up/Down + weight=excursion. This is better than
pure binary — the weight carries magnitude. But the label is still a
threshold measurement: excursion > trail triggers it. The excursion at
the moment of crossing is the minimum interesting value (just above trail).
The real information is the full excursion trajectory — how far past
trail it eventually went. The weight captures the crossing-moment
magnitude, not the terminal magnitude. This is a mild leak, not fatal.
The reckoner accumulates weighted labels, so the signal survives in
aggregate. But you are throwing away the difference between "barely
crossed trail" and "ran 5x past trail" at the moment of learning. The
runner's full excursion is handed to the exit observer instead. Acceptable
if deliberate.

**Leak 2: The exit observer's selection bias is real but justified.**
Only learning from runners means the exit observer never sees "I set
distances X and the trade failed before reaching trail." This IS
selection bias in the statistical sense. But the proposal is correct
that failed entries are the market observer's problem, not the exit
observer's. The exit observer answers "given a good entry, what distances
are optimal?" Conditioning on success is not bias — it is the conditional
distribution the exit observer needs. The information about failed
distances lives in the market observer's Violence events. No information
is destroyed; it is routed to the correct learner.

**Cross-moment correlations.** Three moments from one paper — does the
factorization lose joint information? Specifically: does knowing the
entry quality change the optimal exit distances? Almost certainly yes.
A strong entry (high excursion) may warrant wider trailing stops than a
marginal entry. The exit observer receives weight=buy_excursion, which
partially encodes entry quality. But the composed thought at exit
learning time is the same thought used at entry time. The exit observer
could in principle learn "for thoughts like this, these distances work"
which implicitly captures entry strength through the thought vector.
The correlation is not discarded — it is encoded in the thought. This
is sufficient.

**Net assessment:** Information is preserved through the cascade. Each
learner receives maximal information for its specific question. The
two leaks are minor and arguably correct design choices. The proposal
resolves the label contamination I flagged in 017 — the market observer
now learns from market facts (excursion), not paper mechanics (resolution).
The signal path is clean.

The remaining bottleneck from 017 — whether the noise subspace strips
signal before it reaches the reckoner — is orthogonal to this proposal.
This fixes the label. That fixes the input. Both are needed.

**Approve.**
