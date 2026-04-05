# Review: Rich Hickey

Verdict: APPROVED

---

## Addressing the four conditions from 006

**Condition 1 -- Start with M=1 exit observers.** Addressed. The proposal describes four exit lenses (volatility, structure, timing, generalist) but section 6 question 1 explicitly asks: "do we start with all four exit lenses, or start with one (exit generalist) and earn the specialization?" This is the right question asked at the right time. The architecture is M-agnostic. Start with one. The condition is met if the implementation respects this.

**Condition 2 -- Acknowledge the scalar extraction risk.** Addressed by elimination. This is the most important change from 006 to 007. The proposal abandons scalar extraction from a direction-optimized discriminant entirely. The LearnedStop is a separate regression -- cosine-weighted nearest neighbor averaging over (thought, distance) pairs. It is not a journal. It does not optimize for Buy/Sell. It optimizes for distance directly. The scalar lives in its own space, not as a passenger on someone else's vehicle. My concern from 006 was that the trail-width scalar would not survive extraction from a direction discriminant. The proposal solved this by not putting it there.

**Condition 3 -- Treasury allocation as a snapshot, not a mutable ref.** The proposal moves from N*M fibers (006's channels) to three flat pre-allocated vecs with disjoint slot access. This is a stronger answer than I asked for. There is no allocation table to snapshot. Each slot is owned by exactly one (market, exit) pair. No concurrent reads of shared state because there is no shared state -- each index is independent. The borrow checker enforces disjointness. This is values, not places. Condition met.

**Condition 4 -- The hard switch.** The proposal does not mention the transition question at all. There is no single-sided-to-dual-sided transition because dual-sided excursion is already proven and in the code (`DualExcursion` in `position.rs`). The exit observer starts from ignorance (LearnedStop returns `default_distance` when empty) and blends toward learned values as pairs accumulate. No switch. No mixing parameter. A continuous emergence from ignorance to competence. This is better than a hard switch. Condition met by dissolution -- the question no longer exists.

---

## Four steps: simple or complected?

RESOLVE, COMPUTE+DISPATCH, PROCESS, COLLECT+FUND.

This is simple. Each step has one job. The coupling between steps is data flow: Step 1 produces settled state. Step 2 produces thoughts and proposals. Step 3 consumes thoughts. Step 4 consumes proposals. No step reads from a later step. No step writes to a place that an earlier step reads. The ordering is a pipeline, not a cycle.

The naming reveals the thought. "COMPUTE+DISPATCH" is honest -- it acknowledges that Step 2 does two things (market observers compute, exit observers dispatch to treasury). These two things are genuinely sequential within the step: you cannot dispatch until you have computed. They belong together. Splitting them into separate steps would create a false boundary -- a step that produces thoughts with no consumer, followed by a step that consumes them. Worse. The proposal chose correctly.

Step 3 (PROCESS) is the step I would watch. It does three things: update active trade triggers, tick paper entries, resolve papers into learning. These are related but not identical operations. If PROCESS grows to encompass more concerns, it should split. For now, it is one concern -- "advance the state of all open entries by one candle" -- expressed as three sub-operations on the same data. Acceptable.

---

## The tuple journal as a closure over (market, exit)

The proposal says: "the tuple journal IS the anonymous function that routes reality to the right observers. The struct is the implementation. The closure is the thought."

This is the right distinction. In a language with first-class closures, `propagate` would literally be a closure that captured `market_observer` and `exit_observer`. In Rust, it is a struct with two references and a method. The concept is the same. The struct fields are the closed-over values. The method is the function body. The lifetime of the struct is the lifetime of the closure.

Does the closure hold? The closure needs to route three things: (1) Win/Loss to the market observer, (2) optimal distance to the exit observer's LearnedStop, (3) Grace/Violence to its own track record. All three are produced from the same event (trade resolution). All three require the same inputs (outcome, closes, entry_price). The closure captures the right things and routes them to the right places. It holds.

The question is whether the closure should also hold paper entries. The proposal says yes -- papers are internal state of the closure. This means the tuple journal is both a routing function AND a container. In functional terms, the closure is stateful -- it accumulates papers, ticks them, resolves them. This is a common pattern (accumulators that close over mutable state), but it means the tuple journal is not a pure function. It is a process.

This is fine. The tuple journal is explicitly described as a process -- it receives candles, updates its state, emits proposals. Calling it a closure is metaphor. Calling it a process is accurate. Both are useful. The implementation is a struct with methods. The struct holds state. The methods advance the state. This is what processes are.

---

## Three flat N*M vecs, mutex-free parallel

The lock-freedom is real, not wishful. Here is why.

The index `i = market_idx * M + exit_idx` is deterministic. Given a (market, exit) pair, only one thread ever computes that index. `par_iter_mut` over disjoint index ranges guarantees that no two threads touch the same slot. The borrow checker in Rust cannot prove this at the type level for arbitrary index arithmetic -- but `par_iter_mut` on a slice yields `&mut` references to non-overlapping elements. If the parallelism is over the outer dimension (market observers), each market observer touches indices `[market_idx * M .. (market_idx + 1) * M]`, which are disjoint ranges. This is safe.

The proposal correctly identifies that Step 2's exit dispatch is sequential -- it mutates the treasury (creates journals, inserts proposals). The parallelism is in the market observer computation. The exit dispatch within each market observer's iteration touches only that observer's M slots. If two market observers run in parallel, they touch disjoint slot ranges. No conflict. No lock.

There is one subtle issue. The proposal says `registry[i]` -- "only pair `i` reads or writes its journal." But in Step 1 (RESOLVE), the treasury iterates `active_trades` and calls `tuple_journal.propagate()`. This is a sequential step, so no conflict. In Step 2, exit observers read from `registry[i]` to check the proof curve. This is within the same pair's parallel slice. In Step 3, active trades are updated. Sequential. In Step 4, proposals drain. Sequential. The invariant holds: within each parallel step, each slot is touched by at most one thread.

Pre-allocation at startup, fixed size, never grow, never shrink. This is the right choice. Dynamic growth during parallel execution is where lock-free data structures become complex. Fixed-size vecs with disjoint access are genuinely lock-free by construction.

---

## Papers inside the closure

The proposal puts paper entries inside the tuple journal. Each (market, exit) pair manages its own papers. Papers never leave the closure.

Is this the right place?

Yes. The paper entries exist to train the LearnedStop. The LearnedStop belongs to the exit observer. The training signal requires the (market thought, exit composition, optimal distance) triple. The tuple journal is the only entity that has all three: it receives the market thought, it composes with the exit judgment, and it computes the optimal distance when the paper resolves. If papers lived elsewhere, the resolution would need to route the training signal back to the tuple journal. By putting papers inside the closure, the training loop is closed within one struct. No routing. No channel. No indirection.

The memory concern (section 6 question 2) is reasonable. Seven observers times ~100 candle average lifetime is ~700 concurrent papers. Each paper is a DualExcursion (8 floats = 64 bytes) plus a thought vector reference. At 4096 dimensions, a thought vector is ~4KB. 700 papers * 4KB = ~2.8MB. With N*M tuple journals (7 * 4 = 28 at maximum), that is ~80MB. Not nothing, but not a problem. The concern should be about thought vector lifetime, not paper count. If each paper holds a clone of the thought vector, memory scales with paper count. If papers hold indices into a shared thought buffer, memory is constant. The proposal does not specify. It should.

---

## LearnedStop as the exit observer's brain

The LearnedStop is nearest neighbor regression. Not a journal. Not a discriminant. Not a prototype. A weighted average of historical (thought, distance) pairs, weighted by cosine similarity to the query thought and by the residue weight of each pair.

Is this simpler than a journal?

Simpler to reason about: yes. The journal learns a discriminant that separates two categories. The discriminant is a direction in thought-space. The prediction is "which side of the discriminant is this thought on?" The extraction of a continuous value from the discriminant requires a second step (cosine against a scalar atom) that may or may not carry signal. The LearnedStop bypasses all of this. Input: a thought. Output: a distance. The mapping is direct. There is no intermediate representation to decode.

Simpler in mechanism: also yes. The journal uses online PCA, accumulation, recalibration, engram snapshots, proof curves. The LearnedStop uses cosine similarity and weighted averaging. Two operations. The `recommended_distance` method is eight lines. The `observe` method is four lines. The total implementation is 80 lines including tests. This is an honest primitive.

The trade-off: the journal generalizes across the thought space via the discriminant. It learns a direction that captures the common structure of winning thoughts. The LearnedStop does not generalize -- it interpolates. A thought that is dissimilar to all stored pairs gets the default distance. The journal would give it a prediction (possibly wrong, but a prediction). The LearnedStop gives it ignorance. For this application, ignorance is the right answer. "I have never seen a thought like this, so I will not propose a trade" is better than "I have never seen a thought like this, so here is my best guess at a distance."

The LearnedStop's weakness is the linear scan. `recommended_distance` iterates all stored pairs. At 5000 pairs, that is 5000 cosine computations per query. With N*M tuple journals querying every candle, that is 28 * 5000 = 140,000 cosine computations per candle. At 4096 dimensions, each cosine is ~4K multiplies and ~4K adds. This is on the order of 10^9 floating point operations per candle. Not prohibitive for offline backtesting. Possibly a concern for live trading at 5-minute candles.

The proposal does not discuss this. The cap (`max_pairs`) limits the scan, but the right solution is a spatial index (locality-sensitive hashing or a tree). This is an optimization, not a design concern. The interface (`observe` + `recommended_distance`) is correct regardless of the internal index structure. Design for the interface, optimize the implementation later.

---

## Treasury as registry with three vecs

The treasury holds: `registry` (permanent TupleJournals), `proposals` (per-candle, cleared), `trades` (active positions).

Is the treasury taking on too much?

The current treasury (`treasury.rs`) is pure accounting: balances, deployed, claim, release, swap. It knows about tokens, not about observers or journals. The proposal adds three vecs of observer-specific state. This is a different kind of responsibility. The treasury goes from "ledger" to "ledger + registry + proposal queue + trade manager."

However -- the alternative is worse. If the registry lives outside the treasury, the proposal queue lives outside the treasury, and the trade map lives outside the treasury, then Step 4 (COLLECT + FUND) must coordinate three separate structs. The funding decision requires all three: the journal's proof curve (registry), the proposal parameters (proposals), and the available capital (treasury). Splitting them creates a coordination problem that the proposal solves by co-location.

The treasury is the only entity that sees reality. It holds the capital. It executes swaps. It settles trades. It is the right place for the funding decision. The three vecs are not treasury concerns -- they are data the treasury needs to make its one decision: fund or reject. Co-locating the data with the decision is simpler than passing it through a channel.

The risk: the treasury struct grows. It was 15 fields. It becomes 18 fields plus three vecs. This is manageable if the vecs are treated as indexed stores, not as active participants. The treasury should index into them, not iterate over them with complex logic. Step 4 should be: for each proposal, look up the journal, check the curve, check capital, fund or reject. A flat loop. No nesting. No branching on registry state. If this discipline holds, the treasury is a registry in the database sense -- a lookup table, not a decision engine.

---

## Did this address the conditions from 006?

All four conditions are addressed. Two are addressed by direct compliance (M=1, snapshot semantics). One is addressed by elimination (scalar extraction risk dissolved by LearnedStop). One is addressed by dissolution (hard switch question no longer exists).

The proposal also addressed something I did not ask for but should have: the elimination of the manager. The 006 review accepted the pair as accountability but did not question whether the manager could be removed entirely. This proposal removes it. The tuple journal IS the manager for its pair. The manager encoding in `market/manager.rs` has no role in this architecture. The proposal does not say this explicitly, but it is implied by the signal flow diagram -- there is no manager node. The manager is dead. The tuple journal replaced it.

This is the right call. The manager was aggregation. Aggregation is lossy. The tuple journal preserves the full (market, exit) identity. Attribution survives. The manager's conviction threshold is replaced by the tuple journal's proof curve. The manager's encoding is replaced by the exit observer's composition. Every function the manager served is served by an existing primitive applied at the pair level.

---

## What I would watch

1. **Paper vector memory.** The proposal is silent on whether papers clone or reference thought vectors. At scale, this matters. Specify the ownership model for paper entry thoughts.

2. **LearnedStop scan cost.** Linear scan over 5000 pairs, 28 times per candle, is feasible but not free. If the backtest shows this is a bottleneck, the fix is an index structure, not a design change. The interface is correct.

3. **Step 3 scope creep.** PROCESS does three sub-operations. If a fourth appears, split the step. Three is acceptable. Four is a smell.

4. **The tuple journal struct size.** It already has 16 fields plus a `Vec<ScalarAccumulator>`. Adding paper entries makes it larger. If the struct grows past 20 fields, consider whether the papers should be a nested struct (PaperManager) owned by the tuple journal. The closure concept survives nesting. The flat struct does not survive indefinite field accumulation.

---

## The simplification from 006 to 007

006 was ambitious and sprawling. 12,000 words. The exit observer was a full observer with its own encoding pipeline, its own journal, its own discriminant. The scalar lived on the sphere with the direction signal. The manager was gone but the complexity was not -- it was redistributed into the N*M composition matrix.

007 is narrower and more honest. The exit observer is a regression, not a journal. The scalar lives in its own space (LearnedStop), not on someone else's sphere. The four steps make the pipeline explicit. The three vecs make the state explicit. The pre-allocation makes the memory explicit. The `par_iter_mut` over disjoint slots makes the parallelism explicit.

The proposal learned from the review. The scalar extraction concern was not patched -- it was dissolved. The snapshot semantics concern was not addressed by adding snapshot logic -- it was dissolved by eliminating shared state. The M=1 concern was not argued against -- it was accepted. This is how proposals should evolve.

The pieces are tested. The wiring is specified. The steps are sequential. The parallelism is proven by construction. The closure concept maps to Rust structs. The LearnedStop is 80 lines. The optimal distance computation is a pure function.

Build it.
