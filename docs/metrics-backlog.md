# Metrics Backlog — Find the Bottleneck

## What we know

- Market observer encode: 197ms avg (Arc binary)
- 872 AST nodes walked per encode
- 800 cache hits, 71 misses per encode
- ns_cache_get: 194ms total (all 872 gets)
- ns_compute: 594ms (OVERLAPPING — includes recursive encode calls)
- ns_cache_set: 0.2ms (negligible)
- Cache at capacity: 262,144 entries, thrashing

## What ns_cache_get includes (caller thread)

`cache.get(ast)` does:
1. `ast.clone()` — clone the ThoughtAST key to send through channel
2. `get_tx.send(cloned_key)` — send to cache driver
3. `get_rx.recv()` — block waiting for response

**Missing metrics on the caller:**
- `ns_key_clone` — time to clone the AST key before sending
- `ns_channel_wait` — time blocked on recv after send

## What the cache driver does (driver thread)

The driver loop:
1. `try_recv` on set mailbox — drain pending installs
2. `try_recv` on each client's get queue — service pending lookups
3. For each get: `cache.get(&key).cloned()` — LRU hash + lookup + Vector clone on hit
4. `resp_tx.send(result)` — send response back

**Missing metrics on the driver:**
- `ns_driver_hash_lookup` — time in LRU .get() per request
- `ns_driver_set_put` — time in LRU .put() per install
- `ns_driver_loop_idle` — time between requests (is it spinning?)
- `driver_queue_depth` — how many gets pending when serviced
- `driver_sets_drained` — how many sets drained per loop iteration

## What ns_compute includes (BROKEN — overlapping)

The current timer wraps the entire match block. For Bind:
```
let t0 = now();
let l = encode(cache, left, vm, scalar);  // RECURSIVE — includes child cache_gets
let r = encode(cache, right, vm, scalar);  // RECURSIVE — includes child cache_gets  
Primitives::bind(&l, &r);                  // THE ACTUAL WORK
ns_compute += elapsed(t0);                 // counts children too
```

**Must fix:** measure only the leaf operation, not recursive children.

**Missing metric:**
- `ns_leaf_compute` — ONLY the Primitives call. For Bind: just bind().
  For Bundle: just bundle(). For Permute: just permute(). For scalars:
  just scalar.encode() or vm.get_vector(). EXCLUDES recursive children.

## Programs missing encode metrics

### Broker program
Calls `encode(&cache, &thought_ast, &vm, &scalar)` for gate4.
The broker's AST is larger than any single market observer's — it
bundles market rhythms + regime rhythms + portfolio rhythms + phase
rhythm + time. No encode metrics emitted.

**Missing:** all encode metrics on broker's gate4 encode.

### Regime observer program  
Does NOT call encode(). Builds ASTs only. No encode metrics needed.
But clones regime_asts per slot (11 times). Clone cost unknown.

**Missing:** `ns_regime_ast_clone` — cost of cloning rhythm ASTs
per slot.

## Computation points NOT measured anywhere

### ThoughtAST Hash computation
The LRU cache hashes the ThoughtAST key on every get and put.
With Arc children, the Hash impl dereferences through Arc and
walks the subtree. A Bind hashes both children recursively.
A Bundle hashes all children. For a 100-pair rhythm bundle, the
hash walks 100 pairs × 2 trigrams × 3 facts each = ~600 nodes
PER HASH. This happens on the DRIVER thread.

**Missing:** `ns_ast_hash` — time to hash one ThoughtAST key.

### ThoughtAST Clone for cache.get()
`cache.get(ast)` calls `ast.clone()` to send through the channel.
With Arc children, Bind/Permute clone is cheap (Arc increment).
But Bundle clones the Vec of children — each child is cloned.
The top-level Bundle(rhythms) clones ~25 rhythm ASTs. Each rhythm
is a Bind(Atom, Bundle(pairs)) — Arc clone on the outer, but
the inner Bundle clones the pairs Vec.

**Missing:** `ns_ast_clone_for_get` — cost of cloning the AST
key on the caller thread before sending.

### Vector clone on cache hit
`cache.get(&key).cloned()` on the driver clones the Vector value
(10,000 i8). This is a memcpy of 10KB. 800 hits per encode =
8MB of memcpy per candle per observer.

**Missing:** measured indirectly in ns_driver_hash_lookup but
not isolated.

### Arc::clone vs deep clone cost
We switched Box to Arc. Are we getting the benefit? The rhythm
Bundle still contains a `Vec<ThoughtAST>`. Cloning the Vec clones
each element. If the elements are Bind(Arc, Arc), each clone is
cheap. But if they're Bundle(Vec<...>), each clone walks the Vec.

**Missing:** verify Arc benefit with a simple timing test —
clone a rhythm AST before and after Arc, compare.

## The question

194ms for 872 cache gets = 223μs per get. Is that fast or slow?

A channel send + recv roundtrip through crossbeam should be ~1μs.
223μs is 223x slower than a bare channel roundtrip. Something
else is happening in that 223μs. Candidates:

1. AST clone before send (walks the tree)
2. AST hash on the driver (walks the tree)  
3. LRU eviction on the driver (capacity thrashing)
4. Driver busy with other clients' requests (contention)
5. Vector clone on hit response (10KB memcpy)

The metrics above isolate each candidate. Add them. Measure.
Stop guessing.
