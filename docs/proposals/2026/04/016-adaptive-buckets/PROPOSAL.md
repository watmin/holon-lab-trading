# Proposal 016 — Adaptive Buckets

**Date:** 2026-04-11
**Author:** watmin + machine
**Status:** PROPOSED
**Follows:** Proposal 015 (B accepted, K=10 measured)

## Context

Proposal 015 accepted B with K=10. The experiment proved K=10 is the
knee of the error curve at N=2000 observations. 130× speedup over
brute-force. 0.97% mean error. The designers agreed.

Then the datamancer asked three questions:

1. "The kernel doesn't know the domain. K must be parameterized."
2. "The application doesn't know the range upfront. It experiences
   the market in real time. How does range evolve?"
3. "How does bucket count evolve?"

The answer to all three: the reckoner discovers its own structure
from the data. No K. No range. One parameter: the default value
(the crutch). Everything else emerges.

## The experiment

An adaptive reckoner starts with K=1. When a bucket has enough
observations AND the value variance within it exceeds 25% of its
width, it splits. K grows from experience. The range grows from
observed min/max.

Tested against brute-force ground truth (N=2000, D=10000, 100 queries):

```
min_split     K    mean_err    μs/query
       10   269    0.01235     32237     too many, over-split
       50    48    0.01071      5465     reasonable
      100    26    0.01144      2978     near theoretical optimal
      150    17    0.01064      1970     sweet spot
      200    14    0.01322      1644     too few, error rises
```

For comparison, fixed K=10: mean_err=0.00973, μs/query=970.

K evolution with min_split=50:
```
N=   50  K=1     ignorant
N=  100  K=1     still one bucket
N=  500  K=1     hasn't split yet
N= 1000  K=25    burst of splits as variance builds
N= 2000  K=48    still growing
```

## What this shows

1. The data CAN discover its own bucket structure. No range parameter.
   No K parameter. The range grew from observations. K grew from splits.

2. At min_split=150, the adaptive reckoner arrived at K=17 with
   mean_err=0.01064 — competitive with fixed K=10 (0.00973). The
   error difference is 0.09 percentage points. The adaptive reckoner
   discovered its resolution from the data.

3. The adaptive K doesn't stabilize — it keeps splitting as more data
   arrives. At N=2000 with min_split=50, K=48. This is too many. The
   split threshold controls the growth rate.

4. Cost: 2ms vs 1ms per query. The difference is 1 millisecond. Over
   48 queries per candle, that's 48ms vs 24ms. Both are under the
   per-candle budget. Both are 100× better than brute-force (187ms).

## The proposal

Replace `ReckConfig::Continuous` with:

```rust
ReckConfig::Continuous {
    default_value: f64,
    // no K — starts at 1, grows from experience
    // no range — discovered from observations
    // one tuning lever: how readily to split
}
```

The reckoner:
- Starts with K=1. One bucket. The crutch.
- Range grows from observed min/max.
- Splits a bucket when its observation count exceeds a threshold AND
  the value variance within it is high relative to its width.
- Each bucket is an Accumulator — the same monoid as discrete mode.
- Query: cosine against K prototypes, soft-weight top-3, interpolate.

The split threshold could be:
- A fixed count (e.g., 150 observations per bucket before split eligible)
- Derived from target error (split when interpolation error > budget)
- Derived from K itself (split less readily as K grows — diminishing returns)

## Questions for the designers

1. The adaptive reckoner has one implicit parameter: the split threshold.
   Is this simpler or more complex than fixed K + range?

2. K doesn't stabilize. Should there be a cap? Or should the reckoner
   grow forever and the CSP scheduling handle the cost?

3. The adaptive error (0.01064) is slightly worse than fixed K=10
   (0.00973). The fixed version knows the range upfront — the adaptive
   version discovers it. Is the 0.09% error increase acceptable for
   eliminating two parameters (K and range)?

4. The discrete reckoner has fixed K=2 (Up/Down) forever. The continuous
   reckoner would have growing K. Is this asymmetry a problem? Or is it
   the natural difference between categorical and continuous output?
