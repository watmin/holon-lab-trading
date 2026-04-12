# Resolution: Proposal 029 — Typed Thought Pipeline

**Date:** 2026-04-12
**Decision:** ACCEPTED — implement in phases

## Designers

Both accepted unanimously after reading the VSA primers.

**Hickey:** The flat extract beats 028's hierarchy. Typed structs
are the most important change — the compiler becomes the
proofreader. Don't defer. Exit needs its own noise subspace.
Broker must receive both (ast, anomaly) pairs independently.

**Beckman:** The algebra closes. The pipeline is a chain of
morphisms. Exit MUST have a noise subspace — at ~128 atoms and
D=10,000, the expected noise per probe exceeds 1.0 without
stripping. The noise subspace is algebraically required. Broker
reads both pairs: `broker-facts + extract(market-ast, market-anomaly)
+ extract(exit-ast, exit-anomaly)`.

## The noise floor

The threshold for "present" vs "noise":

```
5.0 / sqrt(dims)
```

At D=10,000: `5.0 / 100.0 = 0.05`. Two random bipolar vectors
have expected cosine 0 with standard deviation `1/sqrt(D) = 0.01`.
At 5 sigma, any cosine above 0.05 is statistically significant.
Below 0.05 is random alignment.

This is the consumer's default threshold. Not baked into the
primitive. The consumer applies it. The expression is:
`5.0 / (dims as f64).sqrt()`.

## The changes — phased

### Phase 1: Fix the scoping + flat extract (immediate)

1. **Flat extract primitive:** `extract(vec, forms, encoder) →
   Vec<(ThoughtAST, f64)>`. Map, encode (cache hit), cosine.
   No hierarchy. No threshold. In `thought_encoder.rs`.

2. **Scoping fix:** Move extraction INTO the N×M grid. Each
   (mi, ei) slot extracts from ONE market observer's
   (ast, anomaly). The exit vec is per-slot, not shared.
   N×M exit encodings instead of M.

3. **Consumer-side filtering:** The exit filters extracted forms
   above `5.0 / sqrt(dims)`. The original ASTs pass through —
   not transformed to presences. The forms that survived the
   market's noise stripping AND pass the noise floor become
   facts in the exit's vocabulary.

4. **Exit gains noise subspace:** Every thinker that produces
   (ast, anomaly) strips its own noise. The market observer
   has one. The broker has one. The exit gains one.
   `OnlineSubspace::new(dims, 8)`. The exit's anomaly is
   what survived BOTH the market's stripping AND the exit's
   own stripping.

### Phase 2: Typed structs (next session)

5. **Vocabulary structs:** Each vocabulary module defines a
   struct. Fields ARE the facts. `ToAst` trait for encoding.
   `forms()` for extraction queries. Compiler-enforced
   boundaries.

6. **Pipeline types:** The communication type `(ThoughtAST,
   Vector)` becomes `(T: ToAst, Vector)` — the type parameter
   prevents wrong piping.

7. **Broker receives both pairs:** `(market-ast, market-anomaly)`
   AND `(exit-ast, exit-anomaly)` independently. The broker
   extracts from both. The broker's full thought:
   `broker-self + extract(market) + extract(exit)`.

### Phase 3: Broker extraction (future)

8. The broker reads both stages' frozen superpositions.
   The broker's typed struct declares which forms it reads
   from each. The compiler enforces the contract.

## What supersedes

- Proposal 027: the principle stands. The flat extract replaces
  the m:-prefix mirrored AST approach.
- Proposal 028: the hierarchical algorithm is replaced by the
  flat primitive + consumer-side hierarchy if desired.
- The scoping bug in the current implementation is fixed.

## What doesn't change

- The market observer's encoding or learning
- The reckoner internals
- The paper mechanics
- The simulation functions
- The fold structure
- The reward cascade (proposals 021-023)
- The noise-anomaly alignment (proposal 024)
