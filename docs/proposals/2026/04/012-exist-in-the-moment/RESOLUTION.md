# Resolution: Proposal 012 — Exist in the Moment

**Date:** 2026-04-10
**Decision:** ACCEPTED

## The designers

**Hickey (ACCEPTED):** "Prediction and learning are two independent
timelines coupled by accident, not by necessity. You are paying 250
vec ops for a distinction without a difference. The moment is for
acting. The past is for learning. Let them breathe at their own pace."

Condition: bound the learn queue. Defer timing, never discard content.
Measure when shedding occurs.

**Beckman (ACCEPTED):** "The reckoner is a commutative monoid.
Deferral is just a particular sub-batching. The algebra guarantees
convergence. Your reckoner is a CRDT."

Condition: synchronous warmup phase while the discriminant is thin.
Async after sufficient mass.

## The decision

Decouple prediction from learning. The hot path is constant per
candle: encode the moment, predict, act. The learning runs on its
own schedule — deferred, batched, eventually consistent.

Warmup: synchronous for the first N candles (until the reckoner
has sufficient observations). Then transition to async.

The learn queue is bounded. If it overflows, shed the oldest.
Measure when shedding occurs — that's the signal that the
learning can't keep up with the market.

## The insight

The reckoner is a CRDT. The discriminant is a commutative monoid.
The order of observation doesn't change the destination — only the
path. The prediction at candle N from a reckoner that's 50
observations behind is the same prediction within 1/3000th of the
discriminant's mass.

The machine exists in the moment. The moment is the prediction.
The past is the learning. They breathe at their own pace.
