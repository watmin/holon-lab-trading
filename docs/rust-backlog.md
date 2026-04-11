# Rust Backlog — 2026-04-11 (updated)

Five wards cast on the Rust. 28 of 30 resolved. 2 deferred.

## Bugs — ALL RESOLVED

- [x] `accumulated_misses` → misses flow to encoder service via .set()
- [x] `window_sampler.sample()` → each observer samples its own window
- [x] `current_price()` → `last_close()`, panics on empty, caught real ordering bug
- [x] `fund_proposals` → dead arithmetic removed
- [x] `treasury` dummy origin → panics on invariant violation
- [x] `exit_count: 0` → assert in constructor
- [x] BONUS: placeholder poison eliminated (into_iter, no std::mem::replace)
- [x] BONUS: step 1 ordering bug (settle before first tick)

## Lies — ALL RESOLVED

- [x] `observers_updated` → counted, not hardcoded
- [x] `win_rate` → `grace_pct` (honest name for weighted ratio)
- [x] `enterprise.rs:1` doc → describes the module, not the binary
- [x] `encoder_service.rs:9` doc → Select::ready(), not sleep
- [x] `empty_accums` → TODO comment makes cascade skip visible
- [x] BONUS: treasury test Vector import restored

## Dead code — ALL RESOLVED

- [x] enterprise.rs: on_candle, on_candle_batch, 6 step_* methods removed (370 lines)
- [x] Test-only items marked #[cfg(test)]: deposit, TradeId::new, Levels::new, register_atom
- [x] Kept: Prediction::Continuous (enum completeness), ProposalSubmitted (matched in log_service)

## Performance — ALL RESOLVED

- [x] `to_f64` → extracted to lib.rs, single copy
- [x] Double `to_f64` → single conversion shared in observe
- [x] Exit facts 24x → pre-computed M=4 before grid
- [x] Exit facts step 3c → reuses grid's exit_vecs
- [x] `edge()` → cached on broker, updated in propagate
- [x] Window clone → documented as necessary (VecDeque → Vec for threads)

## Structure — 6/8 RESOLVED, 2 DEFERRED

- [x] Duplicated four-step loop → reaped in dead code pass
- [x] Duplicated `to_f64` → extracted in perf pass
- [x] `_pub` wrappers → renamed to real public functions
- [x] `ctx_scalar_encoder_placeholder` → WHY + TODO documented
- [x] `recalib = 500` → confirmed test-only
- [x] `approximate_optimal_distances` → WHY comment added
- [ ] **DEFERRED:** `exit_observer` reaches into broker internals for cascade — architectural
- [ ] **DEFERRED:** Bare f64 for Price, Amount, Distance — newtypes across many files
