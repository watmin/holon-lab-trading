;; ── wat primitives ──────────────────────────────────────────────────
;;
;; Six primitives. Everything else composes from these.
;;
;; The algebra computes. The journal learns. The curve evaluates.
;; The gate controls. The enterprise composes.

;; ── Algebra (4 primitives) ──────────────────────────────────────────

;; atom: name a concept → deterministic bipolar vector
;; Same seed + same name = same vector everywhere. No coordination.
(atom "momentum")  → Vector

;; bind: compose two concepts into a relationship
;; Self-inverse: (bind (bind A B) A) = B
(bind role filler)  → Vector

;; bundle: superimpose multiple relationships into one thought
;; The superposition — all facts present simultaneously.
(bundle fact1 fact2 fact3 ...)  → Vector

;; cosine: measure similarity between two thoughts
;; The only measurement. One number. Direction + magnitude.
(cosine thought discriminant)  → f64  ; [-1.0, +1.0]

;; ── Learning (1 primitive) ──────────────────────────────────────────

;; journal: accumulates labeled observations, produces predictions
;; Contains: buy accumulator, sell accumulator, discriminant
;; The discriminant = normalize(buy_proto - sell_proto)
;; Prediction = cosine(thought, discriminant) → direction + conviction
(journal name dims recalib_interval)  → Journal

(observe journal thought label weight)  ; label = Buy | Sell
(predict journal thought)  → (direction conviction)
(decay journal rate)

;; ── Evaluation (1 primitive) ────────────────────────────────────────

;; curve: measures journal quality at each conviction level
;; accuracy = 0.50 + a × exp(b × conviction)
;; The curve IS the proof. Monotonically increasing = real signal.
(curve journal resolved_preds)  → (a b)

;; ── Derived patterns ────────────────────────────────────────────────

;; gate: controls information flow based on curve validation
;; Not a new primitive — a conditional from the curve.
(gate journal curve threshold)
→ (if (> (curve journal conviction) threshold)
     (emit opinion)
     silence)

;; permute: shift vector elements for directional encoding
;; BUY = atom, SELL = (permute atom 1). Orthogonal in hyperspace.
(permute vector shift)  → Vector

;; encode-log: scalar magnitude encoding (log scale)
(encode-log value)  → Vector

;; difference: structural change between two states
;; What's new in `after` that wasn't in `before`.
(difference before after)  → Vector

;; ── Additional holon operations (available, not all used yet) ───────
;;
;; attend     — soft attention over memory
;; prototype  — extract consensus from examples
;; cleanup    — snap noisy observation to nearest known pattern
;; segment    — detect structural breakpoints in stream
;; negate     — remove component from superposition
;; amplify    — boost component presence
;; blend      — weighted interpolation
;; analogy    — relational transfer (A:B :: C:?)
;; coherence  — mean pairwise similarity of vector set
;; cross-correlate — causal relationship between streams
;; unbind     — inverse of bind (same operation, bind is self-inverse)
