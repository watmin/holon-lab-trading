# Proposal 029 — Implementation Phases

Backlog for the typed thought pipeline. Each phase proves itself
before the next begins.

## Phase 1: Flat extract + scoping + exit noise subspace (COMPLETE)

- [x] Flat `extract(vec, forms, encoder) → Vec<(ThoughtAST, f64)>` — no hierarchy, no threshold in primitive
- [x] `flatten_leaves(ast) → Vec<ThoughtAST>` helper — collect leaf forms from an AST tree
- [x] Scoping fix: extraction moves INTO N×M grid, each slot extracts from ONE market observer
- [x] Remove pre-computed shared exit vecs — each (mi, ei) slot encodes its own
- [x] Consumer-side noise floor filter: `5.0 / (dims as f64).sqrt()` = 0.05 at D=10,000
- [x] Pass ORIGINAL ThoughtASTs through the filter, not presence-transformed
- [x] Exit observer gains `noise_subspace: OnlineSubspace::new(dims, 8)`
- [x] Exit observer gains `strip_noise()` method
- [x] Exit encoding: update noise subspace, strip, query reckoner on anomaly
- [x] Exit's anomaly (not raw vec) flows to broker thread as exit_thought
- [x] `cargo build --release` clean — 245 tests pass
- [x] Smoke test 500 candles — no panics
- [x] 10k benchmark — ALL DECILES POSITIVE. Grace/Violence 49/51. 27/s throughput.

Results at 10k:
```
Decile  residue%  grace%
  1      +0.24    65.3
  2      +0.29    60.5
  3      +1.04    44.4
  4      +0.63    39.7
  5      +0.73    48.5
  6      +0.69    52.5
  7      +0.09    36.7
  8      +0.28    43.5
  9      +0.26    44.9
  10     +0.09    43.4
```
Observers: regime 73.9%, momentum 69.6%, generalist 63.2%

## Phase 2: Typed vocabulary structs (COMPLETE)

- [x] `ToAst` trait in `thought_encoder.rs`: `to_ast()` + `forms()`
- [x] 13 market vocabulary structs: MomentumThought, RegimeThought, OscillatorsThought, FlowThought, PersistenceThought, PriceActionThought, IchimokuThought, KeltnerThought, StochasticThought, FibonacciThought, DivergenceThought, TimeframeThought, StandardThought
- [x] 6 exit vocabulary structs: ExitVolatilityThought, ExitStructureThought, ExitTimingThought, ExitRegimeThought, ExitTimeThought, ExitSelfAssessmentThought
- [x] Existing `encode_*_facts()` functions delegate to structs — all callers unchanged
- [x] 22 integration tests proving struct `forms()` matches original function output
- [x] `cargo build --release` clean — 267 tests pass

## Phase 3: Broker extraction (COMPLETE)

- [x] Broker receives `(exit-ast, exit-anomaly)` pair alongside market pair
- [x] Broker extracts from BOTH stages independently
- [x] Broker's full thought: `broker-self + extract(market) + extract(exit)`
- [x] Broker typed struct (BrokerSelfAssessmentThought — already implemented in Phase 2)
- [ ] Compiler enforces the contract — broker can't read forms it didn't declare (deferred — plumbing, not signal)
- [x] The broker stops bundling raw 10,000D vectors — reads scalar presences instead
- [ ] 10k benchmark — measure: broker Grace/Violence ratio, edge, disc_strength

## The pipeline (target state)

```scheme
(define (process raw-candle)
  (let* ((candle (enrich raw-candle))
         ((market-ast market-anomaly) (market-observer candle))
         ((exit-ast exit-anomaly) (exit-observer candle market-ast market-anomaly))
         )
    (broker candle market-ast market-anomaly exit-ast exit-anomaly)))
```

Each stage: `(ThoughtAST, Vector)` — the dictionary and the frozen superposition.
Each consumer: queries the prior stage's anomaly using forms from the AST.
The noise floor: `5.0 / sqrt(dims)` — the consumer's default threshold.
The extract primitive: `extract(vec, forms, encoder) → Vec<(ThoughtAST, f64)>` — flat, no hierarchy.

## Key constants

- Noise floor at D=10,000: `5.0 / sqrt(10000) = 0.05`
- Exit noise subspace: 8 principal components
- Extract: no threshold in primitive — consumer filters
