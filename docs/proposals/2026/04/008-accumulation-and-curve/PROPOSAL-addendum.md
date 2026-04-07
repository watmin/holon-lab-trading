# Proposal 008 Addendum: Coupled Messages

## The discovery

Every message in the system should carry its track record.

The observer predicts — the prediction carries the curve's edge.
The exit observer estimates distances — the distances carry the experience.
The broker proposes — the proposal carries the funding level.

This is not a new feature. It's a principle that's already partially
applied. The Proposal carries `funding: f64` — the broker's curve
reading. But `observe-candle` returns `(Vector, Prediction)` without
the observer's `curve-valid`. The coupling is inconsistent.

## The principle

Every message boundary couples data with track record:

```scheme
;; MarketObserver → Post
(observe-candle observer candle-window ctx)
  → (Vector, Prediction, f64)     ; thought, prediction, curve-valid

;; ExitObserver → Post
(recommended-distances exit-obs composed broker-accums)
  → (Distances, f64)              ; distances, experience

;; Broker → Treasury (already coupled via Proposal.funding)
```

The consumer receives both. The consumer is free — gate, weight, sort,
log, ignore. The track record is earned, not claimed. Measured, not
asserted.

## The question

**Q1: Should observe-candle return curve-valid as a third element?**
Currently returns `(Vector, Prediction)`. The curve-valid is on the
observer struct but not in the return value. The post must reach into
the observer to read it.

**Q2: Should recommended-distances return experience as a second element?**
Currently returns `Distances`. The experience is queryable via
`experienced?` but not coupled with the distances.

**Q3: Is this a universal principle?** Should EVERY producer in the
system attach its track record to its output? Or only at boundaries
where the consumer needs it for decisions?

## The meta-journal connection

If every message carries its track record, the meta-journal's input
is already flowing. The trajectory of track records over time IS the
meta-journal's candle stream. No new plumbing — just observation of
what already passes through the boundaries.
