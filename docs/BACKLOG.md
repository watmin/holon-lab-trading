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

- [x] **Window slice `.to_vec()`.** FIXED. Pass `&input.window[start..]`
  directly — `market_lens_facts` already takes `&[Candle]`. Eliminates
  up to 2016 deep Candle clones per observer per candle.

- [x] **7 `to_vec()` in indicator bank tick.** FIXED. Added
  `fill_vec(&mut buf)` to RingBuffer. Scratch buffer on IndicatorBank
  via `std::mem::take` pattern. Free functions take `&[f64]` slices.
  One `to_vec` remains for divergence (needs two buffers simultaneously).

- [x] **`position_lens_facts()` called 11x.** FIXED. Hoisted above
  slot loop — computed once from first slot's candle, cloned into
  each slot's fact collection. 10x fewer lens+self-assessment calls.

- [x] **`compute_trade_atoms()` per active paper.** FIXED. Send one
  TradeUpdate per broker per candle (last active paper only). Position
  observer drains and keeps the last anyway.

- [x] **Double extraction encoding.** FIXED. Pre-encode all market
  fact ASTs into vectors once, then two cosine passes (anomaly + raw).
  Eliminates redundant cache round-trips on the second extraction.

- [x] **Phase history clone every candle.** FIXED. Generation counter
  on PhaseState, incremented in close_phase. IndicatorBank caches the
  snapshot and only re-clones when generation changes (~every 6 candles).

- [ ] **`to_edn()` every candle for all observers.** The thought
  logging. 7.2M string constructions across a full run. Accept
  for now — being blind is being incapable. Revisit when perf
  matters more than diagnostics.

- [x] **Multiple phase_history scans in portfolio biography.**
  FIXED. Fused into single pass: valleys, peaks, durations, duration
  stats, and favorable entry records collected in one iteration.

- [x] **Invariant telemetry string `dims`.** Renamed to metric_dims
  (done with dims shadowing fix).

- [x] **Redundant `collect_facts()` for snapshot count.** FIXED.
  Use `slot_facts.len()` before bundling instead of re-walking AST.

## Structural — to sever

- [x] **`compute_portfolio_biography` inline.** MOVED to
  `src/vocab/broker/portfolio.rs`. Broker vocab directory recreated.

- [x] **`compute_trade_atoms` inline.** MOVED to
  `src/vocab/exit/trade_atoms.rs`. Re-exported from position_observer_program
  for backward compatibility.

## Naming — gaze fixes

- [x] **Stale test names.** FIXED. Renamed to
  `test_position_lens_display` and `test_position_lens_equality`.

- [x] **Stale comment.** rolling_percentile.rs deleted entirely.

- [x] **`dims` shadowing.** FIXED. Renamed to `metric_dims` in
  market_observer_program, position_observer_program, broker_program.

- [x] **`atr_r` mumbles.** FIXED. Renamed to `atr_ratio` across
  candle.rs, indicator_bank.rs, and momentum.rs.

- [x] **`compute_portfolio_biography` claims purity but mutates.**
  Fixed in critical #3 — returns values now.

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
