# Ward Backlog — Post-056

Six wards cast on 2026-04-16 after implementing Proposal 056.
Performance first. Correctness second. Dead code third. Naming last.

## Performance — the 298ms bottleneck

### 1. Box<ThoughtAST> deep cloning — 300k+ allocations/candle
**Temper**
Overlapping trigram windows clone shared AST nodes. Each pair clones
two trigrams. Each trigram clones three facts. The market_ast clone
into broker_thought_ast copies the entire market rhythm tree for
each of 22 brokers. Replace `Box<ThoughtAST>` with `Rc<ThoughtAST>`.
Every clone becomes a pointer increment. This addresses 5/7 temper
findings and is the dominant cause of the 298ms encode time.

### 2. market_rhythm_specs rebuilt every candle
**Temper**
`market_rhythm_specs(&lens)` is a pure function of the lens — a
loop invariant. Rebuilt every candle in the market observer loop.
Hoist to before the loop. 652k wasted allocations per observer.

### 3. Hardcoded dims = 10_000
**Forge, Scry**
`rhythm.rs`, `phase.rs`, `broker_program.rs` — the budget computation
uses a literal 10_000 instead of the actual dims. Must flow as a
parameter. Not runed — the datamancer did not inscribe these.

### 4. Triple receipt averaging — fuse to one pass
**Temper**
Three passes over `active_receipts` for portfolio snapshot (avg_age,
avg_tp, avg_unrealized). Fuse to one loop.

### 5. props() called twice per phase record
**Temper**
`phase_rhythm_thought` calls `props()` on record i as current, then
again on record i as previous for record i+1. Pre-compute the array.

### 6. Duplicated budget trim in indicator_rhythm
**Forge, Temper**
Input is trimmed to budget+3 values (line 57). Output pairs are
trimmed to budget (line 116). The second trim is nearly always a
no-op. Remove the redundant check or make it a debug_assert.

## Correctness — spec/impl gaps

### 7. Missing standard_specs — 5 lenses lost indicators
**Scry**
DowVolume, DowCycle, WyckoffEffort, WyckoffPosition use
`encode_standard_facts` in the old path. The rhythm specs have no
equivalent. `since-vol-spike`, `dist-from-high`, `dist-from-low`
are silently dropped. These are window-relative indicators — they
need the window, not just one candle. Must add `standard_specs()`.

### 8. No anomaly filtering between thinkers
**Scry**
The proposal says the regime observer cosines market rhythms against
the market anomaly and passes only anomalous ones. The code passes
everything through. Decision needed: is the regime observer truly
middleware (pass everything) or does it filter? If middleware, update
the proposal. If filter, implement it.

### 9. Anomaly temporal mixing — document the intent
**Forge**
Gate 4 learns from today's anomaly about papers opened N candles ago.
If the gate asks "is NOW bad for holding," this is correct. Document.

## Dead Code

### 10. ObsLearn struct — dead
**Reap**
`market_observer_program.rs` — exported, never imported. Old broker
propagation vestige.

### 11. active_direction on Broker — dead
**Reap**
Written every candle, never read.

### 12. gate_open() — dead in production
**Reap**
Only called from tests. Gate reckoner replaced it.

### 13. market_idx() / regime_idx() — dead in production
**Reap**
Only called from tests. Supporting field `regime_count` also dead.

### 14. Trade atom re-exports — dead
**Reap**
`regime_observer_program.rs` re-exports `compute_trade_atoms` and
`select_trade_atoms`. Never consumed.

### 15. Four unused params on regime_observer_program
**Reap**
`_cache`, `_vm`, `_scalar`, `_noise_floor` — accepted but unused.
The caller allocates pool handles for them.

### 16. Old fact paths dead in production
**Reap, Sever**
`market_lens_facts()`, `regime_lens_facts()` and their 11 vocab
imports — only called by tests. 170 lines of dead production code.

## Naming

### 17. "anxiety atoms" in comments — lies
**Gaze**
`broker_program.rs` lines 5-6, `broker.rs` line 2. The broker uses
portfolio rhythms + noise subspace now. The comments lie.

### 18. "position observer" in wat-vm.rs comments — lies
**Gaze**
Lines 4-5, 187, 530, 546. Code says regime observer. Comments don't.

### 19. regime_facts should be regime_rhythms
**Gaze**
`MarketRegimeChain.regime_facts` carries rhythm ASTs, not facts.
The field name lies.

### 20. PortfolioSnapshot trapped in program file
**Sever**
Domain vocabulary in `broker_program.rs`. Should be in domain or
vocab.

### 21. Broker telemetry says "broker" not "broker-observer"
**Scry**
Cosmetic. The proposal says broker-observer.
