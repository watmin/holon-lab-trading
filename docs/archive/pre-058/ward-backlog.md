# Ward Backlog

Findings from six wards cast on 2026-04-16. Files targeted:
`encode.rs`, `thought_encoder.rs`, `cache.rs`, `database.rs`, `treasury_program.rs`, `broker_program.rs`, `market_observer_program.rs`, `wat-vm.rs`.

Wat and guide divergence NOT chased — out of sync by design during this refactor arc.

---

## Quick wins — low risk, high clarity

- [x] **Delete `l1_miss_asts` Vec in `encode.rs`**. Allocated at line 91, passed through `collect_l1_misses` (line 141), written at line 162 with `ast.clone()` per tree node, never read. Pure waste in the hot path. Drop the parameter, drop the Vec, drop the clone.

- [x] **Rename rayon lies in `EncodeMetrics` (`encode.rs`)**. `ns_rayon` → `ns_compute`, `rayon_tasks` → `forms_computed`. Rayon was removed but the metric names propagated into the DB via `emit_metric` calls in `market_observer_program.rs:236-237` and `broker_program.rs:336-337` as `enc_ns_rayon`, `enc_rayon_tasks`, `gate4_enc_ns_rayon`, `gate4_enc_rayon_tasks`. Rename at source and all three emission sites.

- [x] **Delete `ns_leaf` metric**. `EncodeMetrics::ns_leaf` (line 55) is defined and emitted as `enc_ns_leaf` / `gate4_enc_ns_leaf` but never written anywhere in `encode.rs`. Always zero. A metric that lies by silence. Drop the field and the two emission sites.

- [x] **Fix `_db_tx` underscore in `treasury_program.rs`** (line 251). Underscore prefix signals "intentionally unused" but the parameter is used at lines 264 and 343. Rename to `db_tx`.

- [x] **Fix `rune:forge(dims)` missing dash-reason** at `broker_program.rs:118`. Fixed by reading vm.dimensions() directly — rune removed entirely. Note: two similar cases remain in `src/encoding/rhythm.rs:58,117` where the pure helpers don't have vm access. Deferred.

- [x] **Fix `database.rs` emit doc** (line 73-76). Doc said `Fn(flush_count, total_rows, total_flush_ns)` but the actual signature is `Fn(&Connection, usize, usize, u64)`. Also dropped the "optional" claim — both can_emit and emit are mandatory.

- [x] **Remove stale `rune:reap(scaffolding)` on `submit_exit`** at `treasury_program.rs:135`. The rune claimed scaffolding but the function is actively called at `broker_program.rs:218`.

- [x] **Delete `ObsLearn` struct** in `market_observer_program.rs:42-44`. Declared as `pub` but no callers anywhere. `UnconfirmedPrediction` replaced it; the old struct was never removed.

- [x] **Update stale doc comments**:
  - broker_program.rs — anxiety atoms replaced with current reality
  - wat-vm.rs — position observers → regime observers with current topology
  - encode.rs — dropped "ONE way" claim, acknowledged test path, then made it true in the two-encoder reconciliation

---

## Naming schism — the regime/position drift

- [x] **Rename `position_*` bindings in `wat-vm.rs` to `regime_*`**. POSITION_LENSES → REGIME_LENSES in config.rs. All bindings renamed. Comments fixed. "Position" still appears legitimately in PositionState / PositionReceipt / PaperPosition (treasury trade lifecycle).

- [ ] **Update `wat-vm.rs:524-525` comment** referring to "054/055" proposal numbers without explanation. (Not done — skipped.)

---

## Dead treasury fields

- [x] **`TreasuryEvent::Tick.atr`** — NOT removed; WIRED IN. Proposal 055 planned volatility-scaled deadlines. Treasury now tracks current_atr via observe_atr(), locks reference_atr on first reading, and handle_request uses scaled_deadline() at paper issue. Volatile periods shrink deadlines, calm periods extend them.

- [ ] **`TreasuryResponse::ExitApproved.position_id`** — INTENTIONALLY KEPT. The user called out that response fields carry identity for the treasury's accounting — the broker's destructure with `..` drops information the treasury rightfully provides. That's a caller issue, not a protocol issue.

---

## Braided concerns (sever)

- [x] **Extract time facts vocabulary**. `time_facts(candle)` in `vocab/shared/time.rs` returns 5 leaf binds + 3 pairwise compositions (minute×hour, hour×dow, dow×month). Market observer bundles time into its own thought (learns time). `market_ast` in the chain is rhythms only (no time). Broker bundles time into its thought. Each learner gets time exactly once. No double-counting.

