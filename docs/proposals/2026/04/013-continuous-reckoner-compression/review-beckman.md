# Review: Proposal 013
**Reviewer:** Brian Beckman
**Verdict:** CONDITIONAL — Accept B+F, reject A and D, defer C, accept E as trivial housekeeping

## The algebraic situation

The discrete reckoner's accumulators form a commutative monoid: (prototype, bundle, zero-vector). Observation order doesn't matter. The prototype IS the compression — it's the homomorphic image of the observation stream under bundling. This is why it's O(1) at query time: you already hold the answer.

The continuous reckoner has no such homomorphism. It stores the raw stream and computes at query time. This is a fundamental category error: it confuses a *lazy computation* with a *value*. In algebraic terms, the discrete reckoner applies the fold eagerly; the continuous reckoner defers it to query time and pays O(N) each time.

The question is: does a suitable monoid exist for the continuous case?

## Option-by-option

**A. Single prototype. REJECT.** A single accumulated prototype maps the entire observation manifold to one direction. This is a monoid homomorphism from (observations, bundle, zero) to a single vector — but it destroys the fiber structure. The continuous reckoner answers a *family* of questions indexed by thought-context. Collapsing to one prototype is like taking the colimit of a diagram and then asking which object you came from. The information is gone. The diagram does not commute with recovery.

**B. Bucketed accumulators. ACCEPT.** This is the right idea. You discretize the codomain into K bins and maintain K prototypes — each one a commutative monoid under bundling, exactly like the discrete reckoner. Query is a K-way cosine vote followed by interpolation. The key insight: each bucket's accumulator inherits the same algebraic properties the discrete case enjoys. The functor from (continuous observations) to (K discrete accumulators) is well-defined: each observation maps to its bucket, the bucket bundles it. The interpolation at query time is a convex combination — it preserves the bounded range. O(K*D) is constant in N. K=10-20 is fine. This composes.

**C. Subspace regression. DEFER.** Algebraically elegant — CCIPCA learns a linear subspace, and projection onto it is an idempotent endomorphism (a retract). The observations form a module over the reals, and the subspace is a direct summand. Beautiful. But: it introduces a dependency on eigenvalue convergence, warm-up transients, and hyperparameter sensitivity (number of components, learning rate). The algebra is clean; the engineering is not. Defer until B proves insufficient.

**D. Capped observations. REJECT.** A bounded FIFO is not a monoid — it has no associative composition. Eviction is order-dependent. Merging two capped buffers gives a different result depending on interleaving. You lose the ability to reason algebraically about what the reckoner "knows." It's an engineering band-aid on an algebraic wound. The proposal itself calls this "least algebraically satisfying." Correct.

**E. Cache grid distances. ACCEPT (trivially).** This is not an algebraic change — it's memoization, which is always valid when the function is pure over a candle. It halves the constant factor. Do it regardless of everything else. It doesn't address the growth problem but it's free money.

**F. Amortize via similarity gating. ACCEPT.** This is a coalgebraic observation: if the input hasn't moved (cosine > threshold), the output hasn't moved. This is Lipschitz continuity of the query function — small input perturbation, small output perturbation. The cosine check is O(D), constant. This composes with any choice of reckoner internals because it operates at the call site, not inside the algebra. It's an orthogonal optimization. Do it.

## The composition

B gives the reckoner a proper algebraic backbone — K commutative monoids, one per bucket. F gives the caller the right to be lazy. E removes redundant computation. Together: O(K*D) worst case, amortized to O(D) when thoughts are stable. The 315x slowdown becomes bounded and eventually amortized to near-zero.

The natural transformation from the current brute-force to B is: partition existing observations into K buckets, bundle each bucket into its prototype, discard the raw observations. This is a one-time migration, not a rewrite. The query interface doesn't change — it still takes a vector and returns a scalar.

Conditions: B must preserve the weighted interpolation between adjacent buckets. A hard argmax over buckets would introduce discontinuities. Use soft weighting (cosine-proportional contribution from top-2 or top-3 buckets) to maintain smoothness.
