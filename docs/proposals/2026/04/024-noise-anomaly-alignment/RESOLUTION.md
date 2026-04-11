# Resolution: Proposal 024 — Noise-Anomaly Alignment

**Date:** 2026-04-11
**Decision:** ACCEPTED — implement

## Designers

Both accepted. Hickey: the mismatch is a categorical error, the
anomaly is a fact about what was perceived. Beckman: the current
code has a type error, the fix closes the diagram. Apply to broker
too.

## The changes

1. **Market observer observe()** — re-enable noise stripping.
   Return the ANOMALY alongside the prediction. The anomaly is
   what the reckoner predicted on.

2. **PaperEntry** — gains `prediction_thought: Vector`. This is the
   anomaly from prediction time. Stored at paper registration.
   The market observer's reckoner will learn from this vector.

3. **Broker register_paper()** — accepts the anomaly and stores it
   as `prediction_thought` on the paper.

4. **Broker propose()** — re-enable noise stripping on composed
   thought. The broker's reckoner predicts on the broker's anomaly.
   Store as a separate field for the broker's own learning.

5. **Broker propagation** — market signals carry `prediction_thought`
   (the anomaly) not the original thought. The market observer
   learns from what it actually saw.

6. **Binary** — the market observer thread returns the anomaly. The
   grid passes the anomaly to register_paper. The propagation
   routes the anomaly to market learn channels.

7. **RunnerHistory** — stores the anomaly per candle (for deferred
   batch training). The exit observer learns from the composed
   anomaly at each candle of the runner's life.
