# Resolution: Proposal 057

**Decision:** APPROVED with conditions from both designers incorporated.

## Ship both — L1 and rayon together

Hickey argues for sequencing: L1 first, measure, then rayon. The datamancer overrules on this point. The L1 and rayon touch different phases of the encode flow — L1 is a HashMap check before the pipe, rayon is a scope after the pipe. They don't interact. The AST has natural parallelism and we want to exploit it. Measure both together.

Beckman's three conditions are accepted and required:

1. **Document the AST-as-value invariant.** The correctness of L1 depends on vocabulary modules embedding quantized scalar values in the AST node. `round_to` at emission time + `Hash` via `to_bits()` means changed values produce changed keys. Stale entries are unreachable, not incorrect. This invariant is load-bearing and must be documented in encode.rs.

2. **Measure actual memory before choosing L1 capacity.** Vector is i8 at 10,000 dimensions = 10KB per entry. Start with 2048 entries per entity (~20MB per entity, ~660MB total for 33 entities). Instrument L1 hit rate. Adjust from measurement.

3. **Rayon tasks read L1.** Pass `&HashMap` into the rayon scope. Workers short-circuit on L1 hits inside subtrees. Writes happen after the scope — the entity thread inserts all computed results into L1 post-join. Read-only sharing during compute, write after compute. Values up.

## Additional decisions

- **Global rayon pool.** Both designers agree. One pool, work-stealing across cores.
- **LRU for L1.** Use the `lru` crate — same O(1) LRU we use for L2. No rolling our own.
- **L1-per-entity.** Both designers agree. Don't share L1 between entities.
- **L1 size:** start at 2048, instrument, adjust.

## Implementation order

1. Add L1 (lru::LruCache) to the encode path — check L1 before L2, populate from L2 hits and computed misses.
2. Add rayon scope for L2 misses — fan out unknown subtrees, pass `&l1` as read-only reference, join, install results.
3. Instrument: L1 hit rate, L1 miss rate, L2 traffic reduction, rayon task count, entity thread utilization.
4. Smoke test 500, then 10k benchmark. Compare to 7.1 c/s baseline.
