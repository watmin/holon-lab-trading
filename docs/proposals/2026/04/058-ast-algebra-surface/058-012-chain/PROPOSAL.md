# 058-012: `Chain` — Bundle of Pairwise Thens

**Scope:** algebra
**Class:** STDLIB
**Parent:** 058-ast-algebra-surface
**Foundation:** ../FOUNDATION.md
**Depends on:** 058-011-then (pivotal — if Then is rejected, this must re-express via Bundle + Permute directly)

## The Candidate

A wat stdlib function that encodes a LIST of events as pairwise transitions:

```scheme
(define (Chain thoughts)
  (Bundle (pairwise-map Then thoughts)))
```

Where `pairwise-map` produces `(Then thoughts[0] thoughts[1])`, `(Then thoughts[1] thoughts[2])`, `(Then thoughts[2] thoughts[3])`, ... — a sliding window of Thens across adjacent pairs.

### Semantics

Chain captures "this sequence of events unfolded in this order, with each transition visible." Unlike Sequential (which encodes each item at its position relative to the start), Chain encodes each ADJACENT TRANSITION as a Then, then bundles all transitions together.

Reader intent: "these things happened in sequence; the sequence itself is the encoded information."

## Example

For `thoughts = [a, b, c, d]`:

```
pairwise-map Then = [(Then a b), (Then b c), (Then c d)]
                  = [(Bundle [a (Permute b 1)]),
                     (Bundle [b (Permute c 1)]),
                     (Bundle [c (Permute d 1)])]

Chain = (Bundle [(Then a b) (Then b c) (Then c d)])
```

Three pairwise transitions, bundled into one vector. The resulting vector contains evidence of the TRANSITIONS, not the absolute positions.

## Why Stdlib Earns the Name

**1. Its expansion uses only existing core/stdlib forms.** Bundle is core, Permute is core, Then is stdlib (058-011). Chain is a stdlib composition over stdlib and core primitives. Valid composition chain.

**2. It reduces ambiguity for readers.** `(Chain [rsi-divergent price-rise volume-spike entry])` reads as "these four stages unfolded in order." Without the named form, the vocab code must write the explicit pairwise Then bundling, and readers must infer the intent.

Both criteria met.

## Arguments For

**1. Common pattern in event-stream vocabularies.**

Any vocab that encodes stages, steps, or phases of a process wants Chain:
- Trade lifecycle: signal → entry → hold → exit
- Pattern formation: accumulation → breakout → retest → confirmation
- Thought cascade: observation → interpretation → decision → action

Having `Chain` as a named form makes these stage encodings one-liners.

**2. Captures pairwise transitions, not absolute positions.**

Sequential's positional encoding produces a vector where each item is labeled by its position (0, 1, 2, ...). Chain's pairwise encoding produces a vector where each TRANSITION is labeled (a→b, b→c, c→d).

These are categorically different encodings for different uses:
- Sequential: "the 3rd thing in this sequence was X"
- Chain: "X was followed by Y somewhere in this sequence"

Chain is superior for invariance to starting offset — a chain `[a, b, c]` and its shifted version in a longer sequence `[x, a, b, c, y]` share transitions `a→b` and `b→c`. Sequential doesn't share this invariance.

**3. Dimensionality efficient.**

Each transition is one bundled item. For a chain of length `n`, Chain produces `n-1` Then-bundled transitions, then bundles them together. The full Chain is a bundle of `n-1` elements. Fits within ternary vector capacity for reasonable `n` (the capacity limit of Bundle is ~d/2 before similarity breaks down).

**4. Composes with Ngram (058-013).**

Ngram generalizes Chain: n-wise adjacency rather than pairwise. For `n=2`, Ngram IS Chain. For `n=3`, Ngram encodes triplet-transitions. Chain is the `n=2` specialization with a short, readable name.

## Arguments Against

**1. Redundancy with Sequential at composition time.**

Chain and Sequential are both "encode a list of things in some order-aware way." Having both in stdlib means two names for "ordered list of thoughts," with subtly different encodings.

**Counter:** the encodings really are different. Sequential uses positional permutations; Chain uses pairwise Thens. Downstream operations (similarity, cleanup) behave differently on the two encodings. The name distinction corresponds to an encoding distinction, not a reader-style distinction.

**2. Dependency chain is long: Chain → Then → (Bundle, Permute).**

If Then (058-011) is rejected, Chain must re-express directly:

```scheme
(define (Chain thoughts)
  (Bundle
    (pairwise-map
      (lambda (a b) (Bundle (list a (Permute b 1))))
      thoughts)))
```

Works, but loses the readable Then layer. Then's presence makes Chain readable; without Then, Chain's expansion is cluttered.

