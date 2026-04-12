# Proposal 029 — Typed Thought Pipeline

**Date:** 2026-04-12
**Author:** watmin + machine
**Status:** PROPOSED

## The pipeline

Each stage of the enterprise produces a pair: the thought AST
(the dictionary) and the anomaly vector (the frozen superposition
of noteworthy thoughts). Each consumer receives the prior stage's
pair and is free to do whatever work it wants on that data.

```scheme
(define (process raw-candle)
  (let* ((candle (enrich raw-candle))
         ;; Market: candle → (ast, anomaly)
         ((market-ast market-anomaly)
          (market-observer candle))
         ;; Exit: candle + market's outputs → (ast, anomaly)
         ((exit-ast exit-anomaly)
          (exit-observer candle market-ast market-anomaly))
         ;; Broker: candle + both outputs → proposal
         )
    (broker candle
            market-ast market-anomaly
            exit-ast exit-anomaly)))
```

This is one (market, exit, broker) triple. The full enterprise
is N×M of these.

## The communication type

Each stage produces `(ThoughtAST, Vector)`:
- The AST is the dictionary — the tree of forms this stage encoded
- The Vector is the anomaly — the noise-stripped superposition

Together they are a self-describing message. The AST tells you
what forms COULD be inside. The Vector holds which ones ARE.

## The consumer's freedom

The consumer receives `(ThoughtAST, Vector)` from the prior stage.
The consumer is free to:

1. Walk the AST — it's data. Filter it. Select forms by type.
   Take only `Bind` nodes. Take only `Linear` nodes. Take only
   forms with specific names. Whatever work the consumer wants.

2. Encode the selected forms — cache hits. Get the vector for
   each form of interest.

3. Cosine each form's vector against the anomaly — measure
   presence. "Is this form here?"

4. Choose a threshold — the consumer decides what "here" means.
   High cosine = present. Low cosine = absent. The cutoff is
   the consumer's choice. Not the extraction's. Not the
   producer's. The consumer's.

5. Use the present forms — append them to the consumer's own
   facts, encode them into the consumer's own thought, feed
   them to the consumer's own reckoner.

```scheme
;; The exit as consumer — one possible strategy:
(define (exit-observer candle market-ast market-anomaly)
  (let* (;; Own facts about this candle (28 atoms)
         (own-facts (exit-lens-facts lens candle self))
         ;; Read the market's frozen superposition
         ;; Consumer chooses: all Bind forms (leaves) above 0.01
         (market-forms (filter bind? (flatten market-ast)))
         (measured (extract market-anomaly market-forms encoder))
         (present (filter (lambda (pair)
                    (> (abs (second pair)) 0.01))
                    measured))
         ;; The original ASTs — not transformed, not m:-prefixed.
         ;; The actual facts the market found noteworthy.
         (absorbed (map first present))
         ;; Encode: own facts + absorbed market facts
         (all-facts (append own-facts absorbed))
         (thought (encode all-facts))
         ;; Strip own noise
         (anomaly (anomalous-component noise-subspace thought)))
    ;; Return OUR pair for the next consumer
    (list (Bundle all-facts) anomaly)))
```

## The extract primitive

```scheme
(extract thought-vec forms encoder) → Vec<(ThoughtAST, f64)>
```

Flat. Simple. A batch of queries against a frozen vector.
Map forms → encode each (cache hit) → cosine each → return pairs.

No hierarchy in the primitive. No threshold in the primitive.
No recursion in the primitive. The consumer provides the forms.
The consumer applies the threshold. The consumer decides the
hierarchy. The primitive just measures.

```scheme
(define (extract thought-vec forms encoder)
  (map (lambda (form)
    (let ((form-vec (encode encoder form)))
      (pair form (cosine thought-vec form-vec))))
    forms))
```

## Typed ASTs

The ThoughtAST for momentum is not the same type as the
ThoughtAST for regime. Today both are `Vec<ThoughtAST>` — the
compiler can't distinguish them. You can pipe momentum facts
where regime facts are expected.

Each vocabulary becomes a struct. The struct fields ARE the facts.

```rust
struct MomentumThought {
    close_sma20: f64,
    close_sma50: f64,
    close_sma200: f64,
    macd_hist: f64,
    di_spread: f64,
    atr_ratio: f64,
}

struct RegimeThought {
    kama_er: f64,
    choppiness: f64,
    dfa_alpha: f64,
    variance_ratio: f64,
    entropy_rate: f64,
    aroon_up: f64,
    aroon_down: f64,
    fractal_dim: f64,
}
```

Each struct implements `ToAst`:

```rust
trait ToAst {
    fn to_ast(&self) -> ThoughtAST;
    fn forms(&self) -> Vec<ThoughtAST>;  // the queries this type knows
}
```

The `forms()` method returns the ASTs this vocabulary produces.
The consumer calls `extract(anomaly, thought.forms(), encoder)`
to query all of them. Or the consumer filters `forms()` first —
take only the ones it cares about.

The compiler enforces: you can't pass `MomentumThought` where
`RegimeThought` is expected. The types prevent wrong piping.
The 600-atom bug (extracting from all 6 market observers instead
of one) becomes a compile error — the exit's function signature
says which market type it accepts.

## The scoping fix

The current implementation pre-computes M exit vecs shared across
all N market observers. With extraction, this is wrong — each
(mi, ei) pair sees a different market observer's noteworthy
thoughts. The exit vec is no longer shared.

The extraction moves INTO the N×M grid. Each slot:
1. Takes its one market observer's (ast, anomaly)
2. Extracts the forms it cares about
3. Encodes its own facts + absorbed market facts
4. Produces its own exit vec

N×M exit encodings instead of M. More encoding. But honest —
each exit sees the market it's paired with. And the extraction
cost drops from 6×100 to 1×100 per slot.

## What changes

1. **`extract()` primitive:** flat batch query. `(vec, forms,
   encoder) → Vec<(ThoughtAST, f64)>`. Replaces the hierarchical
   version from 028.

2. **Pipeline shape:** each stage produces `(ThoughtAST, Vector)`.
   Each consumer receives the prior stage's pair.

3. **Exit encoding moves into the grid:** each (mi, ei) slot
   computes its own exit vec with extracted market facts.

4. **Typed thought structs:** each vocabulary module defines a
   struct. `ToAst` trait for encoding. `forms()` for extraction
   queries. Compiler-enforced boundaries.

5. **Consumer-side filtering:** no threshold in the primitive.
   The consumer walks the AST, selects forms, calls extract,
   filters by cosine. Point-in-code opinions on decomposition.

## What doesn't change

- The market observer's encoding or learning
- The noise subspace mechanics
- The reckoner internals
- The paper mechanics
- The simulation functions
- The fold structure

## Questions

1. The typed structs are a large refactor — every vocabulary
   module changes. Should we implement extract + scoping first
   (proposals 027-028 corrected) and defer typed structs?

2. The exit produces its own `(ast, anomaly)`. Should the exit
   have its own noise subspace for stripping? Currently it
   doesn't. The market observer has one. The broker has one.
   The exit is the only stage without noise stripping.

3. Each (mi, ei) slot produces a unique exit vec. The broker
   thread receives the composed vector. Should the broker also
   receive the exit's `(ast, anomaly)` pair so it can extract
   from both stages independently?
