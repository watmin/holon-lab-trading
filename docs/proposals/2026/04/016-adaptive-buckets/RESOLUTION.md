# Resolution: Proposal 016 — Adaptive Buckets

**Date:** 2026-04-11
**Decision:** REJECTED — both designers said no. Fixed K=10 stands.

## The designers

**Hickey:** "When a value suffices, do not substitute a process."

**Beckman:** "The proposal proved the data CAN discover K. But 'can'
is not 'should.' The redistribution on split is algebraically unproven."

Both unanimous. Fixed K wins on error, cost, predictability, and
algebraic cleanliness.

## The datamancer's note

K=10 and range=[0.001, 0.10] are magic numbers. They work for BTC
at 5-minute resolution. They are not universal. The kernel must
accept them as parameters — the application provides domain knowledge.
The magic will be killed later. Make it work now.

The experiment (adaptive_buckets.rs) stays in the repo. It proved
the data can find structure. That thought survives for when we're
ready to kill the magic properly.
