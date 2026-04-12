# Proposal 028 — Hierarchical Extraction

**Date:** 2026-04-12
**Author:** watmin + machine
**Status:** PROPOSED

**Supersedes Proposal 027** in the extraction algorithm. Proposal
027 established the principle (extract thoughts between observers
via cosine decode). This proposal refines the algorithm to be
hierarchical — the extraction walks the AST tree top-down, stops
at the highest level that matches, and only decomposes when the
composition isn't present.

## The algorithm

```scheme
(define (extract thought-ast thought-vec encoder)
  (let* ((ast-vec   (encode encoder thought-ast))    ;; cache hit
         (presence  (cosine thought-vec ast-vec)))
    (if (> (abs presence) threshold)
      ;; This form IS present — return it with its cosine.
      ;; Do not recurse. The composition as a whole is in the thought.
      (list (pair thought-ast presence))
      ;; This form is NOT present as a whole — recurse into children.
      (match thought-ast
        [(Bundle children)
         (flat-map (lambda (child)
           (extract child thought-vec encoder))
           children)]
        [leaf
         ;; Leaf not present above threshold — still report it.
         ;; The cosine is honest. Near-zero means absent.
         (list (pair leaf presence))]))))
```

The return type: `Vec<(ThoughtAST, f64)>`.

The ThoughtAST is the form that was found. The f64 is the cosine
of that form against the thought vector. Always honest. Always
data.

## Why hierarchical

A ThoughtAST can be nested. A Bundle of Bundles. A composition
of compositions. Each level of the tree IS a thought — the
bundle of `(close-sma20 + rsi)` is a thought just as much as
`close-sma20` alone is a thought.

If the composition is present in the anomaly — if the market
observer found `close-sma20 AND rsi` noteworthy TOGETHER — the
extraction should return ONE result: the Bundle, with its cosine.
Decomposing it into `close-sma20` and `rsi` separately loses
the information that they were noteworthy AS A COMPOSITION.

If the composition is NOT present — the combination wasn't
noteworthy — the extraction recurses. Maybe `close-sma20` alone
is present. Maybe `rsi` alone is present. Maybe neither. The
recursion finds the highest-level match.

The descent stops where presence is found. The extraction is
greedy — returns the LARGEST matching form. Only decomposes when
the composition isn't present.

## The consumer owns the data

The extraction returns `Vec<(ThoughtAST, f64)>`. This is DATA.
The consumer owns it.

The consumer can:
- Filter by cosine (their threshold, not the extraction's)
- Further decompose a matched Bundle into children
- Encode each result into their own thought vector
- Flatten the results into scalar facts
- Ignore results below some relevance
- Use the ASTs as keys in their own cache

The extraction does not decide what matters. The extraction
reports what exists and how much. The consumer decides.

```scheme
;; The exit observer as consumer:
(let ((found (extract market-ast market-anomaly encoder)))
  ;; found: Vec<(ThoughtAST, f64)>
  ;;
  ;; Option A: encode each found fact as a scalar presence
  (map (lambda (pair)
    (Linear (string-append "m:" (ast-name (first pair)))
            (second pair) 1.0))
    found)
  ;;
  ;; Option B: only take facts above some threshold
  (filter (lambda (pair) (> (abs (second pair)) 0.05)) found)
  ;;
  ;; Option C: re-encode the found ASTs directly
  ;; (the ASTs are valid ThoughtASTs — they can be bundled)
  (Bundle (map first found)))
```

## The threshold

The extraction needs a threshold to decide "present" vs "not
present" at each tree level. This is the ONE parameter.

Proposal 027's designers said: no threshold — a threshold is a
parameter pretending to be a fact. But the hierarchical version
NEEDS it for the descent decision. Without it, the outer Bundle
always matches (everything has SOME cosine), and the extraction
never recurses.

The threshold is NOT a filter on the output. The output includes
ALL leaves with their honest cosines. The threshold controls the
DESCENT — "should I decompose this Bundle or return it as a
whole?" High threshold = decompose more, return smaller pieces.
Low threshold = return larger compositions.

Proposal: start with `1.0 / sqrt(N)` where N is the number of
facts in the Bundle. This is the EXPECTED cosine of a random
component in a bundle of N quasi-orthogonal vectors. Above it
= genuinely present. Below it = noise-level presence.

Or: the consumer provides the threshold. Each consumer decides
how aggressively to decompose. The exit might want fine-grained
leaves. The broker might want coarse compositions.

## What changes from Proposal 027

1. **Return type:** `Vec<(ThoughtAST, f64)>` instead of a
   mirrored AST tree with m:-prefixed names.

2. **Hierarchical descent:** top-down, stop at highest match.
   Not flat walk of all leaves.

3. **Threshold for descent:** one parameter that controls
   granularity. Consumer-provided or derived from `1/sqrt(N)`.

4. **Consumer responsibility:** the consumer transforms the
   results into their vocabulary. The extraction is generic.
   No `m:` prefix in the extraction itself — that's a consumer
   choice.

## Questions

1. Should the threshold be on the extraction function or on
   the consumer? If on the extraction, it's one parameter.
   If on the consumer, the extraction always returns all
   leaves and the consumer decides.

2. The hierarchical descent means a matched Bundle is returned
   as one element. The consumer receives a ThoughtAST that may
   be a Bundle. Should the consumer's encoder handle this
   directly (encode the Bundle → vector → scalar fact in their
   own thought)?

3. Can the extraction threshold be LEARNED? A reckoner that
   discovers the optimal decomposition depth for each consumer?
   Future work, but the question shapes the interface.
