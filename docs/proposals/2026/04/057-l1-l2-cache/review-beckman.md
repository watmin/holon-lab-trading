# Review: Brian Beckman

Verdict: CONDITIONAL

## The algebraic situation

The proposal claims no algebraic change. This is almost true, and the "almost" is where the interesting mathematics lives.

The six primitives (atom, bind, bundle, permute, cosine, reckoner) are pure functions. The ThoughtAST is a free algebra over those primitives -- it is literally the initial algebra of the signature. The encoding function `encode_local` is the unique homomorphism from that free algebra into the vector space. This is categorical structure: the AST is the syntax, the vector space is the semantics, the encoder is the interpretation.

Caching is memoization of a pure function. Memoization does not change the denotation. Whether the memo table lives on a shared driver thread (L2) or in a thread-local HashMap (L1) is operationally different but denotationally identical. The proposal preserves the homomorphism. Good.

Rayon's work-stealing on independent subtrees is parallel evaluation of independent subexpressions. Since bind and bundle are deterministic pure functions (no side effects, no ambient state), the evaluation order is irrelevant to the result. The Church-Rosser property holds. The join at the rayon scope boundary is the synchronization -- all children complete before the parent composes. This is a standard parallel catamorphism over a tree. Algebraically sound.

So: the monoid is preserved. The operations close. No escapes. The "almost" I mentioned is not algebraic -- it is operational, and I will get to it.

## What is actually being proposed

Strip away the performance narrative and this is a clean factoring of a monad.

The current system has one memo table (the L2) accessed through an effectful channel (send/recv). The proposal factors this into:

1. A pure local memo (L1) -- a Reader-like environment, no effects
2. An effectful shared memo (L2) -- unchanged
3. A parallel evaluator (rayon) -- pure, deterministic, no shared state

This is good algebraic hygiene. The L1 is the identity element of the caching monoid -- it adds nothing to the algebra, it only short-circuits evaluation. The L2 handles the cross-entity sharing, which is the one place where communication (and therefore ordering) matters.

## The condition

### 1. Cache coherence is your obligation, not the algebra's

The proposal has L1 persisting across candles. The L2 is also persistent. When an entity computes a vector and inserts it into L1, it also batch_sets to L2. Other entities eventually see it in L2. But here is the question the proposal does not answer:

**What invalidates an L1 entry?**

The ThoughtAST nodes that contain scalar values (Linear, Log, Circular, Thermometer) carry quantized candle data. A rhythm subtree for "RSI at window offset 3" will have different scalar leaves on candle N vs candle N+1 (the newest candle shifted in). The round_to quantization means the AST itself changes -- the cache key changes. So the old L1 entry is not invalid, it is simply unreachable. New key, new miss, new computation. The old entry occupies space but causes no incorrectness.

This is fine IF AND ONLY IF the vocabulary modules are disciplined about embedding the quantized value in the AST node. I verified this in your code -- `round_to` happens at emission time, and the Hash implementation uses `to_bits()`. The structural equality IS the cache key. So stale entries waste space but never produce wrong answers. LRU eviction handles the space.

The condition: **document this invariant explicitly.** The correctness of L1 depends on the vocabulary modules never reusing an AST node with changed semantics. Today this holds because scalar values are embedded in the AST. If someone ever introduces a mutable reference (an index into a table, a pointer to a changing value), L1 becomes unsound. The AST-as-value property is load-bearing for the entire L1 design.

### 2. The memory estimate needs scrutiny

33 entities x 8K entries x ~10KB = ~2.6GB. This is high. But let me check the actual arithmetic.

A Vector at 4096 dimensions of bipolar integers is 4096 bytes (i8) or 16384 bytes (i32). The ThoughtAST key varies -- an Atom is a String (~50 bytes), a deep Bundle can be large due to the tree. With Arc sharing on Bind children, the key overhead is smaller than it appears, but the Vector is the dominant cost.

At 4096 dimensions with i8 encoding: 4096 bytes per vector. 8K entries = 32MB per entity. 33 entities = ~1GB. Manageable.

At i32 encoding: 4x that. 4GB. Less manageable.

The proposal should specify the actual vector representation size and compute the real number before committing to 8K entries. The parameter "L1 size" is load-bearing for memory, and the right size depends on the working set per entity per candle -- measure it, don't guess it.

### 3. Rayon is the right tool but scope placement matters

The proposed encode flow has rayon::scope at the point where L1 and L2 both miss. The subtrees are independent -- they share no mutable state. Rayon's work-stealing will naturally balance load across cores. This is textbook data parallelism on a tree.

One subtlety: the proposal says rayon tasks should be "pure math, no cache." This is correct for L2 (you cannot send on a pipe from a rayon worker without introducing channel contention that defeats the purpose). But the question of whether rayon tasks should read L1 is interesting.

If L1 is a thread-local HashMap and rayon workers run on the rayon thread pool (not the entity thread), the L1 is invisible to workers. They would need their own memo tables or receive a shared reference. Since the entity's L1 is not Sync (it is a plain HashMap), sharing it with rayon workers requires either a read lock or passing it as a reference into a scope that proves the borrow outlives the workers.

rayon::scope gives you exactly this: the scope proves all spawned tasks complete before the scope exits, so a `&HashMap` borrow into the scope is safe. The workers can read L1 without locks. They should. There is no reason to recompute a subtree that L1 already has, and the read is a pointer chase -- nanoseconds.

**The condition:** rayon tasks MUST have read access to L1. Forbidding it doubles the computation for partially-resolved subtrees. Pass `&local_cache` into the scope.

## Answers to the designer questions

1. **L1 granularity.** Per-entity is correct. Sharing L1 between a broker-observer and its market observer would require synchronization, which is the problem you are solving. If two entities happen to need the same subtree, L2 handles the sharing. L1 is private. This is the monoid: L1 composes with L2 via "check L1, then L2, then compute."

2. **Rayon global pool vs per-entity.** Global pool. Rayon's default thread pool is one-per-core with work-stealing. 33 entities will not all miss simultaneously -- the pool naturally absorbs bursty demand. Per-entity pools waste threads and lose the work-stealing benefit. The algebra does not care -- the tasks are pure -- but the operational efficiency strongly favors a shared pool.

3. **Eviction policy.** LRU is fine. The access pattern is temporal locality with slow drift (each candle shifts the window by one). The working set is the current candle's AST nodes plus recent ancestors. LRU captures this naturally. More exotic policies (LFU, adaptive) add complexity for marginal gain in this access pattern.

4. **Rayon read access to L1.** Answered above. Yes. Read access. No writes from workers -- the entity thread inserts after the scope completes. Borrows, not mutations.

5. **L1 size.** Measure the working set. You say ~1300 nodes per encode. With 33 entities and significant overlap, the unique nodes per entity are likely fewer. Start with 4K, instrument the eviction rate, adjust. Do not pick 8K or 16K without data.

## Summary

The proposal is algebraically clean. The primitives are unchanged. The encoding homomorphism is preserved. Memoization is denotationally transparent. Parallel evaluation respects the Church-Rosser property. The monoid closes.

The conditions:

1. Document the AST-as-value invariant that makes L1 sound (no mutable references in cache keys, ever).
2. Compute actual memory cost from measured vector size before choosing L1 capacity.
3. Allow rayon workers to read L1 via shared reference within the scope. Do not forbid cache reads from workers.

With these three addressed, the proposal is approved.
