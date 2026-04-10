# Review: Proposal 009 — Brian Beckman

**Verdict:** ACCEPTED

The question is whether `Distances = trail * stop * tp * runner_trail` (a product of four) can be reduced to `Distances = trail * stop` (a product of two) without losing information that the downstream morphisms require. Let me work through it.

The cascade morphism `recommended-distances` has type `ExitObserver x Vector x Vec<ScalarAccumulator> -> Distances x f64`. Today it fires four independent cascades — one per field. Each cascade is structurally identical: reckoner -> accumulator -> crutch. The four cascades share no lateral information. They don't compose with each other. They are four parallel copies of the same diagram. Removing two copies cannot break the diagram — it simply narrows the product type.

The more interesting question is whether the simulation module's objective function changes. Today `compute-optimal-distances` sweeps four independent candidate sets. Each `simulate-*` function is `Vec<f64> -> f64` — pure, no shared state. The tp and runner-trail simulations are *independent fibers* of the same bundle as trail and stop. Removing them removes fibers, not the bundle's structure. The objective function — maximize residue — is unchanged for the two surviving fibers.

Now: does the product type lose a degree of freedom that matters? The proposal argues convincingly that it does not.

Take-profit is a *constant* morphism. It maps the entry thought to a fixed price level. The trailing stop is a *dynamic* morphism — it re-evaluates every candle via step 3c. A constant morphism composed with a dynamic one is dominated by the dynamic one in any sufficiently long sequence. The TP can only outperform the trail when the trail fails to tighten before a gap reversal — a measure-zero event at 5-minute resolution. The TP is an identity element that occasionally truncates. Removing it strictly enlarges the image of the profit morphism.

Runner-trail is subtler. It attempts to be a *phase-dependent* morphism — a different distance for the same thought, conditioned on portfolio state. But the exit observer's domain is the composed thought vector, which does not encode the phase. The reckoner sees `Vector -> f64`. If the phase is not in the vector, the reckoner cannot condition on it, and the runner-trail reckoner learns the *same* function as the trail reckoner from a different initial condition. Two reckoners learning the same morphism from different starting points will converge to the same fixed point. This is redundant — not a degree of freedom, but a duplicate basis vector. Removing it reduces the dimension of the parameter space without reducing the rank of the learnable map.

The category shrinks cleanly. The diagram still commutes: candle -> thought -> distances -> levels -> paper -> resolution -> optimal -> observe. Every arrow survives. The product type narrows but every consuming morphism (broker, trade, settlement) only destructures the fields it uses — trail for trailing stops, stop for safety stops. No morphism today consumes tp or runner-trail in a way that cannot be replaced by trail's continuous adaptation.

One concern worth monitoring: if the thought vector does not encode enough trending-regime signal, the trail reckoner might predict tight distances during runners, causing premature exits. This is an empirical question about the *richness of the thought functor's image*, not a structural defect. The 100k benchmark will answer it. If Grace degrades, the information was in the two extra fibers after all, and they should return — but I expect it won't.

Two reckoners. Two accumulators. Two simulations. Half the surface area, same algebraic rank. The diagram commutes. Accept.
