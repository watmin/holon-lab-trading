# Resolution: Proposal 028 — Hierarchical Extraction

**Date:** 2026-04-12
**Decision:** ACCEPTED — implement with designer clarifications

## Supersedes Proposal 027

Proposal 027 established the principle (extract thoughts between
observers via cosine decode). Proposal 028 refines the algorithm.
Both proposals are accepted. 028 is the implementation spec.

## Designers (revised with primer context)

Both designers read the VSA primers (atoms, operations, memory,
encoding mechanics) before re-reviewing.

**Hickey — ACCEPTED with clarification.** The hierarchical descent
is algebraically justified — a Bundle-of-two sits in a different
region of vector space than either component alone. Leaf probes
cannot recover the composed signal. The composition IS information.
Bind nodes are opaque — one bound pair, no sub-structure below
the encoding. The threshold formula needs empirical verification
before hardening.

**Beckman — CONDITIONAL, three clarifications.** All resolved:

### Clarification 1: threshold derivation

The proposal used `1/sqrt(N)`. Beckman corrected: in MAP bipolar
vectors, the expected cosine of a present component in a bundle
of N is approximately `1/N`, not `1/sqrt(N)`. The `1/sqrt(N)` is
the noise floor of cross-terms.

BUT: the extraction operates on the ANOMALY — the noise-stripped
residual from the OnlineSubspace. The subspace removes explained
variance, leaving a sparser effective-N. This improves SNR
substantially. The threshold is viable BECAUSE of the noise
stripping. The noise subspace IS the enabler of extraction.

Resolution: use `1/sqrt(N)` as the default descent threshold.
It approximates the noise floor. Above it = signal that survived
noise stripping. Below it = residual noise. Measure empirically
on real anomalies. Adjust if needed. The threshold is a default,
not a constant — the consumer can override.

### Clarification 2: Bind is opaque

`bind(A, B)` in MAP creates a vector orthogonal to both A and B.
You cannot cosine the children of a Bind against a target and
expect superposition semantics. Bind nodes are opaque.

In the current ThoughtAST, leaf facts (Linear, Log, Circular)
encode to `bind(role_vec, scalar_vec)` — one bound pair. This is
the atomic unit. There is no sub-structure below it in the
encoding space. The extraction treats all non-Bundle nodes as
leaves: cosine, report, do not recurse.

### Clarification 3: output contains absent leaves

The result `Vec<(ThoughtAST, f64)>` mixes present forms with
absent leaves found at the bottom of descent. The consumer must
filter. This is documented, not implied:

- Forms returned from a matched Bundle (cosine above threshold)
  are genuinely present compositions.
- Leaves returned from recursion into an unmatched Bundle may
  have near-zero cosines — they were reached because their
  PARENT wasn't present, not because they are.
- The consumer filters by their own relevance criterion.
  The extraction reports. The consumer decides.

Hickey suggested a `min_cosine = 0.0` garbage collection
parameter to prevent drowning consumers with near-zero pairs.
Accepted as a practical default — leaves below `min_cosine`
are dropped from the output.

## The algorithm (final)

```scheme
(define (extract thought-ast thought-vec encoder min-cosine)
  (let* ((ast-vec   (encode encoder thought-ast))
         (presence  (cosine thought-vec ast-vec))
         (n-children (if (bundle? thought-ast)
                       (length (children thought-ast))
                       0))
         (threshold  (if (> n-children 0)
                       (/ 1.0 (sqrt n-children))
                       0.0)))
    (cond
      ;; Non-Bundle: leaf. Report with cosine if above min.
      [(not (bundle? thought-ast))
       (if (> (abs presence) min-cosine)
         (list (pair thought-ast presence))
         (list))]
      ;; Bundle above threshold: present as composition. Return it.
      [(> (abs presence) threshold)
       (list (pair thought-ast presence))]
      ;; Bundle below threshold: decompose. Recurse into children.
      [else
       (flat-map (lambda (child)
         (extract child thought-vec encoder min-cosine))
         (children thought-ast))])))
```

Return type: `Vec<(ThoughtAST, f64)>`

Threshold: per-node `1/sqrt(k)` where k is the local child count.
min-cosine: garbage collection, default 0.0 (keep all).

## The changes

1. **New function:** `extract()` in `thought_encoder.rs` or
   new `extraction.rs` module. Walks the AST hierarchically.
   Per-node threshold. Returns `Vec<(ThoughtAST, f64)>`.

2. **Pipe change:** Market observer thread sends the AST
   alongside the thought vector and misses.

3. **Exit encoding (step 2):** Calls `extract` on the market
   observer's `(ast, anomaly)` pair. The consumer (exit)
   transforms the results into its own vocabulary — `m:` prefix,
   Linear encoding of presences — and appends to its own facts.

4. **VectorManager pre-registration:** Walk market ASTs at
   startup, register `m:` prefixed atom names. (From 027.)

5. **No global threshold.** Per-node `1/sqrt(k)`. The geometry
   determines the descent, not a parameter.

## What doesn't change

- The market observer's encoding or learning.
- The exit observer's own 28 atoms.
- The broker (future work — extracts from both).
- The ThoughtAST type.
- The ThoughtEncoder (read-only during extraction — cache hits).
- The simulation or paper mechanics.
