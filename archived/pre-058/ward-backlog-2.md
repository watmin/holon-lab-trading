# Ward Backlog 2 — Whole-tree scan

Six wards cast on all 77 Rust source files. Findings triaged below.

---

## Critical — real bug

- [ ] **`encode.rs:132` — `l1_hits` metric clobbered.** After correctly incrementing per-hit in `collect_l1_misses` and `encode_local`, line 132 overwrites the counter with `state.l1_cache.len()`. Every dashboard reading `enc_l1_hits` / `gate4_enc_l1_hits` is showing cache size, not hits. Remove the assignment. (Optionally emit a separate `enc_l1_size` metric.)

- [ ] **`wat-vm.rs:489` — `hit_rate` emitted as `"Count"`.** It's a ratio. Use `"Percent"` or `"Ratio"`.

---

## Reap — dead code (~2000 lines)

Order: delete inner, then callers, watching build pass after each wave.

### Wave 1: the dead trade lineage
- [ ] `src/trades/proposal.rs` — `Proposal` only used by its own tests
- [ ] `src/trades/trade.rs` — `Trade` only used by `settlement.rs` (also dead)
- [ ] `src/trades/settlement.rs` — `TreasurySettlement` only used by own tests
- [ ] `src/trades/trade_origin.rs` — `TradeOrigin` only used by own tests
- [ ] Dependent dead enum variants: `TradePhase` (Runner/SettledViolence/SettledGrace never constructed), `Prediction::Continuous` (never constructed), `Levels::new` (test-only marked in doc)

### Wave 2: the dead vocab path
- [ ] `src/vocab/exit/trade_atoms.rs` — `compute_trade_atoms` / `select_trade_atoms`
- [ ] `src/programs/app/regime_observer_program.rs:34` — stale `pub use` re-export
- [ ] `src/trades/paper_entry.rs` — `PaperEntry` only consumed by trade_atoms.rs (dead)
- [ ] `src/vocab/exit/time.rs` — duplicates `shared/time.rs`, only reached from dead lens path
- [ ] `src/domain/lens.rs` — `market_lens_facts` (lines 43-162) + `regime_lens_facts` (lines 168-295) + 13 `encode_*_facts` calls they drive
- [ ] After those go: every `encode_*_facts` function in `src/vocab/market/*.rs` and `src/vocab/exit/regime.rs` with zero non-test callers

### Wave 3: test-only pub items in main modules
- [ ] `src/domain/simulation.rs` — `simulate_trail`, `simulate_stop`, `best_distance`, `compute_optimal_distances` all `pub`, zero production callers
- [ ] `src/learning/scalar_accumulator.rs` — `ScalarAccumulator` only tested in isolation
- [ ] `src/services/queue.rs:70` — `queue_unbounded` only used by tests; move to `#[cfg(test)]` or delete
- [ ] `src/domain/broker.rs` — `gate_open()`, `market_idx()`, `regime_idx()` — test-only helpers
- [ ] `src/domain/treasury.rs` — `get_real_position`, `get_record` — test-only
- [ ] `src/programs/stdlib/cache.rs:73` — `CacheDriverHandle.name` with `#[allow(dead_code)]` — drop it

### Wave 4: write-only struct fields
- [ ] `MarketChain.{encode_count, market_raw, market_anomaly, edge}` — broker never reads these
- [ ] `MarketRegimeChain.{encode_count, market_raw, market_anomaly, market_edge}` — same cascade
- [ ] `Broker.active_direction` — written at broker_program:254, never read
- [ ] `ObserveResult.raw_thought` — read only to populate the dead `MarketChain.market_raw`
- [ ] `BrokerCandleMetrics.conviction` — reserved-for-future, not emitted

### Wave 5: dead parameters
- [ ] `resolve_paper_outcomes(treasury, price)` in broker — discarded via `let _ = (treasury, price);`
- [ ] `check_engram_gate(_recalib_interval)` — underscore prefix, unused

---

## Sever — braided/duplicated encoding

