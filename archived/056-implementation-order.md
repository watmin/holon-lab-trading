# 056 Implementation Order

Leaves to root. Each step builds on the previous. Test at each step.

## Phase 1: Encoding Foundation

### 1. ThoughtAST::Thermometer variant
Add `Thermometer { value: f64, min: f64, max: f64 }` to ThoughtAST enum.
The encode.rs walker produces a thermometer vector via holon-rs
`ScalarMode::Thermometer`. The cache handles it like any other node.

**Files:** `encoding/thought_encoder.rs`, `encoding/encode.rs`
**Test:** encode a Thermometer AST, verify gradient survives bind.

### 2. indicator_rhythm function
The generic function from the proposal. Takes a window of candles,
an atom name, an extractor, bounds, and dims. Returns one Vector.
Thermometer + delta for continuous. Circular variant for periodic.
Atom wraps the whole rhythm.

**Files:** new `encoding/rhythm.rs`
**Test:** port `prove_indicator_rhythm.rs` to use the production function.

## Phase 2: Market Observer

### 3. Market observer builds indicator rhythms
Replace single-candle fact encoding with per-indicator rhythms
across the window. The window already exists (window sampler).
Each lens indicator gets `indicator_rhythm()`. Time gets
`circular_rhythm()`. The thought IS the bundle of rhythms.

**Files:** `programs/app/market_observer_program.rs`, `domain/market_observer.rs`
**Test:** 500-candle smoke test. Check DB: rhythm vectors non-zero,
prediction direction varies.

### 4. MarketChain carries rhythms
The chain type changes. Instead of `market_ast: ThoughtAST` (single
candle), it carries the rhythm bundle as a Vector. The anomaly and
raw vectors are produced from the rhythm, not from a single-candle
encoding.

**Files:** `programs/chain.rs`, `programs/app/market_observer_program.rs`
**Test:** compile. The position observer receives the new chain shape.

## Phase 3: Regime Observer

### 5. Rename position observer → regime observer
File renames. Struct renames. Import renames. Config renames.
Binary wiring renames. Telemetry namespace. Console diagnostics.
No logic changes — pure naming.

**Files:** all files referencing position observer. ~15 files.
**Test:** `cargo test`. Everything compiles. Names are honest.

### 6. Regime observer builds regime rhythms
Same `indicator_rhythm()` function. Regime indicators (kama-er,
choppiness, dfa-alpha, etc.) + circular time. The regime observer
receives the candle window (new — currently receives one chain per
slot). Builds its own rhythms. Bundles with the market rhythms it
receives.

**Files:** `programs/app/position_observer_program.rs` (renamed),
`domain/lens.rs`
**Test:** 500-candle smoke test. Regime rhythms in the chain.

### 7. MarketRegimeChain replaces MarketPositionChain
The chain carries market rhythms + regime rhythms as Vectors.
The broker-observer receives the renamed chain type.

**Files:** `programs/chain.rs`, broker and regime observer programs.
**Test:** compile. The broker receives the new shape.

## Phase 4: Phase Rhythm

### 8. Phase record structural deltas
Update `phase_series_thought` (or replace it) to compute
prior-bundle and prior-same-phase deltas on each record.
Thermometer encoding for all values and deltas. Returns
phase records as encoded Vectors.

**Files:** `vocab/exit/phase.rs`
**Test:** unit test — verify deltas are correct for known sequences.

### 9. Phase rhythm as bundled bigrams of trigrams
Build trigrams from phase record vectors. Build bigram-pairs.
Bundle. Trim to sqrt(dims). Returns one Vector.

**Files:** `vocab/exit/phase.rs` or new `encoding/phase_rhythm.rs`
**Test:** port `prove_rhythm_with_subspace.rs` phase tests.

## Phase 5: Broker-Observer

### 10. Broker portfolio snapshot window
The broker keeps a ring buffer of portfolio snapshots (avg age,
avg time pressure, avg unrealized, grace rate, active count).
One snapshot per candle. The window grows to sqrt(dims) and trims.

**Files:** `programs/app/broker_program.rs`, `domain/broker.rs`
**Test:** verify snapshots accumulate, window trims.

### 11. Broker portfolio rhythms
Apply `indicator_rhythm()` to the portfolio snapshot window.
Five rhythm vectors. Replace the scalar anxiety facts.

**Files:** `programs/app/broker_program.rs`
**Test:** portfolio rhythms non-zero after warmup.

### 12. Broker thought composition
Bundle: market rhythms + regime rhythms + portfolio rhythms +
phase rhythm. One encode. One predict. Gate 4: Hold/Exit.

**Files:** `programs/app/broker_program.rs`
**Test:** 500-candle smoke. Gate reckoner learns. Telemetry shows
gate experience accumulating.

## Phase 6: Noise Subspace

### 13. Broker-observer owns the noise subspace
Add OnlineSubspace to the broker. Train on the composed thought
each candle. Predict from the anomaly, not the raw thought.
The market observer keeps its own subspace for its own reckoner.
The regime observer has no subspace — it's middleware.

**Files:** `domain/broker.rs`, `programs/app/broker_program.rs`
**Test:** 10k benchmark. Residuals in telemetry. Grace rate improves.

## Phase 7: Cleanup

### 14. Remove Sequential AST usage from phase encoding
The old `phase_series_thought` returns Sequential. Replace with
the phase rhythm Vector. Remove Sequential from the position facts
chain if no other consumer uses it.

**Files:** `vocab/exit/phase.rs`, `domain/lens.rs`
**Test:** `cargo test`. No Sequential in the phase path.

### 15. Remove stale position observer references
Grep for any remaining "position observer" strings in comments,
docs, telemetry. Clean them.

**Files:** scattered.
**Test:** `grep -ri "position.observer" src/` returns nothing.

### 16. Update CLAUDE.md
Architecture section reflects 056: market observer, regime observer,
broker-observer. Indicator rhythms. Thermometer encoding.

**Files:** `CLAUDE.md`
