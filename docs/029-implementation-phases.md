# Proposal 029 — Implementation Phases

Backlog for the typed thought pipeline. Each phase proves itself
before the next begins.

## Phase 1: Flat extract + scoping + exit noise subspace (IN PROGRESS)

- [x] Flat `extract(vec, forms, encoder) → Vec<(ThoughtAST, f64)>` — no hierarchy, no threshold in primitive
- [x] `flatten_leaves(ast) → Vec<ThoughtAST>` helper — collect leaf forms from an AST tree
- [ ] Scoping fix: extraction moves INTO N×M grid, each slot extracts from ONE market observer
- [ ] Remove pre-computed shared exit vecs — each (mi, ei) slot encodes its own
- [ ] Consumer-side noise floor filter: `5.0 / (dims as f64).sqrt()` = 0.05 at D=10,000
- [ ] Pass ORIGINAL ThoughtASTs through the filter, not presence-transformed
- [ ] Exit observer gains `noise_subspace: OnlineSubspace::new(dims, 8)`
- [ ] Exit observer gains `strip_noise()` method
- [ ] Exit encoding: update noise subspace, strip, query reckoner on anomaly
- [ ] Exit's anomaly (not raw vec) flows to broker thread as exit_thought
- [ ] `cargo build --release` clean
- [ ] `cargo test` all pass
- [ ] Smoke test 500 candles
- [ ] 10k benchmark — measure: exit residue by decile, throughput, cache hit rate

## Phase 2: Typed vocabulary structs (NEXT SESSION)

- [ ] Each vocabulary module defines a struct (fields ARE the facts)
- [ ] `ToAst` trait: `fn to_ast(&self) -> ThoughtAST` + `fn forms(&self) -> Vec<ThoughtAST>`
- [ ] Market vocabulary structs: MomentumThought, StructureThought, VolumeThought, RegimeThought, NarrativeThought, GeneralistThought
- [ ] Exit vocabulary structs: ExitVolatilityThought, ExitStructureThought, ExitTimingThought, ExitGeneralistThought
- [ ] Pipeline communication type: `(T: ToAst, Vector)` — compiler prevents wrong piping
- [ ] Update all vocabulary functions to construct structs instead of raw `Vec<ThoughtAST>`
- [ ] `cargo build --release` clean — the compiler enforces vocabulary boundaries
- [ ] `cargo test` all pass

## Phase 3: Broker extraction (FUTURE)

- [ ] Broker receives `(exit-ast, exit-anomaly)` pair alongside market pair
- [ ] Broker extracts from BOTH stages independently
- [ ] Broker's full thought: `broker-self + extract(market) + extract(exit)`
- [ ] Broker typed struct declares which forms it reads from each stage
- [ ] Compiler enforces the contract — broker can't read forms it didn't declare
- [ ] The broker stops bundling raw 10,000D vectors — reads scalar presences instead
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
