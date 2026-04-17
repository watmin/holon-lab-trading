# Ward Backlog

Findings from six wards cast on 2026-04-16. Files targeted:
`encode.rs`, `thought_encoder.rs`, `cache.rs`, `database.rs`, `treasury_program.rs`, `broker_program.rs`, `market_observer_program.rs`, `wat-vm.rs`.

Wat and guide divergence NOT chased — out of sync by design during this refactor arc.

---

## Quick wins — low risk, high clarity

- [ ] **Delete `l1_miss_asts` Vec in `encode.rs`**. Allocated at line 91, passed through `collect_l1_misses` (line 141), written at line 162 with `ast.clone()` per tree node, never read. Pure waste in the hot path. Drop the parameter, drop the Vec, drop the clone.

- [ ] **Rename rayon lies in `EncodeMetrics` (`encode.rs`)**. `ns_rayon` → `ns_compute`, `rayon_tasks` → `forms_computed`. Rayon was removed but the metric names propagated into the DB via `emit_metric` calls in `market_observer_program.rs:236-237` and `broker_program.rs:336-337` as `enc_ns_rayon`, `enc_rayon_tasks`, `gate4_enc_ns_rayon`, `gate4_enc_rayon_tasks`. Rename at source and all three emission sites.

- [ ] **Delete `ns_leaf` metric**. `EncodeMetrics::ns_leaf` (line 55) is defined and emitted as `enc_ns_leaf` / `gate4_enc_ns_leaf` but never written anywhere in `encode.rs`. Always zero. A metric that lies by silence. Drop the field and the two emission sites.

- [ ] **Fix `_db_tx` underscore in `treasury_program.rs`** (line 251). Underscore prefix signals "intentionally unused" but the parameter is used at lines 264 and 343. Rename to `db_tx`.

- [ ] **Fix `rune:forge(dims)` missing dash-reason** at `broker_program.rs:118`. Skill requires `rune:category(term) — reason`. Current rune has no reason after the dash. Either expand or remove.

- [ ] **Fix `database.rs` emit doc** (line 73-76). Doc says `Fn(flush_count, total_rows, total_flush_ns)` but the actual signature is `Fn(&Connection, usize, usize, u64)`. Doc omits `&Connection`.

- [ ] **Remove stale `rune:reap(scaffolding)` on `submit_exit`** at `treasury_program.rs:135`. The rune claims the function is scaffolding but it's actively called at `broker_program.rs:218`. Rune is stale.

- [ ] **Delete `ObsLearn` struct** in `market_observer_program.rs:42-44`. Declared as `pub` but no callers anywhere. `UnconfirmedPrediction` replaced it; the old struct was never removed.

- [ ] **Update stale doc comments**:
  - `broker_program.rs:4` — "Encodes anxiety atoms from active position receipts." No anxiety atoms exist. Replace with current reality (market + regime + portfolio + phase + time rhythms).
  - `wat-vm.rs:11` — "Position observers compose market thoughts with position facts." Renamed to regime observers. Fix the comment.
  - `encode.rs:1-2` — "the ONE way to turn a thought into geometry" — `ThoughtEncoder::encode` is a second path. Either reconcile to one path or update the comment.

---

## Naming schism — the regime/position drift

- [ ] **Rename `position_*` bindings in `wat-vm.rs` to `regime_*`**. Types are already `RegimeObserver` / `regime_observer_program` / `wire_regime_observers`, but bindings and constants still use position: `num_position`, `POSITION_LENSES`, `position_console_handles`, `position_queue_rxs`, `position_cache_pool`, `position_console_pool`, `position_db_pool`. CLAUDE.md declares the vocabulary is **Regime Observer**. Also fix section header comments (lines 186-285).

- [ ] **Update `wat-vm.rs:524-525` comment** referring to "054/055" proposal numbers without explanation.

---

## Dead treasury fields

- [ ] **Remove `TreasuryEvent::Tick.atr`** (line 26). Written via `send_tick(candle, price, atr)` at line 363, destructured with `..` at line 261. Never read. `wat-vm.rs:680` computes `candle.atr_ratio * candle.close` only to fill this dead field. Drop both.

- [ ] **Remove `TreasuryResponse::ExitApproved.position_id`** (line 62). Set at line 220, ignored with `..` at line 148. Write-only.

---

## Braided concerns (sever)

- [ ] **Extract time facts vocabulary**. Same `Bind(Atom("hour"), Circular{hour,24.0})` + day-of-week pattern appears THREE times:
  - `market_observer_program.rs:156-173` (plus nested pair at 164-173)
  - `broker_program.rs:91-98`
  
  The broker re-binds time that the market observer ALREADY embedded inside `market_ast`. Time is being double-counted. Create `vocab/time.rs::time_facts(hour, day) -> Vec<ThoughtAST>`. Call in one place. Decide where time should live — likely only at the outermost bundle (broker), not inside the market AST.

- [ ] **Extract portfolio vocabulary**. `broker_program.rs:50-63` hardcodes min/max/delta_range for `avg-paper-age`, `avg-time-pressure`, `avg-unrealized-residue`, `grace-rate`, `active-positions`. Bounds define what "normal" means — that's vocabulary. Move to `vocab/portfolio.rs::rhythm_asts(snapshots)`. Broker calls it.

- [ ] **Move `direction_from_prediction`** from `broker_program.rs:33-39` to `impl From<&Prediction> for Direction` in `types/enums.rs` or a `domain/prediction.rs` adapter. It's a type-boundary conversion, not broker logic.