- [ ] **~40 sites inline `Bind(Atom("name"), Log|Linear|Circular { value })`.** `scaled_linear` helper exists for Linear; no equivalent for Log/Circular. Add `atom_log(name, value)`, `atom_linear(name, value, scale)`, `atom_circular(name, value, period)` helpers. Promote the private `bind/atom/circ` from `vocab/shared/time.rs:18-31` to shared module. Touches: trade_atoms, oscillators, momentum, flow, ichimoku, standard, price_action, exit/regime, exit/time, plus 8 other vocab modules.

- [ ] **Bigram-of-trigrams duplicated** in `rhythm.rs:88-110` and `vocab/exit/phase.rs:134-146`. Extract `bigrams_of_trigrams(records: &[ThoughtAST], budget: usize) -> ThoughtAST` into `rhythm.rs`. `phase_rhythm_thought` calls it.

- [ ] **Hardcoded `10_000.sqrt()` budget** at `rhythm.rs:58`, `rhythm.rs:117`, `phase.rs:126`. Thread `dims` through these pure functions. Two of three are already runed.

---

## Forge — craft issues

### Types that enforce (newtype expansion)

- [ ] **Treasury arithmetic uses bare `f64`.** `entry_fee`, `exit_fee`, `atr`, `reference_atr`, `price`, `current_price`, `residue` all `f64`. `Price` / `Amount` newtypes exist in `newtypes.rs` and are used elsewhere. Convert at the mailbox boundary, keep internal arithmetic newtyped.
- [ ] **`TreasuryEvent::Tick { price, atr }` is bare.** Wire protocol strips type safety.
- [ ] **`submit_exit(paper_id, current_price: f64)`** — bare.
- [ ] **Raw `u64`/`usize` IDs everywhere.** `PaperId`, `PositionId`, `ClientId`, `BrokerSlot` would prevent slot-as-paper mistakes. `batch_get_paper_states(Vec<u64>)` accepts anything u64.
- [ ] **`Prediction::Discrete { scores: Vec<(String, f64)> }`** — direction labels as String. `Label` enum exists upstream.
- [ ] **`from_asset: String`, `to_asset: String`** through TreasuryRequest — `.to_string()` allocations per request. `AssetSymbol(Arc<str>)` or intern at wiring time.

### Values, not places

- [ ] **`thread_local! METRICS` in encode.rs.** `encode()` claims to return `Vector` but mutates per-thread state. Change to return `(Vector, EncodeMetrics)` — callers collect the tuple. Eliminates the `take_encode_metrics()` dance.
- [ ] **Treasury volatility state** (`current_atr`, `reference_atr`). The caller can't tell that deadline scaling is in play. Have the tick handler compute the scale and pass it into `issue_paper(deadline: Deadline)` directly.

### Missing abstractions

- [ ] **MetricEmitter helper.** `emit_broker_telemetry` has 26 calls, each repeating `ns.clone(), id.clone(), dims.clone()`. A `struct MetricEmitter { pending, ns, id, dims, ts }` with `.emit(name, value, unit)` inlines the clones at one point. Same pattern in `market_observer_program` (19 calls) and `regime_observer_program` (5 calls).
- [ ] **`RegimeObserver` is a 1-field struct** `{ lens: RegimeLens }` with no behavior. Delete it; `regime_observer_program` takes `RegimeLens`.
- [ ] **`TreasuryTickSender`** wraps `QueueSender<TreasuryEvent>` with one method. Main loop can hold the QueueSender directly.
- [ ] **`simulation::best_distance`** takes `fn` pointer despite exactly two call sites (`simulate_trail`, `simulate_stop`). Inline into `best_distance_trail` / `best_distance_stop`. (May be moot once simulation.rs is reaped.)

### Composition

- [ ] **Broker and market observer program loops** still ~200 lines each with 8-param signatures. Can't unit-test without threads + queues + caches. Gate 4's "predict-from-anomaly" and per-candle telemetry bundle could be pure-fn extractions.

---

## Temper — hot path waste

### High-heat (per candle × per observer)

