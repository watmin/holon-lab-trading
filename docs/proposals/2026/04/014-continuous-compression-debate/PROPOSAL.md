# Proposal 014 — The Compression Debate

**Date:** 2026-04-11
**Author:** watmin + machine
**Status:** PROPOSED
**Follows:** Proposal 013 (unresolved)

## Context

Proposal 013 identified that the continuous reckoner has no compression.
The discrete reckoner accumulates into prototypes — O(1) query. The
continuous reckoner stores raw observations — O(N) query. Two designers
reviewed. Both accepted F (similarity gating at the call site). They
disagreed on the reckoner internals.

## The disagreement

### Hickey's position: D+F now, A later

Cap observations at 100-200. Add per-broker staleness checks. Simple.
Bounded. Obvious. Not algebraically satisfying — doesn't need to be.
It buys time while the real compression is understood.

The single-prototype accumulator (A) is the correct long-term answer.
One direction in thought-space. One cosine per query. But only after
measuring whether one direction captures enough of the regression.

Rejects B (bucketed accumulators): "You have braided discretization
policy with the regression. Bucket boundaries are a new parameter
that encodes assumptions about the scalar distribution. You are now
tuning bucket counts instead of solving the problem."

Rejects D (from Beckman's lens): Beckman says FIFO is not a monoid.
Hickey would respond: "The monoid is a nice property, not a
requirement. The reckoner's job is to return a scalar. A capped buffer
returns a scalar. Whether the buffer has algebraic structure is a
concern of the mathematician, not the machine."

### Beckman's position: B+F+E

Bucketed accumulators. K=10-20 buckets over the scalar output range.
Each bucket IS a commutative monoid under bundling — the same algebra
the discrete reckoner uses. Query: cosine against K prototypes,
soft-weight top-2-3, interpolate. O(K×D), constant in observations.

The natural transformation from brute-force to bucketed: partition
existing observations into K buckets, bundle each into its prototype,
discard raw observations. One-time migration. Query interface unchanged.

Rejects A (single prototype): "Collapsing to one prototype is taking
the colimit of a diagram and asking which object you came from. The
information is gone. The diagram does not commute with recovery."

Rejects D (capped FIFO): "A bounded FIFO is not a monoid. Eviction
is order-dependent. Merging two capped buffers gives different results
depending on interleaving. You lose the ability to reason algebraically
about what the reckoner knows."

## The questions for the debate

1. **Hickey to Beckman:** The bucket boundaries are parameters. Who
   chooses them? The scalar range [0.001, 0.10] is known from the
   domain — trail and stop distances. But the bucket WIDTH within
   that range encodes an assumption about resolution. Is that not a
   magic number wearing algebraic clothes?

2. **Beckman to Hickey:** A capped FIFO loses old observations by
   position, not by relevance. An observation from candle 50 that
   perfectly predicts the current market is evicted to make room for
   a recent observation that may be noise. Is recency a valid proxy
   for relevance? Can you justify the information loss?

3. **Both:** F (similarity gating) is unanimous. But what threshold?
   Cosine > 0.99? > 0.95? > 0.90? The threshold determines how often
   the reckoner is actually queried. Too high and you query almost
   every candle (no savings). Too low and you reuse stale answers
   (accuracy loss). Is the threshold itself a magic number? Or can
   it be derived from the reckoner's own experience?

4. **Both:** The discrete reckoner compresses into prototypes because
   the output is categorical. The continuous reckoner's output is a
   scalar. Is there a compression that is natural to scalar prediction
   over high-dimensional inputs? Not borrowed from the discrete case
   (buckets are borrowed categories). Not borrowed from linear algebra
   (subspace is borrowed projection). Something native to the problem
   of "given a thought, what scalar?"

## The format

Each designer responds to the other's objections and to the four
questions. Then a verdict. The datamancer reads both and decides.