- [ ] **Consolidate telemetry construction in `treasury_program.rs`** (lines 275-286, 325-336). Treasury hand-builds `LogEntry::Telemetry { ... }` twice. Other programs use `emit_metric(&mut pending, ...)`. Use the same helper.

- [ ] **Reconcile two encoders**. `encode_local` in `encode.rs:169` and `ThoughtEncoder::encode` in `thought_encoder.rs:229` both walk `ThoughtASTKind` with identical match arms. The tests+incremental path is a second implementation — will drift. Make `ThoughtEncoder::encode` a thin wrapper over `encode_local` with empty L1/L2, OR delete the second path entirely if only tests use it.

---

## Forge — craft issues

- [ ] **Parameterize `EncodeState::new`** (encode.rs:38). Takes no params; `L1_CAPACITY = 16384` is a module const. Different entity types (market observer vs broker) may want different capacities. Make it `EncodeState::new(capacity: NonZeroUsize)`.

- [ ] **Symmetric `set` / `batch_set` semantics in `CacheHandle`** (cache.rs). Currently `set()` is fire-and-forget while `batch_set()` is confirmed. Same abstraction level, different semantics — bug waiting to happen. Either make `set(k,v)` call `batch_set(vec![(k,v)])` or drop `Set` and `CacheRequest::Set` entirely.

- [ ] **Extract broker program phases**. `broker_program.rs:105` is ~270 lines. `treasury_program::handle_request` is the exemplar — compute extracted, program body orchestrates. Extract:
  - `compute_portfolio_snapshot(candle_count, price, receipts, ev) -> PortfolioSnapshot`
  - `resolve_outcomes(&mut Broker, receipts, states, gate_pred, anomaly, labels) -> Vec<Outcome>`
  - `emit_broker_telemetry(pending, slot_idx, candle_count, metrics)`
  
  The program body receives, orchestrates, and shuts down — it does not compute.

- [ ] **Extract market observer program phases** similarly. Same shape as broker — too long, telemetry bloats the body.

- [ ] **`IncrementalBundle` on `MarketObserver`** (domain/market_observer.rs:39). Entire machinery is constructed but never invoked in production. Large latent dead subsystem. Either wire it or delete it. Outside immediate target file list but flagged.

---

## Temper — hot path waste

- [ ] **Hoist `market_rhythm_specs(&lens)`** out of the market observer's `while let` loop (market_observer_program.rs:153). The lens is fixed for the observer's lifetime; the specs are the same every candle. Hoist once.

- [ ] **Fuse passes over `active_receipts`** in `broker_program.rs:154-174`. Three sequential iterations for `avg_age`, `avg_tp`, `avg_unrealized`. One fold returning a 3-tuple.

- [ ] **Fuse passes over `treasury.proposer_records`** at `treasury_program.rs:290-304`. Two iterations for `total_submitted`, `total_survived`. One fold.

- [ ] **Use `Arc<str>` for repeated telemetry strings**. `emit_metric` in `telemetry.rs` takes `&str` params then calls `.to_string()` inside (lines 22-25), allocating each time. Market observer and broker call it ~20 times per candle with the same `namespace`, `id`, `dimensions`. Options:
  - Change `LogEntry::Telemetry` fields from `String` to `Arc<str>` or `Cow<'static, str>`
  - Change `emit_metric` to take `Arc<str>` and clone the Arc
  - Pre-build a template `LogEntry::Telemetry` once per candle, just vary metric_name/value

- [ ] **Move `l1_miss_keys` instead of cloning** at `encode.rs:97`. `batch_get` takes owned `Vec<K>`. Currently clones so the original can be indexed at line 106. Flip: iterate `zip(l1_miss_keys.into_iter())` and pass the Vec by move.

- [ ] **Batch atomic counter updates in cache driver** (cache.rs:263). `hits_inner.fetch_add(1, Relaxed)` per key in a BatchGet — for 50+ keys per batch this is an atomic per key. Accumulate local `hits` / `misses` counts, do ONE `fetch_add(n, Relaxed)` per batch.

- [ ] **Hoist `senders` Vec in database driver** (database.rs:155). Allocated inside the outer loop; hoist and `senders.clear()` per iteration. Same pattern already used for `writes`/`reads` in cache.rs.

- [ ] **Dedupe ack sends in database driver**. If one client sends multiple batches during a single drain pass, the driver acks each. One ack per client per drain iteration is sufficient.

---

## Lower priority notes

- `CacheDriverHandle.name` (cache.rs:94) has `#[allow(dead_code)]` — confessed dead field. Either surface in telemetry or drop.
- `collect_facts` (thought_encoder.rs:433) has no production callers, only tests.
- `extract` (thought_encoder.rs:415) has `rune:reap(scaffolding)` — kept intentionally.
- Metrics thread-local in `encode.rs:62-64` is an algebraic escape. `encode()` returns `Vector` but mutates thread-local state. Worth a `rune:forge(escape) — measured telemetry, not cognition`.

---

## Execution order

1. Quick wins first — ~1-2 hours, no architectural change
2. Naming schism — mechanical rename pass
3. Dead treasury fields — one small refactor
4. Time facts extraction — affects correctness (double-counting)
5. Temper hot path — measurable throughput gains
6. Forge extractions — improves maintainability, not correctness
7. Reconcile two encoders — last, because it touches both layers