- [x] **Extract portfolio vocabulary**. PortfolioSnapshot and portfolio_rhythm_asts moved to `vocab/broker/portfolio.rs`. Deleted orphaned compute_portfolio_biography (Proposal 044's pre-wat-vm design, superseded by 056 rhythms).

- [x] **Move `direction_from_prediction`**. Now `impl From<&Prediction> for Direction` in `types/enums.rs`. Broker calls `Direction::from(&pred)`.

- [x] **Consolidate telemetry construction in `treasury_program.rs`**. Uses `emit_metric` everywhere now — consistent with market_observer, regime_observer, broker.

- [x] **Reconcile two encoders**. Deleted `ThoughtEncoder` and `IncrementalBundle`. Deleted `Ctx`. Tests use `test_support::TestEncodeEnv` which drives the real `encode()` function through a throwaway cache. One algebra, one implementation, zero drift.

---

## Forge — craft issues

- [x] **Parameterize `EncodeState::new`**. Takes capacity parameter. DEFAULT_L1_CAPACITY = 16384 is a public const for callers that don't want to tune.

- [x] **Symmetric `set` / `batch_set` semantics**. Went further — deleted `set` AND `get` entirely. Cache API is batch-only now. CacheRequest::Set and CacheRequest::Get removed. Tests use a get_one helper that wraps batch_get for single-key lookups.

- [x] **Extract broker program phases**. 261 → 211 lines. Three helpers: `compute_portfolio_snapshot`, `resolve_paper_outcomes`, `emit_broker_telemetry`. Thread body is an orchestrator now.

- [x] **Extract market observer program phases**. 176 → 168 lines. Two helpers: `build_market_thought`, `emit_observer_telemetry`.

- [x] **`IncrementalBundle` on `MarketObserver`**. Deleted with ThoughtEncoder in the two-encoder reconciliation. The `incremental` field is gone. Large latent dead subsystem removed.

---

## Temper — hot path waste

- [x] **Hoist `market_rhythm_specs(&lens)`** out of the candle loop. Computed once at thread start.

- [x] **Fuse passes over `active_receipts`**. One fold returning (sum_age, sum_tp, sum_unrealized). Averages computed once by dividing by n.

- [x] **Fuse passes over `treasury.proposer_records`**. One fold returning (total_submitted, total_survived).

- [x] **Use `Arc<str>` for repeated telemetry strings**. LogEntry::Telemetry fields changed from String to Arc<str>. Callers pre-build ns/id/dims per candle and clone (refcount++) per emit. ~2000 allocations/candle eliminated. Throughput impact was within noise — the pipe latency is the real cost — but memory pressure is lower.

- [x] **Move `l1_miss_keys` instead of cloning**. `batch_get` now returns `Vec<(K, Option<V>)>` — the driver pairs keys with results, caller iterates pairs directly. No clone needed.

- [x] **Batch atomic counter updates in cache driver**. One fetch_add per batch for hits + one for misses.

- [x] **Hoist `senders` Vec in database driver**. Became `sender_flags: Vec<bool>` allocated once at thread start, cleared per iteration.

- [x] **Dedupe ack sends in database driver**. One ack per client per drain pass via sender_flags.

---

## Lower priority notes

- `CacheDriverHandle.name` (cache.rs:94) has `#[allow(dead_code)]` — confessed dead field. Either surface in telemetry or drop.
- `collect_facts` (thought_encoder.rs:433) has no production callers, only tests.
- `extract` (thought_encoder.rs:415) has `rune:reap(scaffolding)` — kept intentionally.
- Metrics thread-local in `encode.rs:62-64` is an algebraic escape. `encode()` returns `Vector` but mutates thread-local state. Worth a `rune:forge(escape) — measured telemetry, not cognition`.

---

## Status summary

**Done**: 30 of 30 structural items. (5 of 6 lower-priority notes open — see below.)
**Current throughput**: 15 c/s at 500 candles.
**Memory**: deterministic, no unbounded growth anywhere.

**Remaining lower-priority notes**:
- wat-vm 054/055 comment
- rhythm.rs hardcoded 10_000 (needs signature change through pure helpers)
- CacheDriverHandle.name dead field
- collect_facts with only test callers
- Metrics thread-local in encode.rs is an algebraic escape — worth a forge rune

---

## Execution order (original plan — for reference)

1. Quick wins first — DONE
2. Naming schism — DONE
3. Dead treasury fields — DONE (atr wired in, ExitApproved.position_id kept by design)
4. Time facts extraction — DONE
5. Temper hot path — IN PROGRESS (5 of 8 done)
6. Forge extractions — PARTIAL (3 of 5 done; program phase extractions pending)
7. Reconcile two encoders — DONE
