# Resolution: Proposal 015 — Cheaper Queries

**Date:** 2026-04-11
**Decision:** ACCEPTED — B with K=10. Measured.

## The designers

**Hickey (ACCEPTED — reversed from D):** "D's defense rested on 'patterns
recur.' Cosine 0.50 between consecutive candles says otherwise. Without F
to amortize, D is a cap on a brute-force search that forgets. B is a
compression that remembers. I was wrong. The data showed it."

**Beckman (ACCEPTED):** "The bucket partition operates on the codomain —
input variance is irrelevant to the algebraic structure. The high-variance
manifold makes D worse, not better. Precision is a chosen parameter, but
one with an error bound and convergence guarantee."

Both accept B. Unanimous. First time across three proposals.

## The experiment

Bucket sweep: K=2 through K=30, against brute-force ground truth.
N=2000 observations, D=10000, 100 test queries.

```
  K   mean_err    max_err    speedup
  8   0.01338     0.0372      133x
  9   0.01187     0.0338      116x
 10   0.00973     0.0287      130x   <-- sweet spot
 11   0.00982     0.0258      118x
 12   0.01055     0.0294      104x
 20   0.00942     0.0309       66x
 50   0.01040     0.0277       26x
```

K=10 is the knee of the curve. Mean error drops sharply at 10, then
floors at ~0.010 regardless of K. More buckets don't help — sparsity
defeats precision. K=10 at 130× speedup. K=20 at 66× for 0.03% less
error. Not worth it.

The theoretical optimal K = (4N)^(1/3) = 20. The measured optimal is
10 — the theory overestimates because it assumes uniform distribution.
Real observations cluster.

## The error budget

Mean error: 0.97% of the distance range. On a trail distance of 0.02
(2%), the bucketed answer differs from brute-force by ~0.0001 (0.01%).
The price impact: on a $100,000 BTC position, that's $10 difference
in stop placement. The enterprise makes 24 of these decisions per
candle. The 130× speedup converts 187ms of grid time back to ~1.5ms.

## What to implement

1. **BucketedReckoner in holon-rs** — K uniform buckets over [min, max].
   Each bucket holds an Accumulator (same primitive as discrete mode).
   observe_scalar: find bucket, bundle into its accumulator.
   query: cosine against K prototypes, soft-weight top-3, interpolate.
   O(K × D) per query. Constant in observations.

2. **Replace Continuous mode** — the brute-force Vec<ContinuousObs> is
   replaced by K Accumulators. The query() interface doesn't change.
   The observe_scalar() interface doesn't change. Internal only.

3. **E: Cache grid distances for step 3c** — the grid already computes
   distances for all 24 slots. Step 3c re-queries the same reckoners
   with the same composed thoughts. Cache and reuse. Free.

## The chain

```
013: diagnosis     → brute-force KNN is O(N×D), 315× slowdown
014: debate        → D vs B, F unanimous
014: F measured    → F failed, zero gate hits, thoughts shift 50%/candle
015: debate        → Hickey reverses, both accept B
015: K measured    → K=10, 130× speedup, 0.97% error, the knee of the curve
```

Three proposals. Two debates. One reversal. One experiment. The
measurement decided. K=10.
