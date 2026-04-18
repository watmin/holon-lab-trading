# 058-013: `Ngram` — n-Wise Adjacency

**Scope:** algebra
**Class:** STDLIB
**Parent:** 058-ast-algebra-surface
**Foundation:** ../FOUNDATION.md
**Depends on:** 058-011-then (for the pairwise case), 058-012-chain (generalizes)

## The Candidate

A wat stdlib function that encodes `n`-wise adjacency windows over a list of thoughts:

```scheme
(define (Ngram n thoughts)
  (Bundle (n-wise-map encode-window n thoughts)))
```

Where `n-wise-map` slides a window of size `n` across `thoughts`, and `encode-window` encodes each window as a permutation-ordered Bundle (Sequential, specialized).

### More concretely

```scheme
(define (encode-window window)
  (Bundle
    (map-with-index (lambda (t i) (Permute t i)) window)))

(define (n-wise-map f n xs)
  ;; produces: (f xs[0..n]), (f xs[1..n+1]), (f xs[2..n+2]), ...
  ;; until the sliding window exhausts xs
  ...)

(define (Ngram n thoughts)
  (Bundle (n-wise-map encode-window n thoughts)))
```

### Special cases

- `n = 1`: each window is a single thought; Ngram produces `(Bundle [t0 t1 t2 ...])` = `(Bundle thoughts)` = `(Concurrent thoughts)`.
- `n = 2`: each window is a pair; with the pairwise encoding, Ngram produces `(Chain thoughts)`.
- `n = k`: each window is a `k`-tuple, permutation-encoded internally, then all windows bundled.

### Semantics

Ngram captures "the n-sized adjacency structure of this list." It is to natural-language n-grams what Sequential is to positional encoding. A vocab module using Ngram asserts "the sliding-window view is what matters here, not the absolute positions."

## Why Stdlib Earns the Name

**1. Its expansion uses only existing core/stdlib forms.** Bundle, Permute are core; the window encoding decomposes into Bundle + Permute compositions. Ngram is a composition over primitives.

**2. It reduces ambiguity for readers.** `(Ngram 3 [s1 s2 s3 s4 s5])` reads as "triplet-windowed encoding of these 5 stages." The expansion, written out, is a dense Bundle-of-Bundles-of-Permutes that requires the reader to infer the structure.

Both criteria met.

## Arguments For

**1. Classical n-gram structure is useful for many domains.**

Text, audio, event sequences, time series — any list where adjacent patterns matter — benefits from windowed encoding. The vocabulary of n-grams (bigrams, trigrams, 4-grams) is well-established.

**2. Generalizes Chain.**

Chain (058-012) is Ngram at `n=2`. Keeping both in stdlib gives readers a short name for the common case (Chain) and a parameterized name for the general case (Ngram). Analogous to how Sequential is Ngram with specific conventions.

Could Chain be deprecated in favor of `(Ngram 2 xs)`? Possibly, but `Chain` reads cleaner for the common case. Keep both.

**3. Bounded cache impact.**

Each window encoding is its own sub-AST. Caching happens at the window level. Two Ngrams over overlapping lists share windows automatically via the L1 cache — identical sub-windows produce identical vectors.

Example: `(Ngram 2 [a b c d])` and `(Ngram 2 [a b c e])` share the windows `(Then a b)` and `(Then b c)`. Different final outputs, but cached sub-computations reuse.

**4. Invariance properties.**

Ngram is shift-invariant on windows: moving a pattern within a longer list leaves the windows containing the pattern unchanged (even if the list-level position changes). This is the classical n-gram property that makes the encoding useful for sequence classification.

## Arguments Against

**1. Parameterization adds surface complexity.**

Ngram takes an integer `n` as its first argument, unlike Bundle/Concurrent/Chain which are unary over a list. Readers must remember the parameter order: "n comes first." Could be confusing if `n` is a computed value or passed through variable.

**Mitigation:** keyword argument or specialized names per `n` could solve this — `Bigram`, `Trigram`, `Quadgram`. But that proliferates names. Keeping one parameterized `Ngram` is cleaner than 5+ specialized forms.

**2. `n-wise-map` may not exist in the wat stdlib.**

The expansion depends on a sliding-window combinator. If unavailable, must define:

```scheme
(define (n-wise-map f n xs)
  (if (< (length xs) n)
      '()
      (cons (f (take n xs))
            (n-wise-map f n (rest xs)))))
```

Works but requires `take`, `length`, standard list combinators. Assumes these exist in the wat stdlib or become bundled additions.

**3. Edge cases: `n > length(thoughts)` or `n = 0`.**

