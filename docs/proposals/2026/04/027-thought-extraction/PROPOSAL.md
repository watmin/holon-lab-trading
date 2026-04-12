# Proposal 027 — Thought Extraction

**Date:** 2026-04-12
**Author:** watmin + machine
**Status:** PROPOSED

## The primitive

```scheme
(extract thought-ast thought-vec encoder) → thought-ast
```

A function that reads a thought vector using a thought AST as
the dictionary. Walks the tree. Cosines each form against the
vector. Returns a new AST — same shape, same atom names, but
the values are PRESENCES: how much of each form survived in the
noteworthy thought.

The input is a pair: `(thought-ast, thought-vec)`. The AST is
the tree of all possible facts the producer encoded. The vector
is the producer's noteworthy thought — the anomaly, the noise-
stripped signal. The output is a new AST that says what the
producer found noteworthy.

This is not a new primitive. This is cosine + encode composed
into a pattern. The tools exist: ThoughtEncoder caches the AST
vectors. Cosine measures presence. The extraction is encode in
reverse.

## Why this matters

The exit observer receives the market thought. Today it either
bundles with it (drowns the signal) or ignores it (loses the
context). Neither is right.

The extraction gives the exit a third option: READ the market
thought. Decode what the market observer found noteworthy. Absorb
those facts as ambient context in the exit's own vocabulary.

The market observer encoded ~100 facts through its lens. The noise
subspace stripped the background. What survived is the anomaly —
the things the market observer's experience said were UNUSUAL this
candle. The exit doesn't need to know which facts those were in
advance. The exit walks the AST, cosines each form, and discovers
which facts survived. The extraction IS the communication.

```scheme
;; The market produced:
;;   thought-ast = (Bundle
;;                   (Linear "close-sma20" 0.03 0.1)
;;                   (Linear "rsi" 0.73 1.0)
;;                   (Log "atr-ratio" 0.02)
;;                   ...)
;;   anomaly     = 10000D vector (noise stripped)
;;
;; The exit extracts:
;; (extract thought-ast anomaly encoder)
;; → (Bundle
;;     (Linear "close-sma20" 0.12 1.0)   ;; noteworthy — 12% presence
;;     (Linear "rsi" -0.01 1.0)          ;; noise — ~0% presence
;;     (Linear "atr-ratio" 0.08 1.0))    ;; noteworthy — 8% presence
;;
;; The exit now knows: the market observer found trend and
;; volatility noteworthy this candle. RSI was background noise.
;; The exit didn't need to be told. The geometry told it.
```

## The properties

**Transferable without coordination.** The producer encodes
through its own lens, strips its own noise. The consumer reads
the result using the producer's AST as the dictionary. No shared
state. No protocol agreement. No "these are the important facts."
The geometry carries the importance.

**Live per candle.** The extraction happens every candle. Different
candle → different anomaly → different presences. The exit's
absorbed market context breathes with the candle stream. The
reckoner accumulates the experience: "when the market found
momentum noteworthy, the optimal trail was X." The extraction is
the present. The reckoner is the history.

**Cache-friendly.** The market's ASTs were encoded this candle.
The vectors are in the ThoughtEncoder's LRU cache. The extraction
is cosines against cached vectors. No recomputation. The decode
is free — just inner products.

**Composable.** The output IS a ThoughtAST. It goes straight into
the consumer's bundle. The exit's thought becomes:

```scheme
(Bundle
  exit-own-facts              ;; 28 atoms (volatility, regime, time, self)
  (extract market-ast         ;; ~100 atoms (what the market found noteworthy)
           market-anomaly
           encoder))
```

The encoder encodes the full bundle. The exit's reckoner sees
exit facts + extracted market facts. All as scalars. All named.

**Hierarchical.** The broker can extract from BOTH the market
thought and the exit thought. Two extractions. Two ASTs. Two
anomalies. The broker absorbs the judgments of both leaves as
scalar facts in its own vocabulary.

```scheme
;; The broker's thought:
(Bundle
  broker-self-facts
  (extract market-ast market-anomaly encoder)
  (extract exit-ast exit-anomaly encoder))
```

Each layer reads the layer below. The extraction is the
communication. The AST is the dictionary. The anomaly is the
message. The cosine is the decode.

## The algorithm

```scheme
(define (extract thought-ast thought-vec encoder)
  (match thought-ast
    [(Bundle children)
     (Bundle (map (lambda (child)
                    (extract child thought-vec encoder))
                  children))]
    [leaf  ;; Linear, Log, or Circular
     (let* ((form-vec (encode encoder leaf))       ;; cache hit
            (presence (cosine thought-vec form-vec)))
       (Linear (string-append "m:" (name leaf))
               presence
               1.0))]))
```

Walk the tree. At each leaf, encode the AST form (cache hit),
cosine against the thought vector, return a Linear fact with
the `m:` prefixed name and the presence as the value.

The `m:` prefix avoids collision. The exit has its own `rsi`
(from the current candle). The extracted `m:rsi` is what the
market observer's noise-stripped experience says about RSI.
They are different thoughts about the same measurement. Both
present. Both named. Both honest.

## What changes

1. **New function:** `extract(ast, vec, encoder) → ast` in
   `thought_encoder.rs` or a new `extraction.rs` module.

2. **Exit encoding (step 2):** after encoding exit facts, call
   `extract` on the market observer's `(ast, anomaly)` pair.
   Append the extracted AST to the exit's facts before encoding.

3. **The pipe:** the market observer's AST must flow to the exit
   grid. Today the observer thread sends `(thought, misses)`.
   Add the AST: `(thought, ast, misses)`.

4. **Exit reckoner training:** `observe_distances` receives
   `exit-thought` which now INCLUDES the extracted market facts.
   No change to the training path — the extraction is absorbed
   at encoding time.

## What doesn't change

- The market observer's encoding or learning.
- The broker's encoding (future work — the broker can extract too).
- The ThoughtAST type (the extracted facts ARE ThoughtASTs).
- The ThoughtEncoder (it encodes the extracted AST like any other).
- The simulation functions.
- The paper mechanics.

## Questions

1. Should the extraction use a threshold? Only absorb facts with
   presence above some minimum? Or absorb all and let the reckoner
   decide what matters?

2. The extracted AST is ~100 nodes. The exit's own AST is 28.
   The bundle is now ~128 atoms. Does the exit's signal get
   drowned by the market's 100 extracted facts? Or does the
   noise subspace (when added to the exit) strip what doesn't
   matter?

3. The `m:` prefix creates new atoms — `m:close-sma20` is a
   different vector from `close-sma20`. Should the extracted
   facts share atoms with the exit's own facts where they
   overlap? `rsi` and `m:rsi` — same atom or different?

4. This primitive is generic. It applies to any (AST, Vector)
   pair. Should it be in holon-rs (the substrate) rather than
   the trading lab? The extraction IS a VSA operation — decode
   a bundle using a known codebook.
