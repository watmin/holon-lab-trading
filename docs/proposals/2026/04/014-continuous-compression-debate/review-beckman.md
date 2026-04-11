# Review: Proposal 014 — The Compression Debate
**Reviewer:** Brian Beckman
**Verdict:** B+F. Bucket boundaries are not magic — they are the image of a functor.

## Response to Hickey's objection to B

Hickey says bucket boundaries are "a new parameter that encodes assumptions
about the scalar distribution." Let me be precise about what is happening
algebraically.

The continuous reckoner maps from thought-space T to a scalar interval
[a, b]. A partition of [a, b] into K subintervals is not a parameter in
the sense Hickey means. It is a *cover* of the codomain. The prototypes
in each bucket are the preimages of that cover under the regression — they
are the fibers. This is not discretization policy braided with regression.
It is the regression *expressed as a sheaf over the codomain*.

The bucket count K is not a tuning knob. It is the resolution of your
approximation to a continuous function by a step function. The convergence
theorem is classical: as K grows, the step function converges uniformly to
the original. K=10 with soft-weighted interpolation over top-2-3 neighbors
gives you piecewise-linear approximation, which converges at O(1/K). You
do not tune K. You choose it once from the desired precision (bucket width
= (b-a)/K) and the cost budget (K cosines per query). The domain [0.001,
0.10] with K=10 gives 1bp resolution. That is not magic. That is arithmetic.

Compare this to D's cap of 100-200. *That* is a magic number. It encodes an
assumption about how many recent observations are "enough" — with no
convergence guarantee, no error bound, and no algebraic justification.
Hickey's objection to B applies more forcefully to D.

## Response to Hickey's defense of D

Hickey says a capped buffer "says exactly what it is" and does not need
algebraic structure. I disagree on a point of engineering, not aesthetics.

A FIFO buffer with eviction is a lossy compression whose loss function is
*implicit*. You cannot characterize what information was destroyed. You
cannot merge two buffers. You cannot reason about what happens when two
reckoners that saw different market regimes combine their experience. The
buffer is a dead end — it compresses, but the compression has no inverse,
no adjoint, no functorial relationship to the original data.

The bucketed accumulator has all of these. Two reckoners trained on
different periods? Bundle their bucket prototypes pairwise. The merge
is associative, commutative, and semantically meaningful — it is the
coproduct in the category of bucketed reckoners. D has no such operation.

"Simple" and "composable" are not in tension. B is both.

## Question 1 (Hickey to me): Are bucket boundaries magic numbers?

No. The boundaries are determined by three quantities that are already
known: the minimum scalar value (from domain constraints), the maximum
scalar value (same), and the desired precision. Given min, max, and
precision, K = ceil((max - min) / precision). This is not a degree of
freedom. It is a consequence.

## Question 2 (me to Hickey): Is recency a valid proxy for relevance?

This is the question I most want Hickey to answer honestly. Recency is
a heuristic for stationarity. If the process is stationary, old and new
observations are equally informative and evicting old ones is pure waste.
If the process is non-stationary, you want to forget — but you want to
forget *what changed*, not *what is old*. A FIFO forgets by timestamp.
The bucketed accumulator with decay forgets by magnitude — the prototype
in each bucket decays toward zero, so stale structure fades while fresh
structure reinforces. Decay is a forgetting policy with algebraic
meaning. Eviction is a forgetting policy with none.

## Question 3: Is the similarity threshold for F a magic number?

It can be derived. The threshold should be the cosine distance at which
the reckoner's output changes by more than one bucket width. If the
reckoner's Lipschitz constant L is known (estimated from observations),
then the threshold is 1 - (precision / L). This makes F's threshold a
function of B's resolution. The two mechanisms compose — they do not
introduce independent parameters.

## Question 4: Is there a native compression for scalar prediction?

Yes, and it is B. The natural structure of "given a thought, what scalar?"
is a function T -> R. The natural finite approximation of a function is a
partition of its range into fibers. Each fiber has a prototype (the
centroid of its preimage) and a value (the centroid of the fiber). This is
not borrowed from the discrete case — it *generalizes* it. The discrete
reckoner with labels {Up, Down} is B with K=2 where the partition is given
by the label set. B is the natural completion of the pattern the discrete
reckoner already established. It is not an import. It is the colimit.

## Summary

D is a stopgap that forecloses composition. A is a collapse that
forecloses context. B preserves both — it is finite, composable,
convergent, and the bucket boundaries are derived, not chosen. With F
gating queries and the threshold derived from B's resolution, the entire
system has one free parameter: precision. Everything else follows.
