# Proposal 013 — The Continuous Reckoner Has No Compression

**Date:** 2026-04-11
**Author:** watmin + machine
**Status:** PROPOSED

## The problem

The N×M grid degrades from 674μs to 187,673μs across 500→2000 candles.
315× slowdown. Throughput drops from 173/s to 10/s. The grid consumes 92%
of every candle by candle 1500.

The cause: the continuous reckoner's `query()` is brute-force nearest-
neighbor regression. It stores every observation as a full `Vec<f64>`
(10,000 elements = 80KB) and scans ALL of them on every query. O(N × D)
where N = observation count, D = dimensionality. N grows with every
paper resolution. At candle 2000, each query does ~2000 cosine
computations over 10,000 dimensions. With 96 query calls per candle
(24 grid slots × 2 reckoners × 2 call sites), that's ~192,000 cosine
computations per candle.

## The deviation

The discrete reckoner does NOT have this problem. It ACCUMULATES into
prototypes — one per label. `predict()` is O(labels × D) — two cosines
for Up/Down, regardless of how many observations it has seen. 10
observations or 10,000 — same cost. The observations are compressed
into the prototypes. The prototypes ARE the memory.

The continuous reckoner stores raw observations. `query()` scans them
all. The more it learns, the slower it gets. The doc says "Same
accumulation mechanism. Same decay. Same recalibration." This is not
true. The discrete mode uses `Accumulator`. The continuous mode uses
`Vec<ContinuousObs>`. They are not the same mechanism.

## What each reckoner answers

**Discrete:** "Given this thought, which LABEL?" Binary. The compression
into prototypes IS the answer. The discriminant is a direction in vector
space. The cosine against it gives conviction. O(1) per query.

**Continuous:** "Given this thought, what SCALAR?" Context-dependent.
The answer for momentum×volatility at 0.73 RSI is different from the
answer for regime×timing at 0.12 entropy. The continuous reckoner is
trying to be contextual — "for THIS specific composed thought, what
trail distance?" The context-sensitivity is why it stores raw
observations. It's doing lazy evaluation because it doesn't know how
to compress context-dependent scalar regression into a fixed-size
representation.

## The grid

The enterprise has N=6 market observers × M=4 exit observers = 24 brokers.
Each broker composes a unique thought (market lens × exit lens). Each
broker asks each of 2 continuous reckoners (trail, stop): "for my composed
thought, what distance?" These are 24 genuinely different questions — each
composed thought is different because each market lens sees different
things and each exit lens judges differently.

Additionally, step 3c (update triggers) re-asks the same questions for
all active trades on the same candle. This is redundant — the distances
were already computed in the grid — but it is a secondary issue.

## The question for the designers

The discrete reckoner found its compression: prototypes + discriminant.
The continuous reckoner has not. It uses brute-force as a placeholder.

Options:

**A. Accumulator-based compression (holon-rs change).** The continuous
reckoner accumulates like the discrete does. Instead of storing raw
observations, it maintains a weighted prototype that represents "the
direction in thought-space that correlates with high scalar values."
The query becomes a cosine against this prototype — O(D), constant.
The contextual information is captured in the prototype's direction,
not in raw observations.

The challenge: the discrete reckoner separates N classes with N
prototypes. The continuous reckoner maps a continuous input to a
continuous output. A single prototype loses the ability to predict
DIFFERENT values for different contexts. "Momentum at RSI 0.73"
might need trail=0.015 while "regime at entropy 0.12" needs
trail=0.025. One prototype collapses them.

**B. Bucketed accumulators (holon-rs change).** Discretize the
scalar output range into K buckets. Each bucket has a prototype
(the mean thought that produced values in that range). Query:
cosine against each bucket's prototype, select the bucket with
highest similarity, return its centroid value. O(K × D) per query,
constant in observations. K might be 10-20. Loses precision below
bucket width.

**C. Subspace regression (holon-rs change).** Use OnlineSubspace
(CCIPCA) to learn the principal components of the observation
manifold. Store scalar values as projections. Query: project the
input, interpolate. O(k × D) where k = number of components (8-16).
Constant in observations. Preserves contextual variation along the
principal directions. This is the most algebraically honest approach
but the most complex.

**D. Capped observations with recency (holon-rs change).** Keep the
brute-force approach but cap at a small N (e.g., 100-200 most recent
or most weighted). Evict oldest. The quality degrades gradually as
old context is lost, but the cost is bounded. The simplest change.
The least algebraically satisfying.

**E. Cache the grid's distances (trading-lab change).** Don't fix the
reckoner. Cache the 24 distance results from the grid per candle.
Step 3c reuses them instead of re-querying. Cuts query count roughly
in half when trades are active. Doesn't fix the fundamental scaling —
the grid itself still grows.

**F. Amortize queries via CSP (trading-lab change).** The exit
reckoner doesn't need to answer every candle. If the composed thought
hasn't changed enough since the last query (cosine > 0.99), reuse the
previous answer. Each broker caches its last query result and the
thought that produced it. Only re-query when the thought shifts
meaningfully. The cost becomes O(D) per candle (one cosine to check
similarity) instead of O(N × D) (full query).

## The measurements

From the diagnostics DB (runs/10k-laziness.db):

```
candle  throughput  us_grid     grid%
  100   173/s         596       12%
  500    64/s      26,547       64%
 1000    24/s      75,065       83%
 1500    15/s     129,584       91%
 2000    11/s     187,673       92%
```

The grid is 92% of every candle at 2000 candles. The reckoner query
inside the grid is the entirety of the cost. Everything else is flat.

## What we want

Constant-time queries. The discrete reckoner achieves this. The
continuous reckoner must achieve this or something close. The machine
that learns should get FASTER as it gets smarter, not slower. The
architecture of CSP gives each consumer the freedom to be lazy — but
the reckoner's fundamental query cost must not grow linearly with
experience.

The fix may be in holon-rs (change the reckoner), in the trading lab
(change how we use it), or both. The designers should evaluate.
