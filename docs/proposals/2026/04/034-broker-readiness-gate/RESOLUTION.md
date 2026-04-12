# Resolution: Proposal 034 — Broker Readiness Gate

**Date:** 2026-04-12
**Decision:** ACCEPTED — implement

## Designers

Both accepted.

**Hickey:** The data settled it. The reframing from prediction to
readiness resolves the category error. The fallback (rolling
grace-rate as gate) is the simplest correct implementation — the
reckoner must prove it outperforms to earn its cost. Narrow the
broker's input type to enforce the constraint.

**Beckman:** The question changed, the algebra follows. Rolling
metrics are autocorrelated at the regime timescale — the reckoner
can learn readiness because slow-changing state clusters with
outcomes. Declare the ungated baseline. The 25-atom snapshot is
stored on the paper and returned unchanged at resolution.

## The changes

1. **Broker thought: opinions only.** Drop bound whole vectors.
   Drop extraction. 25 scalar atoms: 7 opinions + 7 self + 11
   derived. No candle state.

2. **Broker noise subspace reverts to reflexive default.**
   Remove the hardcoded 32. Use the initial hint (8) and let
   the reflexive subspace discover its own K from the 25-atom
   background. Simpler background = fewer needed PCs.

3. **The protocol carries but the broker ignores.** The
   raw/anomaly/ast from market and exit still flow on the pipe.
   The broker receives them. The broker doesn't use them for
   its thought. The protocol is intact.

## What doesn't change

- Market observer encoding and learning
- Exit observer encoding and learning
- The extraction pipeline (exit still extracts from market)
- The paper mechanics
- The simulation
- The broker's propagate() and learning path
- The conviction gate logic (still uses cached_edge from curve)
