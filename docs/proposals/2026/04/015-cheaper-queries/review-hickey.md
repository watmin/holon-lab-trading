# Review: Proposal 015 — Cheaper Queries
**Reviewer:** Rich Hickey
**Verdict:** B. I was wrong about D.

## What changed

F failed. That is not a minor data point — it was half my position. D+F was
a compound prescription: D bounds cost, F amortizes it. Without F, D pays
full price every candle. A cap of 200 at O(200 * 10000) queried 48 times is
still 96M multiplies per candle. Better than 2000, but not the structural
fix I claimed.

More importantly: the thought manifold data changes my reasoning about D
itself.

## D under high variance

My defense of D rested on one claim: "if a pattern is truly predictive, it
will recur." Cosine 0.50 between consecutive candles says otherwise. The
thought space is not cyclic at the resolution the reckoner operates. A
pattern from candle 50 does not "re-enter the buffer." It enters a region
of thought space that may never be revisited within 200 candles. The FIFO
does not degrade gracefully — it forgets categorically. In a low-variance
manifold, recency approximates relevance. In a high-variance manifold,
recency is arbitrary.

I said an algebraic wound that does not bleed is a scar, not an injury.
Beckman said the FIFO has no algebraic structure. He was right about the
property. I was wrong that it did not matter. It matters because without
algebraic compression, the only lever is N, and N is the wrong axis when
the manifold is wide.

## B under high variance

Beckman's B discretizes the output, not the input. K buckets over
[0.001, 0.10]. Each bucket accumulates a prototype from every observation
that fell in its range — not just recent ones. The prototype compresses
the full history into one vector per bucket. Query is O(K * D), constant
in N, and the prototypes improve with more data rather than forgetting it.

My objection was: who picks K and the boundaries? I called them magic
numbers. That objection stands in principle but weakens in practice. The
scalar range is known. The output is bounded. A uniform partition of a
bounded range is not magic — it is a grid. If the grid is too coarse, the
answer is slightly wrong. If the FIFO is too short, the answer is
categorically wrong. I prefer the failure mode that is slightly wrong.

The bucket boundaries are a parameter. The FIFO cap is also a parameter.
Neither is derived from the data. But the bucket parameter degrades
gracefully (interpolation error) while the FIFO parameter degrades
catastrophically (amnesia). In a high-variance manifold, graceful
degradation wins.

## Verdict

**B now. A remains the target.**

Implement K uniform buckets over the known scalar range. Start with
K=10. Measure whether the interpolation error is acceptable. The
prototypes are monoids — they compose, they compress, they do not forget.

D was defensible when F would mask its cost. Without F, D is a cap on a
brute-force search that forgets. B is a compression that remembers.

I was wrong. The data showed it. That is how it should work.
