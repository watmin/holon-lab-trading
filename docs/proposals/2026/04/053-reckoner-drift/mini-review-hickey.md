# Mini-Review: Hickey — Cosine vs Dot Product in Continuous Reckoner

## The question is wrong.

You're asking: "which similarity function?" But neither works. One inflates 10x, the other 100x. When two implementations of the same idea both fail, the idea is wrong. Stop tuning the similarity function. Look at the interpolation.

## What's actually happening

The continuous reckoner does this:

1. Accumulate thoughts into K=10 buckets by scalar range.
2. At query time, find which bucket prototypes the query thought resembles.
3. Interpolate the bucket *centers* weighted by similarity.

The output is a weighted average of bucket centers. The bucket centers span the observed range. The weights come from similarity — cosine or dot, doesn't matter.

Here's the problem: **the interpolation is unconstrained.** The weights are similarities, not probabilities. They don't sum to one in any meaningful way. The top-3 soft-weighting is an ad hoc mechanism pretending to be a proper mixture model. It isn't one.

But that's not even the real problem.

## The real problem: prototypes converge

You have 10 buckets. You're accumulating 10,000 thoughts into them. Each bucket is a superposition of hundreds or thousands of high-dimensional vectors. As count grows, the prototypes converge toward the global mean of the thought distribution. This is the central limit theorem applied to vector spaces.

When all 10 bucket prototypes point roughly the same direction, the cosine similarity between the query and each bucket is roughly the same. The interpolation degenerates into an unweighted average of the centers — which is approximately the midpoint of your range.

Except: with raw dot product, the norms differ. A bucket with 5,000 observations has 10x the norm of one with 500. The dot product is `cos(theta) * ||a|| * ||b||`. When cosines converge, the norm dominates. Mass selects the bucket. This is why dot product "works better" — it's not measuring thought similarity anymore, it's measuring *where most observations landed*. That's a frequency histogram with extra steps.

Cosine strips the mass, leaving only the converged directions. Everything looks the same. The interpolation wanders.

## The diagnosis

The bucketed accumulator conflates two things:

1. **What thoughts look like** at a given scalar value (direction)
2. **How many thoughts** fell in that scalar range (mass)

The accumulator stores both in one object. Cosine reads (1). Dot product reads (1) * (2). Neither reads what you actually want: "given this specific thought, what scalar did thoughts like it produce?"

This is a regression problem. You've built a histogram and bolted similarity onto it. The histogram part works — it tracks the range. The similarity part doesn't — the prototypes don't carry discriminative information after thousands of observations.

## What to do

The discrete reckoner works because it has 2-3 labels. Each prototype accumulates a *different population*. The prototypes stay separated because the populations are different. The discriminant (prototype_A - mean) amplifies the difference.

The continuous reckoner has 10 buckets over a smooth range. Adjacent buckets see *almost the same thoughts*. There is no natural separation. The prototypes converge.

Two options:

**Option A: Discriminants for continuous mode.** Compute a mean prototype across all buckets. For each bucket, subtract the mean. Now you have a direction that says "what's different about thoughts in THIS range." This is what discrete mode does. It works there. It should work here.

**Option B: Don't interpolate prototypes. Interpolate observations.** Keep the scalar in each bucket. At query time, don't use the accumulated prototype. Use the *most recent* N observations per bucket — a small ring buffer. Cosine against actual individual thoughts, not their superposition. This preserves discriminative power at the cost of O(N*K) query time instead of O(K).

Option A is simpler. It's the same mechanism that already works. Start there.

## The principle

When you have two implementations of an idea and both fail in the same direction (inflation), the abstraction is wrong. You don't fix it by choosing between two bad options. You look at the assumptions. The assumption here was that accumulated prototypes carry discriminative signal across adjacent scalar ranges. They don't. The discrete reckoner knew this — that's why it has discriminants.

Bring the discriminant to continuous mode. The primitive already exists.
