# Review: Proposal 015 — Cheaper Queries
**Reviewer:** Brian Beckman
**Verdict:** B, without F. Hickey's objection to bucket boundaries deserves a stronger answer now.

## F is gone. Good.

F assumed Lipschitz continuity of the thought stream. Cosine 0.50 between consecutive candles means the stream is nowhere near continuous in the relevant topology. The gating threshold I proposed deriving from B's resolution is moot — there is no stability regime to exploit. F was not wrong algebraically. It was wrong empirically. I accept this.

## Does B survive the high-variance manifold?

Yes, but the argument shifts. My original defense of B rested on the codomain partition being a cover with well-defined fibers. That structure is invariant to input variance — the buckets partition the *output* space [0.001, 0.10], not the input thought-space. Whether consecutive thoughts have cosine 0.99 or 0.10, each observation still lands in exactly one bucket and bundles into its prototype. The monoid structure is untouched.

What changes: the prototypes in each bucket will be broader. High input variance means the preimage fibers are fat — many structurally different thoughts map to similar scalar outputs. Each bucket's prototype is the superposition of a diverse set. This is fine. The prototype already tolerates diversity; that is the point of bundling. The query asks "which bucket's prototype am I nearest?" not "am I identical to the prototype?" Cosine similarity degrades gracefully with prototype breadth. The discrete reckoner already handles this — its Up and Down prototypes absorb enormous thought diversity. B inherits the same tolerance.

## Does Hickey's D look different now?

Worse, not better. High variance means the last 100-200 observations are not a representative sample of the manifold — they are a random walk through it. A FIFO trained on a trending regime evicts its ranging experience just when the market reverts. The high variance *is* the argument against recency as a proxy for relevance. D's implicit forgetting policy — evict the oldest — is maximally uncorrelated with what actually changed.

B's decay-weighted prototypes forget by magnitude attenuation across all buckets simultaneously. When the market shifts, new observations reinforce the relevant buckets while stale buckets fade. The forgetting is *structural*, aligned with the codomain, not temporal.

## Hickey's objection reconsidered

He is right that K is a parameter. I was too dismissive. Let me be honest: K = ceil(range / precision) is derived, but *precision* is chosen. The choice of 1bp resolution is a design decision. It is a better-grounded decision than a FIFO cap — it has an error bound, a convergence rate, and a compositional story — but it is still a decision. I will not pretend otherwise.

The remedy: start with K=10, measure interpolation error against the brute-force ground truth at candle 2000, and adjust once. This is calibration, not tuning. One measurement, one adjustment, then fixed.

## Verdict

**B. Without F.** Every candle pays O(K * D). No amortization, no gating, no cleverness. K=10, soft-weighted top-3 interpolation, decay on the prototypes. One parameter (precision), derived from the domain, calibrated once. The high-variance manifold does not weaken B — it strengthens the case against D.

Do E as well. It is free.