- [ ] **Vocab atom allocations.** `vec![ ... ThoughtAST::new(ThoughtASTKind::Atom("name".into())) ... ]` in every vocab module × per candle × per observer. `OnceLock<Arc<ThoughtAST>>` per atom name, clone the Arc. 12 modules × ~6 atoms × N candles × M observers.
- [ ] **`standard.rs` — 4 passes over candle window.** Fuse the RSI/vol/move/highlow scans into one.
- [ ] **`regime_facts.clone()` per broker slot** in `regime_observer_program.rs:116`. Wrap in `Arc<Vec<ThoughtAST>>`.
- [ ] **`children()` deep-clones via Arc deref.** Change to `children_refs() -> Vec<&ThoughtAST>`.
- [ ] **`rhythm.rs` / `phase.rs` `pairs[start..].to_vec()`** — allocate + move. Use `pairs.drain(..start); pairs` or `split_off`.
- [ ] **`budget` recomputed twice** in `rhythm.rs:58` and `:117` (same function). Compute once.

### Lower-heat

- [ ] **Hoist per-candle `Arc::from("market-observer")`** above the loop in market_observer and broker and regime programs. Build once, clone per candle.
- [ ] **Reckoner double-predict** in market_observer `resolve()` — calls `predict(thought)` after `observe` on the same vector.
- [ ] **`ThoughtASTKind::Bundle` encoding** allocates `Vec<Vector>` then `Vec<&Vector>` refs. Use `Vec::with_capacity(children.len())` to avoid growth reallocations.
- [ ] **Treasury `check_deadlines`** — paper and real-position scans are structurally identical. Generic helper.
- [ ] **`RingBuffer::max/min/sum`** compute mod-indexed `get(i)` per element. Expose `two_slices() -> (&[f64], &[f64])` for SIMD-friendly iteration.

---

## Gaze — level 1 lies

- [ ] `src/types/log_entry.rs:3, 13` — "Seven variants" — actually 13
- [ ] `src/trades/paper_entry.rs:22` — "Proposal 026: position learns from position_thought" — stale "position" terminology (dead file anyway)
- [ ] `src/domain/lens.rs:168` — comment "Collect position vocab facts" — function is `regime_lens_facts`
- [ ] `src/domain/treasury.rs:326-327` — `resolve_grace` doc claims "For real positions" but body only touches papers
- [ ] `src/encoding/thought_encoder.rs` — two stacked doc comments on `collect_facts`; first is wrong (says "non-Bundle leaf nodes", function returns Bind nodes)
- [ ] `src/vocab/exit/trade_atoms.rs:113` — "position lens" — stale (file is dead anyway)
- [ ] `src/domain/broker.rs:1-3` — "anxiety atoms" reference — no such atoms
- [ ] `src/domain/broker.rs:23-24` — `expected_value: f64` — doc says grace rate. Rename field to `grace_rate`.
- [ ] `src/domain/market_observer.rs:79-80` — `observe()` doc claims self-grading; self-grading is in the program not on the observer
- [ ] `src/programs/app/treasury_program.rs:182` — `handle_request` doc claims "Pure function" — takes `&mut Treasury` and mutates

## Gaze — level 2 mumbles

- [ ] `src/programs/chain.rs` fields `position_thought` across 4 trade structs (all dead anyway)
- [ ] `src/programs/app/regime_observer_program.rs:28` — `RegimeSlot` doc skips the regime observer from the pipeline description
- [ ] `src/domain/broker.rs:12` — `observer_names` example uses pre-schools vocabulary

## Gaze — math sanity

- [ ] `src/encoding/scale_tracker.rs:7` — "SCALE_COVERAGE = 2.0 ≈ 89% coverage for Gaussian distributions." 2-sigma Gaussian is ~95%. Either the distribution assumption was different or the number is wrong.

---

## Execution suggestion

1. **Fix the l1_hits bug first** — it's a data lie affecting all analysis
2. **Reap wave 1-4** — mechanical, compiler catches misses, 2000 lines lighter
3. **Sever** atom_log/linear/circular helpers — eliminates 40+ duplications
4. **Temper vocab atom allocations** — biggest remaining throughput win
5. **Gaze lies** — cleanup
6. **Forge newtypes** — biggest type-safety win, largest investment
