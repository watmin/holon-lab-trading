# Review: Proposal 016 — Adaptive Buckets
**Reviewer:** Brian Beckman
**Verdict:** No. Keep fixed K. The algebra says why.

## Question 1: Is one split threshold simpler than fixed K + range?

No. It is differently complex. Fixed K + range gives you a partition of the codomain known at construction time. The split threshold gives you a partition that depends on the observation history. The first is a functor from a static index category into Vect. The second is a functor from a *filtered* category — the index grows with time. You have traded a parameter you can reason about (K) for a parameter you cannot predict (the eventual number of buckets). That is not simplification. That is deferral.

## Question 2: Should K be capped, or grow forever?

Neither option is satisfying, and the question reveals the problem. A cap reintroduces a parameter — now you have min_split AND max_K, which is worse than just K. Uncapped growth means the functor's index category has no terminal object. You never reach a fixed point. Every query operates on a different structure than the last. This is not fatal — colimits over filtered diagrams exist — but it means your performance bounds are not stationary. The reckoner's cost is a random variable, not a constant. For a system that must fit inside a per-candle budget, stationarity matters.

## Question 3: Is 0.09% error acceptable for eliminating two parameters?

The error is acceptable. The elimination is not real. You removed K and range. You added min_split, which controls the growth rate, which determines the eventual K, which determines the error. The dependency chain is longer, not shorter. Worse: with fixed K=10, I can prove the interpolation error bound from the partition width. With adaptive K, the bound depends on the split history. You have made the error analysis path-dependent.

## Question 4: Is the discrete/continuous asymmetry a problem?

No. This is the one place I agree with the proposal. Discrete K=2 is a coproduct — it is the terminal object in its category. Continuous K is necessarily larger because the codomain has finer structure. The asymmetry is not a defect; it is the Yoneda lemma reminding you that representable functors on different categories have different shapes. But this observation supports fixed K, not adaptive K. The continuous codomain has a natural resolution determined by the precision you need. That resolution gives you K. It does not give you a growth process.

## The redistribution question

The proposal does not address this, but it matters. When a bucket splits, its accumulated prototype must be redistributed to the two children. This is a natural transformation only if the redistribution preserves the monoid homomorphism — the bundle of the children must equal the parent. For soft-weighted interpolation with decay, this is not guaranteed. The decayed prototype in the parent bucket was computed under a different partition topology. Splitting it post hoc is not the same as having computed the children from the start. The error may be small. But it is not zero, and it compounds with every split.

## Verdict

**No.** Fixed K=10, calibrated once at N=2000, measured against ground truth. The proposal proved that the data *can* discover K. That is interesting. But "can" is not "should." The adaptive mechanism trades a known parameter for an unknown growth process, introduces path-dependent error bounds, and requires a redistribution step whose algebraic cleanliness is unproven. The 1ms cost difference is irrelevant. The composability difference is not.

Keep B as accepted. Spend the cleverness elsewhere.
