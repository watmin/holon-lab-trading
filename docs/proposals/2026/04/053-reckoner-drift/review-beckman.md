# Review: Beckman

Verdict: CONDITIONAL

## The categorical reading

The proposal describes a non-commuting diagram. Let me make it precise.

We have three morphisms in play:

- **encode**: Candle -> V (the thought encoder, deterministic, stable)
- **strip_t**: V -> V (the noise subspace projection at time t, evolving)
- **reckoner**: V -> R (the bucketed interpolation, learned from past observations)

The pipeline at observation time t1 is:

```
candle --encode--> v --strip_t1--> a1 --reckoner.observe(a1, scalar)-->
```

The pipeline at query time t2 is:

```
candle --encode--> v --strip_t2--> a2 --reckoner.query(a2)--> predicted scalar
```

The reckoner's bucket prototypes are accumulated sums of {a1} vectors. The
query presents an {a2} vector. The dot product between a2 and the accumulated
a1's is the mechanism. For this to be meaningful, strip_t1 and strip_t2 must
be "close enough" that the inner product geometry is preserved.

But strip_t is a projection operator that evolves. Specifically, strip_t
computes x - P_t(x) where P_t is the orthogonal projection onto the learned
k-dimensional subspace at time t. As the subspace grows (absorbs more
"normal"), P_t captures more variance, and the residual x - P_t(x) shrinks
and rotates.

The diagram:

```
        strip_t1
V ─────────────────> V_perp(t1)
│                        │
│ id                     │ reckoner.query
│                        │
V        strip_t2        V
V ─────────────────> V_perp(t2) ──── reckoner.query ───> R
```

This does NOT commute. The reckoner was trained on V_perp(t1) but queried
on V_perp(t2). These are different subspaces. The prototypes point in
directions that may be partially or wholly absorbed into the "normal"
subspace by time t2. The dot products between old prototypes and new
residuals are geometrically incoherent.

The decay factor (0.999) applies a scalar contraction to the accumulated
prototypes. Scalar contraction commutes with everything -- it is a natural
transformation on the identity functor. But the problem is not magnitude. The
problem is that the prototypes live in the image of (I - P_t1) while the
queries live in the image of (I - P_t2). These are different complementary
subspaces. No amount of scalar decay can rotate one into the other.

This is the distinction the proposal makes between temporal non-stationarity
and representational non-stationarity. Decay handles the former (a morphism
in the category of scaled vector spaces). It cannot handle the latter (which
requires a morphism between different subspace decompositions -- a different
category entirely).

## Answers to the five questions

### 1. Is the noise subspace the cause?

Yes, almost certainly, and the categorical argument is sufficient to predict
it without running the ablation. But run it anyway, because sufficiency of
the argument does not preclude other contributing factors.

The strip operator is a time-dependent projection. The reckoner accumulates
in the codomain of that projection. When the projection evolves, the codomain
shifts. The accumulated prototypes are stranded in a codomain that no longer
exists. This is not a subtle effect -- it is a change of basis without a
corresponding change-of-basis transformation on the stored data.

The 91% initial error and 722% final error are consistent with this
mechanism. The initial error is high because the subspace is young and
strip_t1 is a poor projection (high residual, low information removed). As
the subspace matures, strip_t removes more "normal" variance, the residuals
shrink and rotate, and the old prototypes become orthogonal to the new
residuals. The dot products approach zero. The interpolation degenerates.

### 2. Should the reckoner see the raw thought instead of the anomaly?

Yes. This is the categorical fix: remove the non-commuting morphism from the
diagram.

If the reckoner operates on V directly (the output of encode, before strip),
the diagram becomes:

```
candle --encode--> v --reckoner.query(v)--> predicted scalar
```

The encode morphism is deterministic and time-invariant. The same candle
produces the same thought vector at any time. The reckoner's prototypes and
query vectors live in the same space V forever. The diagram commutes trivially
because there is no time-dependent morphism in the pipeline.

This is not merely "simpler." It is categorically sound. The encode functor
maps from the category of market events to the category of vectors. The
reckoner is an interpolation morphism within the category of vectors. Both
are well-defined. Composing them produces a well-defined morphism from market
events to scalars. Inserting strip_t breaks the composition because strip_t
is not a single morphism -- it is a natural transformation between functors
that changes over time. You cannot compose with something that is not yet
determined.

