# Resolution: Proposal 013 — The Continuous Reckoner Has No Compression

**Date:** 2026-04-11
**Decision:** UNRESOLVED — forwarded to Proposal 014

## The designers

**Hickey (CONDITIONAL):** D+F now. A later. Reject B, C, E.
Cap observations low. Add staleness checks. Buy time. The single-
prototype accumulator is the correct long-term answer, but only
after measuring whether one direction captures enough of the
regression.

**Beckman (CONDITIONAL):** B+F+E now. Reject A and D. Defer C.
Bucketed accumulators give K commutative monoids — the right algebra.
FIFO eviction is not a monoid; it has no associative composition.
The single prototype collapses the fiber structure — you can't
recover which context produced which scalar.

## The disagreement

Hickey rejects B: "You have braided discretization policy with the
regression. Bucket boundaries are a new parameter that encodes
assumptions. Arbitrary parameters are the opposite of simplicity."

Beckman rejects D: "A bounded FIFO is not a monoid. Eviction is
order-dependent. Merging two capped buffers gives different results
depending on interleaving. You lose the ability to reason algebraically."

Hickey rejects A later: "The right architecture, but wait until you
have data."

Beckman rejects A now: "Collapsing to one prototype is taking the
colimit and asking which object you came from. The information is gone."

## The agreement

Both accept F — similarity gating at the call site. Unanimous. O(D)
check, orthogonal to reckoner internals. Do it regardless.

## The unresolved question

The discrete reckoner compresses N observations into 2 prototypes
because the output is categorical (Up/Down). The continuous reckoner
maps thought-space to a continuous scalar. The compression that
preserves contextual variation while achieving O(1) query time has
not been found.

Hickey says: buy time with D+F, find the compression later.
Beckman says: B IS the compression — discretize the output, accumulate
per bucket, interpolate.

The datamancer does not know. Forwarded to Proposal 014 where the
designers debate each other directly.
