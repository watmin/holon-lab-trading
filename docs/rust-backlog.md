# Rust Backlog — 2026-04-11

Five wards cast on the Rust. Findings from sever, reap, temper, gaze, forge.

## Bugs

- [ ] `accumulated_misses` never inserted — ctx cache never warms (bin/enterprise.rs:810)
- [ ] `window_sampler.sample()` never called — observers use full window (market_observer.rs:28)
- [ ] `current_price()` returns 0.0 on empty window, propagates to trade entry (post.rs:93)
- [ ] `fund_proposals` dead arithmetic — reserve always equals avail (treasury.rs:114)
- [ ] `treasury` fabricates dummy TradeOrigin on missing origin (treasury.rs:208)
- [ ] `exit_count: 0` causes divide-by-zero in broker (broker.rs:65)

## Lies

- [ ] `observers_updated: 2` hardcoded — actual count varies (enterprise.rs:407, post.rs:336)
- [ ] `win_rate` is value-weighted ratio, not trade count (bin/enterprise.rs:466)
- [ ] `enterprise.rs:1` doc — "Six primitives" belongs on binary, not module
- [ ] `encoder_service.rs:9` doc — says "sleep" but uses Select::ready()
- [ ] `empty_accums` workaround — cascade silently skips accumulator tier (bin/enterprise.rs:959)

## Dead code

- [ ] `enterprise.rs` on_candle + on_candle_batch + all step_* — binary reimplements via pipes
- [ ] `Prediction::Continuous` variant — only in tests (enums.rs:42)
- [ ] `LogEntry::ProposalSubmitted` — never emitted in production (log_entry.rs:14)
- [ ] `Treasury::deposit()` — only in tests (treasury.rs:60)
- [ ] `TradeId::new()` — only in tests (newtypes.rs:11)
- [ ] `Levels::new()` — only in tests (distances.rs:40)
- [ ] `ThoughtEncoder::register_atom()` — only in tests (thought_encoder.rs:110)

## Performance

- [ ] `to_f64` allocates 80KB per call, 36x/candle — 2.8MB heap (broker.rs:21, market_observer.rs:15)
- [ ] Double `to_f64` in observe + strip_noise (market_observer.rs:97+101)
- [ ] Exit facts recomputed 24x in grid — only 4 unique (bin/enterprise.rs:940)
- [ ] Exit facts recomputed AGAIN in step 3c (bin/enterprise.rs:1062)
- [ ] `edge()` creates zero vec + predict every call (broker.rs:147)
- [ ] Window clone per candle — up to 2016 Candles (bin/enterprise.rs:897)

## Structure

- [ ] Duplicated four-step loop — binary and enterprise.rs diverge (sever)
- [ ] `exit_observer` reaches into broker internals for cascade (sever — exit_observer.rs:70)
- [ ] Duplicated `to_f64` in broker.rs and market_observer.rs (sever)
- [ ] `_pub` wrappers expose post internals to binary (sever — post.rs:343-452)
- [ ] `ctx_scalar_encoder_placeholder` static OnceLock hack (sever, forge — post.rs:452)
- [ ] `recalib = 500` hardcoded twice (forge — enterprise.rs:253, 316)
- [ ] Bare f64 for Price, Amount, Distance — no newtypes (forge)
- [ ] `approximate_optimal_distances` — no WHY on 0.5 heuristic (gaze — broker.rs:315)

## Priority

1. Bugs — fix what's broken
2. Lies — fix what misleads
3. Dead code — reap what's dead
4. Performance — temper the hot path
5. Structure — forge the craft