There is a deeper point here. The noise subspace serves a specific algebraic
purpose: it projects out the common mode so that the residual carries
discriminative signal. This is exactly right for classification (the discrete
reckoner), where the question is "which side of a boundary?" The common mode
is noise for that question. But for regression (the continuous reckoner), the
question is "where in the space?" The common mode carries information about
WHERE. Projecting it out discards exactly the structural information the
continuous reckoner needs.

### 3. Can the reckoner realign?

In principle, yes. The mathematical fix is a change-of-basis operator: when
the subspace evolves from P_t1 to P_t2, transform the stored prototypes via
(I - P_t2)(I - P_t1)^+ applied to each prototype, where ^+ denotes the
pseudoinverse. This "re-projects" old prototypes into the new complementary
subspace.

In practice, this is expensive and fragile. The pseudoinverse of a projection
is well-defined but numerically sensitive. And you would need to apply it to
every bucket prototype at every subspace update, which couples the subspace
update cost to the reckoner state size.

The engram approach is a discrete approximation of this: freeze P_t at
snapshot time, score against the frozen P, and periodically reset. This
avoids the continuous change-of-basis computation but introduces a
discontinuity at each snapshot boundary. The reckoner's prototypes are
coherent within each epoch but incoherent across epochs.

Both approaches are solving a problem that does not need to exist. If the
reckoner sees the raw thought, there is no change of basis to track.

### 4. Is this a fundamental tension between stripping and learning?

Yes. This is a coherence condition failure.

In category theory, when you have a diagram of functors, you need natural
transformations between them to make the diagram commute. The noise subspace
defines a family of projection operators {P_t} indexed by time. The reckoner
defines an interpolation morphism trained on the images of past projections.
For the composition to be coherent, you need a natural transformation that
relates (I - P_t1) to (I - P_t2) in a way that preserves the inner product
structure the reckoner depends on.

No such natural transformation exists in general. The subspaces P_t1 and P_t2
can have arbitrary relative orientation (within the constraints of CCIPCA's
incremental updates). The only coherence condition that holds automatically is
when the subspace is FROZEN (P_t = P_t0 for all t > t0), which is exactly
the engram solution.

So the tension resolves into a trichotomy:

1. **Remove the projection** (reckoner sees raw V). No coherence needed.
2. **Freeze the projection** (engrams). Trivial coherence within each epoch.
3. **Track the change of basis** (continuous realignment). Expensive, fragile.

Option 1 is the zero-cost solution. Option 2 is the engineering solution.
Option 3 is the mathematical solution that nobody should implement.

### 5. Does the market observer have the same problem?

The mechanism exists for the market observer, but the severity is different.

The discrete reckoner computes discriminants as differences of prototypes
(prototype_A - prototype_B after normalization). The prediction takes the
cosine of the query against the discriminant. This is a binary classification:
which side of a hyperplane does the query fall on?

When the subspace evolves, the discriminant hyperplane rotates. But
classification is robust to small rotations of the decision boundary --
points far from the boundary are still classified correctly. Only points
near the boundary (low conviction predictions) are affected.

The continuous reckoner, by contrast, uses the actual dot product magnitudes
for interpolation. Every query is affected by the rotation, not just
boundary cases. The degradation is proportional to the total rotation of the
complementary subspace, which grows monotonically as the subspace absorbs
more variance.

So: the market observer's accuracy should degrade more slowly and may plateau
as the subspace stabilizes. The position observer's error should grow
monotonically. The data in the proposal (722% error growth vs presumably
stable market accuracy) is consistent with this prediction.

Measure it. The recalib_wins/recalib_total time series for the market observer
will either confirm or refute this.

## The algebraic recommendation

The composition `reckoner . strip_t . encode` is ill-defined because strip_t
is not a fixed morphism. Replace it with `reckoner . encode`, which is
well-defined, time-invariant, and composes cleanly.

Keep `strip_t . encode` for the discrete market observer, where the
projection serves its intended algebraic purpose (extracting discriminative
signal for classification). The coherence failure is mild for classification
and the discriminative benefit justifies the cost.

Do not reach for engrams or change-of-basis operators to fix a problem that
dissolves when you remove the offending morphism. The simplest diagram that
commutes is the correct one.

The condition: run the ablation to confirm the mechanism empirically. The
categorical argument predicts the outcome, but physics taught me to distrust
arguments that have not been tested. If the ablation confirms, remove
strip from the continuous reckoner pipeline. If it does not confirm, there is
a second non-commutativity hiding somewhere, and I want to see the data
before speculating about where.
