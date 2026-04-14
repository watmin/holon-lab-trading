# Mini-Review: Beckman — Cosine vs Dot Product in Continuous Reckoner

## The question

The `query()` function scores buckets against the query thought. Should it
use cosine similarity (direction only) or the raw dot product (direction
times mass)?

## The data

```
                            Predicted Trail    Optimal ~0.5-1%
Anomaly + dot product:         4.2%           10x inflation
Raw thought + dot product:     4.2%           10x inflation
Raw thought + cosine:          55.9%          100x — catastrophic
```

Cosine is ten times worse. The question is: why?

## The algebra

Each bucket accumulates weighted thought vectors. The prototype is
S_j = sum_i w_i v_i where w_i are decayed weights and v_i are observed
thoughts. The decay factor is 0.999 per observation across ALL buckets.

The raw dot product of the query q against bucket j is:

    dot(S_j, q) = sum_i w_i dot(v_i, q)

This is a weighted sum of individual similarities. The weights are the
decayed observation masses. A bucket that has seen 500 recent observations
has more mass than a bucket that has seen 50. This is correct behavior.
The mass IS the evidence. A bucket with 500 confirming observations should
dominate a bucket with 50.

Cosine normalizes away the mass:

    cos(S_j, q) = dot(S_j, q) / (||S_j|| ||q||)

Now the bucket with 50 observations competes equally with the bucket with
500. The only surviving signal is directional agreement. But in high
dimensions, random superposition of 50 thoughts and 500 thoughts both
produce prototypes that point roughly toward the centroid of their
constituent thoughts. The directional difference between buckets is small.
The interpolation weights become nearly uniform. The prediction collapses
toward the mean of the top-3 centers.

Except it does not collapse toward the mean. It collapses toward the mean
of the top-3 SCORED centers. Which centers are top-3 depends on which
bucket prototypes happen to align best with the query. With cosine, this
alignment is noisy — small directional differences amplified to selection
criteria. The result is unstable interpolation over an arbitrary subset of
buckets. Hence 55.9%.

## The mass-as-evidence principle

The raw dot product implements a form of Bayesian weighting. The mass of
a bucket is proportional to the total decayed weight of observations that
fell into it. This is a frequency estimate. Buckets in the dense part of
the distribution have high mass. Buckets in the tails have low mass. The
dot product naturally shrinks the influence of tail buckets. This is
regularization by evidence count. Cosine destroys it.

## The unbounded growth concern

The question notes that mass grows without bound. The decay is 0.999 per
observation with effective window ~1000. But if a bucket receives a steady
stream of observations, the mass converges to approximately N * w_avg /
(1 - 0.999) = 1000 * w_avg in steady state. This is bounded. The
geometric series converges. The concern about unbounded growth is a
transient — the mass overshoots during warm-up and settles.

If the mass does NOT settle — if the effective input rate to a bucket
exceeds what the decay can absorb — the bucket is receiving a
disproportionate share of observations. Its high mass correctly reflects
this. The dot product correctly weights it heavily. This is not a bug.

## The interpolation scheme

The scheme is: score all buckets, take top-3 by score, compute
sum(score_i * center_i) / sum(score_i).

With dot product scores, this is a mass-weighted interpolation of the
three most relevant centers. The mass acts as both a relevance filter
(high-mass buckets score higher) and a weighting function (high-mass
buckets contribute more to the result). This double role is the one
weakness — it biases toward high-density regions of the distribution.
But for a trailing stop distance, the mode of the distribution is a
reasonable prediction. The bias is defensible.

With cosine scores, the interpolation is direction-weighted only. The
three selected buckets are those whose prototype directions happen to
align with the query. Their weights are cosine similarities, which
cluster near each other in high dimensions (the concentration of measure
phenomenon). The interpolation becomes near-uniform over a noisy subset.
This is the mechanism behind 55.9%.

## The verdict

**Use the raw dot product.** It is not merely the empirically better
choice. It is the algebraically correct one.

The dot product preserves the monoid structure of accumulation. Each
`add_weighted` appends to a free commutative monoid over weighted vectors.
The dot product with a query is a monoid homomorphism into the reals —
it distributes over the sum. Cosine normalization is NOT a homomorphism.
It is a nonlinear transformation that breaks the compositional structure
the accumulator was designed to preserve.

The 10x inflation (4.2% vs optimal 0.5-1%) is a separate problem. It
lives in the bucket centers, the range dynamics, or the interpolation
scheme — not in the similarity metric. The dot product is doing its job.
The question is whether K=10 buckets with top-3 interpolation can resolve
a scalar that needs to be 0.5-1%. That is Proposal 053's deeper question,
and it remains open.

Do not normalize. The mass is the message.
