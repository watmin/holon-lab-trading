# The Wat Language

Wat is an s-expression language for algebraic cognition.

## Grammar

```ebnf
program    = form*
form       = atom | number | string | list | comment
atom       = letter (letter | digit | '-' | '?' | '!' | '>')*
number     = digit+ ('.' digit+)?
string     = '"' char* '"'
list       = '(' form* ')'
comment    = ';' char* newline
```

## Core Forms (corelib)

Six primitives. Everything else composes from these.

```scheme
;; Naming
(atom "name")                    → Vector

;; Composition
(bind role filler)               → Vector    ; two things become one relationship
(bundle fact1 fact2 ...)         → Vector    ; many facts become one thought

;; Measurement
(cosine thought discriminant)    → Float     ; [-1.0, +1.0]

;; Learning
(journal name dims recalib)      → Journal
(observe journal thought label weight) → ()
(predict journal thought)        → Prediction  ; { direction, conviction, raw_cos }
(decay journal rate)             → ()

;; Evaluation
(curve journal resolved)         → { a, b }  ; accuracy = 0.50 + a × exp(b × conviction)
```

## Standard Library (stdlib)

Derived forms built from the corelib.

```scheme
;; Scalar encoding
(encode-linear value scale)      → Vector    ; [0, scale] maps to orthogonal
(encode-log value)               → Vector    ; equal ratios = equal similarity
(encode-circular value period)   → Vector    ; endpoint wraps to start

;; Vector operations
(difference before after)        → Vector    ; structural change
(permute vector shift)           → Vector    ; element rotation
(negate superposition component) → Vector    ; remove component
(amplify superposition component strength) → Vector
(prototype vectors threshold)    → Vector    ; consensus extraction
(cleanup noisy codebook)         → Vector    ; snap to nearest
(attend query memory strength mode) → Vector ; soft attention
(coherence vectors)              → Float     ; mean pairwise similarity
(similarity-profile a b)         → Vector    ; per-dimension agreement

;; Memory
(online-subspace dims k)         → Subspace
(update subspace vector)         → ()
(residual subspace vector)       → Float     ; distance from learned manifold
(threshold subspace)             → Float     ; self-calibrating boundary

;; Gate (derived pattern)
(gate journal curve threshold)   → Bool
;; Equivalent to: (> (curve journal conviction) threshold)

;; Noise floor (derived from geometry)
(noise-floor dims)               → Float     ; 3 / sqrt(dims)
(sweet-spot dims)                → Float     ; 5 / sqrt(dims)
```

## Control Forms

```scheme
;; Binding
(let ((name value) ...) body)
(let* ((name value) ...) body)   ; sequential binding
(define (name args ...) body)    ; function definition

;; Conditional
(if test then else)
(when test body)
(match value (pattern body) ...)

;; Iteration
(for-each fn list)
(map fn list)
(filter fn list)
(filter-map fn list)

;; Channel (communication)
(channel name :type schema)
(publish channel message)
(subscribe channel :filter expr :process fn)
```

## Type Annotations (optional)

```scheme
;; Types are documentation, not enforcement.
;; The algebra doesn't type-check — the curve validates.
(define (encode-expert [expert-atom : Vector]
                       [raw-cos : Float]
                       [dims : Int])
  : Vector
  ...)
```

## Module System

```scheme
(require primitives)             ; corelib
(require common)                 ; stdlib atoms
(require mod/oscillators)        ; domain vocabulary
(require channels)               ; communication contract
```

## What Wat Is Not

- Not a general-purpose language. It expresses algebraic cognition.
- Not Turing complete. It doesn't need to be. The algebra is sufficient.
- Not interpreted at runtime. Wat is compiled to Rust. The Rust runs.
- Not a replacement for Lisp. It IS Lisp, restricted to the six primitives.

## What Wat Is

- A specification language for Holon programs.
- A shared language between human intuition and machine implementation.
- Parseable, validatable, structurally analyzable.
- The intermediate representation between thought and execution.
- Lisp with a purpose: algebraic cognition from named thoughts.

## Example: The Heartbeat

```scheme
(define (heartbeat candle-idx candles vm experts generalist manager risk treasury)
  (let* ((expert-preds (map (lambda (e) (e candles vm candle-idx)) experts))
         (gen-pred     (generalist candles vm candle-idx))
         (mgr-pred     (manager expert-preds gen-pred (nth candles candle-idx)))
         (risk-mult    (risk treasury positions expert-preds))
         (_            (treasury-execute treasury mgr-pred risk-mult))
         (_            (manage-positions positions treasury exit-expert candle))
         (_            (learn experts generalist manager candles pending threshold)))
    (record-all ledger candle-idx)))
```

This is the enterprise in 8 lines. Each line is a layer. Each layer composes.
The architecture is the language. The language is the architecture.
