# Backlog — Ward Findings + Next Phases

Five wards scanned 81 Rust files. Leaves to root. Session: 2026-04-13.

## Critical — correctness

- [x] **Encoding divergence (sever).** REAPED. ToAst trait and all
  impls deleted. 709 lines. One encoding path remains. No divergence.

- [x] **`close_final` fixed (forge).** PhaseState now tracks
  `last_close` every candle. `close_final` stores the real value.

- [x] **`compute_portfolio_biography` fixed (forge).** Returns
  `(Vec<ThoughtAST>, usize)`. Values up, not mutations down.

- [x] **`position_lens_facts` differentiates (gaze).** The lens
  IS the factory. Core: regime + time. Full: regime + time + phase.
  The match statement controls what each observer sees.

## Dead code — to reap

- [x] **RollingPercentile.** REAPED. Entire struct deleted.

- [x] **3 exit vocab modules.** REAPED. volatility.rs, structure.rs,
  timing.rs deleted. Never wired into any lens.

- [x] **Lying comment in lens.rs.** FIXED. Now says "ichimoku,
  stochastic removed" — fibonacci IS used by WyckoffPosition.
  (ichimoku/stochastic were never imported in lens.rs — the comment
  was the only dead part.)

- [x] **4 broker vocab modules.** REAPED. derived.rs, input.rs,
  opinions.rs, self_assessment.rs deleted. Entire broker vocab
  directory removed — nothing imported from it.

- [x] **ToAst trait.** REAPED with encoding divergence fix above.

- [x] **Generic `cache()` + `CacheHandle`.** Gated behind
  `#[cfg(test)]`. Tests preserved.

- [x] **`ThoughtAST::compress()`.** REAPED. Removed entirely.

- [x] **`ObserveResult::misses`.** REAPED. Field removed from
  struct, parameter removed from `observe()`, call sites updated.

- [x] **`ThoughtEncoder::vm()` and `scalar_encoder()`.** REAPED.
  Dead public accessors removed.

- [x] **`_cp` binding in broker.rs.** REAPED. Line removed.
  Parameter prefixed with underscore.

- [x] **Stale test in lens.rs.** FIXED. `test_position_lens_facts_variants`
  now asserts Core=10, Full=13 (was asserting Core=13, pre-existing bug).

## Performance — to temper

- [ ] **Window slice `.to_vec()`.** Clones up to 2016 Candles
  per observer per candle. Fix: pass `&input.window[start..]`
  directly. High priority.

- [ ] **7 `to_vec()` in indicator bank tick.** Ring buffer to
  Vec allocation per candle. Fix: reusable scratch buffer on
  IndicatorBank. High priority.

- [ ] **`position_lens_facts()` called 11x.** Same candle, same
  lens, identical result across all 11 slots. Fix: hoist above
  slot loop. High priority.

- [ ] **`compute_trade_atoms()` per active paper.** Position
  observer only uses the latest TradeUpdate. Fix: send one per
  broker, not one per paper. High priority.

- [ ] **Double extraction encoding.** Position observer encodes
  market facts twice (for anomaly and raw extraction). Fix:
  encode once, cosine twice. Medium.

- [ ] **Phase history clone every candle.** `history_snapshot()`
  clones even when unchanged. Fix: Arc with generation counter.
  Medium.

- [ ] **`to_edn()` every candle for all observers.** The thought
  logging. 7.2M string constructions across a full run. Accept
  for now — being blind is being incapable. Revisit when perf
  matters more than diagnostics.

- [ ] **Multiple phase_history scans in portfolio biography.**
  Fuse valley/peak/regularity into one pass. Medium.

- [ ] **Invariant telemetry string `dims`.** Hoist above loop.
  Low.

- [ ] **Redundant `collect_facts()` for snapshot count.** Use
  `slot_facts.len()` instead of re-walking AST. Low.

## Structural — to sever

- [ ] **`compute_portfolio_biography` inline.** 148 lines of
  vocabulary in broker_program.rs. Move to
  `src/vocab/broker/portfolio.rs`.

- [ ] **`compute_trade_atoms` inline.** 96 lines of vocabulary
  in position_observer_program.rs. Move to
  `src/vocab/exit/trade_atoms.rs`.

## Naming — gaze fixes

- [ ] **Stale test names.** `test_exit_lens_display` and
  `test_exit_lens_equality` test PositionLens, not ExitLens.

- [ ] **Stale comment.** rolling_percentile.rs references
  "pivot tracker" — replaced by PhaseState.

- [ ] **`dims` shadowing.** Telemetry dimensions string shadows
  vector dimensionality in market_observer_program,
  position_observer_program, broker_program. Rename to
  `telemetry_dims` or `metric_dims`.

- [ ] **`atr_r` mumbles.** Should be `atr_ratio` on Candle struct.

- [ ] **`compute_portfolio_biography` claims purity but mutates.**
  Rename or restructure (overlaps with critical #3).

## Next phases (from prior session)

- [ ] **Phase 5: Treasury.** The last program. Receives proposals,
  funds proven brokers, manages capital. The accumulation model.

- [ ] **Phase 6: Measurement.** 100k benchmark. Discriminant
  decode — which atoms predict? The glass box opens fully.

- [ ] **Smoothing tuning.** 1.0 ATR produces 3-6 candle phases.
  Measure phase rates per regime. The data decides.

- [ ] **`approximate_optimal_distances`.** The function that
  admits it's an approximation. Replace with full sweep per
  Proposal 025.

## Principles

- The main thread is ONLY a kernel for programs.
- Papers never stop (043).
- The position observer observes the position (050).
- The phase labeler is ground truth on the indicator bank (049).
- The Sequential encodes order. ABC ≠ CBA (044).
- Every node checks the cache. No exceptions.
- The closure is the seal. The encoder is consumed.
- The ThoughtAST has no helpers. The enum variant IS the form.
- Being blind is being incapable. Log everything.
- Leaves to root. Always.
- The database is the debugger.
- Commit and push often.
- Measure, don't speculate.
