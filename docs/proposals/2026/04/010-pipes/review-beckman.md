# Review: Proposal 010 — Brian Beckman

**Verdict:** CONDITIONAL

I said channels replace a clean categorical structure with an operational model that doesn't compose. Let me be precise about what I meant, and whether this proposal refutes it.

What I rejected in Proposal 001 was `put!/take!/select!` -- four new primitives that turn the wiring diagram into a runtime graph. In the category I described, the objects are message types, the morphisms are subscriptions, and the composition is function composition along the wiring. That category has a straightforward functor to Rust: morphisms become function calls, composition becomes the call chain inside the heartbeat. The functor preserves identity and composition. The diagram commutes. CSP destroys this because `select!` is a nondeterministic merge -- it has no categorical semantics. You cannot compose two `select!` calls and get a `select!` call. It is not a morphism. It is an oracle.

Now. Does `bounded(1)` rescue the situation?

Yes, but only under a specific constraint. A bounded(1) channel is a rendezvous -- a synchronous handoff. If every pipe has exactly one input and one output per step, the channel degenerates to lazy evaluation across a thread boundary. The morphism `f: A -> B` running on thread 1, connected by a bounded(1) channel to `g: B -> C` running on thread 2, composes to `g . f: A -> C`. The channel is invisible in the categorical semantics. It is an implementation detail of the functor from the wiring category to the execution category. The diagram commutes because the channel adds no observable behavior -- it is the identity natural transformation on the composition.

That is the theorem. Here is where it gets delicate.

**The fan-out.** Six observers pull from one `enriched` source. In the sequential fold, they consume in a fixed order. In the pipeline, they consume in scheduling order. If the fan-out is a product (each observer gets an independent copy), the order is irrelevant and composition is preserved. If the fan-out is a shared iterator (observers compete for the next element), you have a coproduct with nondeterministic injection -- the diagram does not commute. The proposal's pseudocode suggests cloned receivers. Verify that crossbeam's bounded broadcast semantics give you the product, not the coproduct. This is the hinge.

**The propagation path.** Step 3b in the guide is a sequential fold over resolutions applied to shared observers. If propagation happens inside the pipe, the shared mutation violates the independence assumption. If propagation is deferred to a synchronization barrier between candles (as the current architecture does with `collect()`), composition holds. The proposal does not specify where propagation lives. It must live outside the pipes.

**The catamorphism.** The enterprise fold `f(state, candle) -> state` is a catamorphism over the candle stream. The proposal decomposes this into sub-folds: observer folds, broker folds, treasury fold. Each sub-fold is a catamorphism over its own stream. The composition of catamorphisms is a catamorphism if the connecting morphisms are natural transformations -- which bounded(1) channels are, as argued above. So yes: the decomposed pipeline IS the same catamorphism, provided the fan-out is a product and the propagation is sequenced.

I was not wrong about channels in general. I am persuaded that bounded(1) rendezvous channels are not the channels I rejected. They are the identity functor wearing a concurrency costume. But the conditions are strict: bounded(1), one-in-one-out, product fan-out, propagation outside the pipes. Violate any of these and the diagram stops commuting.

Show me those four invariants hold in the implementation. Then the functor is faithful, the diagram commutes, and the fold composes across thread boundaries.