**Mitigation:** this is a dependency, not a blocker. 058-011-then should resolve first; if it passes, Chain is clean; if it fails, Chain rewrites.

**3. `pairwise-map` may not exist in the wat stdlib.**

The expansion assumes a `pairwise-map` combinator (or equivalent: `map-pairs`, `zip-with-next`, `sliding-2`). If the wat stdlib does not yet have one, this proposal depends on its addition.

**Mitigation:** pairwise-map is easy to define:

```scheme
(define (pairwise-map f xs)
  (if (or (empty? xs) (empty? (rest xs)))
      '()
      (cons (f (first xs) (second xs))
            (pairwise-map f (rest xs)))))
```

Bundle this into Chain's definition or define it separately in the wat stdlib. Minor hygiene issue, not a blocker.

**4. Edge cases: empty or singleton input.**

What does `(Chain [])` mean? `(Chain [a])`? Both produce empty pairwise lists; bundling an empty list is degenerate (zero vector or error).

**Mitigation:** document the semantics:
- `(Chain [])` → zero vector or error
- `(Chain [a])` → `a` unchanged (or `(Bundle [a])` which equals `a`)
- `(Chain [a b])` → `(Then a b)`
- `(Chain [a b c ...])` → full pairwise bundle

These conventions should be consistent with Bundle's handling of short lists.

## Comparison

| Form | Class | Encoding | Invariance |
|---|---|---|---|
| `Sequential(xs)` | STDLIB | Position-permuted bundle | Position-sensitive (shift changes vector) |
| `Chain(xs)` | STDLIB (this) | Pairwise-Then bundle | Shift-invariant (transitions preserved) |
| `Ngram(n, xs)` | STDLIB (058-013) | n-wise pairwise bundle | Adjacent-n invariance |

Chain sits between Sequential (stricter, position-based) and Ngram (more general, n-wise windowed).

## Algebraic Question

Does Chain compose with the existing algebra?

Yes. Output is a vector in the ternary output space `{-1, 0, +1}^d` (Bundle of Bundles of Permutes, thresholded; see FOUNDATION's "Output Space" section). Same dimensional space. All downstream operations unchanged.

Is it a distinct source category?

No — it is a composition over Bundle and Then. Stdlib idiom.

## Simplicity Question

Is this simple or easy?

Simple — one line, clear intent.

Is anything complected?

No. Chain's role is "pairwise-Then bundle"; no other concerns smuggled in.

Could existing forms express it?

Yes — `(Bundle (pairwise-map Then xs))`, or if Then is rejected, the expanded Bundle/Permute form.

## Implementation Scope

**Zero Rust changes.** Pure wat.

**wat stdlib addition** — one line (given Then and pairwise-map exist):

```scheme
;; wat/std/sequences.wat (or similar)
(define (Chain thoughts)
  (Bundle (pairwise-map Then thoughts)))
```

If pairwise-map doesn't exist:

```scheme
(define (pairwise-map f xs)
  (if (or (empty? xs) (empty? (rest xs)))
      '()
      (cons (f (first xs) (second xs))
            (pairwise-map f (rest xs)))))

(define (Chain thoughts)
  (Bundle (pairwise-map Then thoughts)))
```

## Questions for Designers

1. **Edge case semantics.** What does `(Chain [])` produce? What does `(Chain [a])` produce? Proposal: empty → zero vector (or error, matching Bundle's empty behavior); singleton → `a` unchanged. Confirm conventions.

2. **Dependency on Then's resolution.** If Then (058-011) is rejected, Chain must re-express directly. Should this sub-proposal be explicitly deferred until Then resolves, or should both be reviewed together?

3. **Bounded vs. unbounded chain length.** For very long chains (hundreds of thoughts), the bundle's capacity is exhausted and individual transitions may not be recoverable via cleanup. Should Chain carry a length warning/limit, or is this a documentation concern only?

4. **Position information or not.** Chain encodes pairwise transitions but loses absolute position information (transition `a→b` in a long chain is indistinguishable from `a→b` at the start of a short chain). Is this the right tradeoff, or should Chain optionally encode starting position too?

5. **Relationship to Sequential.** Both are ordered encodings of lists. Should vocab modules prefer Chain (transition-aware) or Sequential (position-aware), and under what circumstances? Documentation guidance would help vocab authors choose.

6. **`Chain2`, `Chain3`, etc.?** If Chain becomes too restrictive (always pairwise), there may be pressure to add `Chain3` (triplet adjacency) and beyond. Ngram (058-013) generalizes this — the n=2 case is Chain, higher `n` is Ngram. Resolve by keeping Chain as the n=2 idiom and using Ngram for everything else.