What should `(Ngram 5 [a b c])` produce? Options:
- Empty bundle (no windows fit) → zero vector.
- Degenerate to `Sequential` (just encode all items).
- Error.

Convention: empty bundle (zero vector), matches the mathematical n-gram definition. `n = 0` is undefined (document).

**4. Windowed encoding inside vs. outside.**

The proposal encodes each window as a Sequential-like position-permuted bundle, THEN bundles all windows together. An alternative: encode each window as Sequential (`(Sequential window)`), THEN bundle. Same operation, but using Sequential by name.

**Mitigation:** simplify the definition:

```scheme
(define (Ngram n thoughts)
  (Bundle (n-wise-map (lambda (window) (Sequential window)) n thoughts)))
```

Or, even more concise (once Sequential is stdlib per 058-009):

```scheme
(define (Ngram n thoughts)
  (Bundle (map Sequential (n-wise-split n thoughts))))
```

Where `n-wise-split` produces the list of windows. Cleaner composition.

## Comparison

| Form | Class | `n` | Description |
|---|---|---|---|
| `Concurrent(xs)` | STDLIB (058-010) | — | Order-insensitive bundle |
| `Then(a, b)` | STDLIB (058-011) | 2 (binary) | Pairwise directed |
| `Chain(xs)` | STDLIB (058-012) | 2 (sliding) | Pairwise transitions |
| `Ngram(n, xs)` | STDLIB (this) | n (sliding) | n-wise windows |
| `Sequential(xs)` | STDLIB (058-009) | — | Full position encoding |

Ngram is the generalized form; Concurrent, Then, Chain, and Sequential are specializations with specific values of `n` or specific encoding schemes.

## Algebraic Question

Does Ngram compose with the existing algebra?

Yes. Output is a vector in the ternary output space `{-1, 0, +1}^d` (Bundle of Bundles of Permutes; see FOUNDATION's "Output Space" section). Same dimensional space.

Is it a distinct source category?

No — it is a composition over Bundle and Permute with windowing. Stdlib.

## Simplicity Question

Is this simple or easy?

Conceptually simple (slide a window, encode each window, bundle). Implementation requires a sliding-window combinator, which may need to be added to stdlib first.

Is anything complected?

No. Ngram has one role: "encode the n-wise adjacency structure of a list." The parameter `n` controls window size; no other concerns mixed in.

Could existing forms express it?

Yes, once the sliding-window combinator is available. Pure composition.

## Implementation Scope

**Zero Rust changes.** Pure wat.

**wat stdlib additions:**

```scheme
;; wat/std/sequences.wat

(define (n-wise-split n xs)
  (if (< (length xs) n)
      '()
      (cons (take n xs)
            (n-wise-split n (rest xs)))))

(define (Ngram n thoughts)
  (Bundle (map Sequential (n-wise-split n thoughts))))
```

Depends on `take`, `length`, `map`, `rest` being available in the wat stdlib (standard list combinators).

## Questions for Designers

1. **Window encoding: Sequential or custom?** The cleanest definition uses Sequential to encode each window. If 058-009 keeps Sequential as a stdlib form, this is clean. If Sequential is rejected (stays as variant), Ngram's internal window encoding inlines the Bundle+Permute pattern.

2. **Edge cases.** What does `(Ngram 0 xs)` produce? `(Ngram 5 [a b c])`? `(Ngram 2 [])`? Proposal: `n=0` is error, `n > length` is empty bundle (zero vector), `xs = []` is empty bundle. Confirm conventions.

3. **Specialized names for small `n`: `Bigram`, `Trigram`?** Pros: readable for the common cases. Cons: name proliferation. Recommendation: keep only `Ngram` as the parameterized form, and `Chain` as the `n=2` specialization (already in 058-012). Avoid `Bigram`/`Trigram` unless they earn distinct semantic intent beyond "Ngram with specific n."

4. **Stdlib dependencies.** `n-wise-split`, `take`, `length`, `map`, `rest` — these are standard list operations that Ngram depends on. Are all present in the current wat stdlib, or does this proposal need to bring them in as prerequisites?

5. **Performance.** An Ngram over a list of length `k` with window `n` produces `k-n+1` windows, each requiring a Sequential encoding. This is `O(k·n)` sub-AST construction and encoding, plus one top-level Bundle of `k-n+1` items. Acceptable for reasonable `k, n`; could be expensive for long lists. Document the scaling.

6. **Relationship to the generalist-observer's rhythm encoding.** The holon-lab-trading project uses an n-gram-like approach for indicator rhythms (bundled bigrams of trigrams). Is this proposal's `Ngram` the right primitive to replace that bespoke encoding, or is the trading-specific encoding subtly different?
