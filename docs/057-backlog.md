# 057 Implementation Backlog — L1/L2 Cache + Rayon

## Dependencies

- [ ] Add `rayon` to Cargo.toml
- [ ] Add `lru` already present (used by L2)

## encode.rs — the core change

- [ ] Add `l1: &mut LruCache<ThoughtAST, Vector>` parameter to `encode()`
- [ ] Progressive descent checks L1 before adding to L2 batch
- [ ] L2 hits inserted into L1
- [ ] L2 misses computed in `rayon::scope` — pass `&l1` as read-only ref
- [ ] Rayon tasks: recursive `compute_subtree(ast, &l1, vm, scalar) -> Vector`
  - Check L1 (read-only). Hit → return clone.
  - Miss → compute via Primitives. Return value up.
  - Bundle/Sequential children use `rayon::join` or `par_iter` for parallel fan-out.
- [ ] After scope: insert all computed results into L1
- [ ] batch_set all computed results to L2
- [ ] Document AST-as-value invariant (Beckman condition #1)

## EncodeMetrics — new counters

- [ ] `l1_hits: u64`
- [ ] `l1_misses: u64`
- [ ] `rayon_tasks: u64`

## Program files — L1 creation

- [ ] `market_observer_program.rs` — create `LruCache::new(2048)` at thread start, pass to `encode()` each candle
- [ ] `broker_program.rs` — same
- [ ] `regime_observer_program.rs` — check if it calls encode (it may not — middleware)

## Telemetry emission

- [ ] Market observer: emit `enc_l1_hits`, `enc_l1_misses`, `enc_rayon_tasks`
- [ ] Broker: emit `gate4_enc_l1_hits`, `gate4_enc_l1_misses`, `gate4_enc_rayon_tasks`

## Verification

- [ ] `cargo test --lib` — 283 tests pass
- [ ] `./wat-vm.sh smoke 500` — compare to 7.1 c/s baseline
- [ ] Query DB: L1 hit rate, L2 traffic reduction, entity CPU utilization
- [ ] Memory check: actual RSS vs estimate (~660MB for 33 × 2048 entries)
