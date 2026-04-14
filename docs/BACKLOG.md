# Backlog — Second Ward Pass

Six wards scanned all Rust files. Post-cleanup. 2026-04-13.

## Findings — to fix

- [x] **16 dead Candle fields (reap).** Removed bb_upper, bb_lower,
  macd, macd_signal, atr, atr_roc_6, atr_roc_12,
  trend_consistency_6/12/24, senkou_span_a/b, tf_1h_close/high/low,
  tf_4h_close/high/low. Dead compute_trend_consistency and
  compute_tf_close helper functions also removed.

- [x] **Double to_f64 conversion (temper).** MarketObserver::observe()
  now converts once and passes &[f64] to both update and
  anomalous_component. Same fix in position_observer_program.rs.

- [x] **Stale doc comment (gaze).** PositionLens::Full now says
  "13 trade atoms (10 original + 3 phase biography)".

- [x] **Scalar accum index-based (forge).** broker.trail_accum and
  broker.stop_accum replace scalar_accums[0] and [1]. Named fields
  throughout broker, config, and broker_program.

- [x] **Vec::remove(0) in position observer (forge).** outcome_window
  and residue_window are now VecDeque with push_back/pop_front.

- [x] **Resolution constructor (forge).** Resolution::from_paper()
  extracts the 15-field construction. Four call sites reduced to
  one-liners.

- [ ] **Levels as bare f64 (forge).** trail_stop and safety_stop
  should be Price, not f64. PaperEntry trail_level and stop_level same.

- [ ] **4 test-only pub functions (reap).** extract(), gate_open(),
  get_oldest_first(), to_levels() — never called in production.
  Gate behind #[cfg(test)] or remove.

- [ ] **4 trade scaffolding structs (reap).** Trade, TradeOrigin,
  Proposal, TreasurySettlement — test-only cluster awaiting treasury.
  Keep for now — treasury is Phase 5.

- [ ] **Cache driver duplication (forge).** Generic cache and
  encoding_cache share ~170 lines of identical driver logic.
  Generic is #[cfg(test)]. Accept or extract shared driver.

## Accepted / runed

- [x] **to_edn() every candle.** rune:temper(intentional). Being
  blind is being incapable.

- [x] **Candle 90+ bare f64 fields (forge).** Conscious tradeoff.
  Newtypes for 90 indicators would be verbose noise. Rune candidate.

- [x] **Telemetry Mutex in rate gate (forge).** Single-threaded.
  Required by Fn trait. Harmless.

- [x] **PhaseState::step 175 lines (forge).** Streaming state machine.
  The mutation IS the function. Tests are thorough.

## Next phases

- [ ] **Phase 5: Treasury.** The last program.
- [ ] **Phase 6: Measurement.** 100k benchmark. Discriminant decode.
- [ ] **Smoothing tuning.** 1.0 ATR → measure phase rates per regime.
- [ ] **approximate_optimal_distances.** Replace with full sweep.

## Principles

- The main thread is ONLY a kernel for programs.
- Papers never stop (043).
- The position observer observes the position (050).
- The phase labeler is ground truth on the indicator bank (049).
- The lens IS the factory. Core lean, Full rich.
- The Sequential encodes order. ABC ≠ CBA (044).
- Every node checks the cache. No exceptions.
- The closure is the seal. The encoder is consumed.
- The ThoughtAST has no helpers. The enum variant IS the form.
- Being blind is being incapable. Log everything.
- Leaves to root. Always.
- The database is the debugger.
- Commit and push often. Smoke test after every change.
- Measure, don't speculate.
