# Proposal 057 — L1/L2 Cache with Parallel Subtree Compute

**Scope:** userland
**Date:** 2026-04-16

## The current state

The encoding pipeline has one cache: a single-threaded LRU behind typed request channels (the L2). Every entity (11 market observers, 2 regime observers, 22 broker-observers) sends `batch_get` requests through pipes to one driver thread. The driver does hash lookups and returns vectors.

After Proposal 056 and seven cache iterations, throughput reached 7.1 c/s with 92% hit rate. The remaining bottleneck: `batch_get` pipe latency — 178ms for market observers, 194ms for brokers. The actual compute (Primitives calls) is under 7ms. The pipe round-trip is 95% of encode time. 33 clients × ~8 rounds of progressive descent × 17ms per round = the physics we're working against.

The cache driver thread is at 100% CPU. The 33 entity threads are at 5-25% CPU — mostly blocked waiting for cache responses.

## The problem

The entities can't compute because they're waiting on the pipe. The driver can't go faster because it's serializing 33 clients through one thread. The cores are idle while the pipe is saturated.

The cache is doing two things that should be separate:
1. **Memoization** — "I've seen this subtree before, here's the vector." This is local to the entity. Rhythm subtrees don't change between candles. The entity re-asks the L2 for vectors it got last candle.
2. **Sharing** — "Another entity computed this, here's the result." This requires the shared cache. Market observer A's rhythm subtree is the same as market observer B's if they share an indicator at the same window offset.

Memoization doesn't need a pipe. Sharing does.

## The proposed change

### L1: per-entity local cache

Each entity maintains its own `HashMap<ThoughtAST, Vector>`. No pipe. No lock. No channel. Direct lookup on the entity's own thread.

- Size: bounded, small. The working set is ~1300 nodes per encode. 4K-8K entries should cover the hot set across a few candles. LRU eviction when full.
- Lifetime: persists across candles within the entity. Warm after candle 1.
- Population: on every computed or L2-fetched vector, insert into L1.
- Hit rate projection: very high after warmup. Most rhythm subtrees repeat between candles — only the newest candle's values change. 95%+ L1 hit rate expected at steady state.

### L2: the shared cache (existing, unchanged)

The current cache program. Typed requests, batched dispatch, epoll-style driver. Unchanged API: `batch_get`, `batch_set`, `get`, `set`.

The L2 receives fewer requests — only L1 misses. Instead of 33 entities × 8 rounds × ~120 keys = ~31,680 cache lookups per candle, the L2 sees only L1 misses. If L1 hit rate is 95%, L2 traffic drops to ~1,584 lookups per candle. 20x reduction.

### Parallel subtree compute via rayon

When the entity finds unknown subtrees (L1 miss AND L2 miss), it computes them in parallel using rayon's work-stealing thread pool. Rayon uses real OS threads (one per core at startup) with work-stealing deques. Tasks are closures. The kernel schedules the OS threads. Rayon schedules the tasks onto those threads.

The pattern:
1. Walk the AST top-down on the entity thread.
2. Check L1. Hit → return immediately.
3. L1 miss → collect into a batch. After walking one level, send one `batch_get` to L2.
4. L2 hits → insert into L1, continue.
5. L2 misses → these are compute work. The unknown subtrees are independent. Fan them out as rayon tasks. Each task computes its subtree using only Primitives (bind, bundle, permute, scalar encode). No cache access inside the task — just math.
6. Join all tasks. Collect the computed vectors.
7. Insert all computed vectors into L1.
8. Submit all computed vectors to L2 via `batch_set` (fire-and-forget).
9. Continue walking up the tree using L1.

The parallelism is reflexive — it matches the AST structure. A Bundle with 20 unknown children spawns 20 tasks. A Bind with 2 unknown children spawns 2 tasks. A leaf spawns none. The fan-out IS the concurrency. No fixed pool size chosen by a human. Rayon's work-stealing distributes tasks across cores.

### The encode flow

```
entity thread:

  for each AST node (top-down, level by level):
    L1 hit?  → use it (instant, no pipe)
    L1 miss? → add to L2 batch

  send L2 batch_get (one round-trip for all L1 misses)

  for each L2 result:
    L2 hit?  → insert into L1
    L2 miss? → add to compute batch

  rayon::scope(|s| {
    for each unknown subtree:
      s.spawn(|| compute_subtree(subtree))  // pure math, no cache
  })
  // all tasks join here

  insert all computed vectors into L1
  batch_set all computed vectors to L2

  walk up the tree using L1 (everything is local now)
```

### Expected outcome

- L1 absorbs 95%+ of lookups. No pipe. No contention.
- L2 traffic drops 20x. Driver thread goes from 100% to ~5%.
- Unknown subtrees compute in parallel across all cores.
- Entity threads go from 5-25% to core-saturating.
- The pipe is no longer the bottleneck. Compute is.

## The algebraic question

No algebraic change. The six primitives are unchanged. The ThoughtAST is unchanged. The encoding produces the same vectors. L1 and L2 are implementation concerns — memoization and sharing. The algebra doesn't know about caches.

Rayon's work-stealing composes — each task is a pure function from ThoughtAST to Vector. No shared mutation. No side effects inside the tasks. The join is the synchronization. The algebra is the same whether computed sequentially or in parallel.

## The simplicity question

**What's being complected?** Nothing new. The L1 is a HashMap. The L2 is unchanged. Rayon is a dependency. The encode function gains a local cache parameter and a rayon scope. The progressive descent logic stays — it just checks L1 before L2.

**Could existing forms solve it?** No. The pipe latency is structural. No amount of batching or reordering eliminates the round-trip. The L1 eliminates the round-trip for repeated lookups. Only parallel compute can saturate the idle cores.

**What's the risk?** Rayon adds a dependency. The L1 adds memory per entity (33 × 8K entries × ~10KB per vector = ~2.6GB total at 8K entries). If too large, reduce to 4K entries (~1.3GB). The L1 size is the one parameter to tune.

## Questions for designers

1. Is the L1-per-entity the right granularity? Should broker-observers share an L1 with their market observer (same rhythm subtrees)?

2. Rayon's global thread pool vs per-entity thread pools — one shared pool means all entities' compute tasks compete in the same deques. Is this acceptable, or should entities have isolated pools?

3. The L1 eviction policy — LRU matches the L2. Should L1 use a different policy given its smaller size and entity-local access pattern?

4. Should the rayon compute tasks have read access to L1 (shared reference), or should they be fully independent (no cache, just math)? Read access means they can short-circuit on L1 hits inside the subtree. No access means simpler — pure functions, no shared state.

5. The L1 size — 4K, 8K, 16K entries per entity. What's the right working set? The measurement will tell, but is there a principled starting point?
