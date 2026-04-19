# 058-012: `Chain` — Bundle of Pairwise Transitions

**Scope:** algebra
**Class:** ~~STDLIB~~ **REJECTED**
**Parent:** 058-ast-algebra-surface
**Foundation:** ../FOUNDATION.md

---

## REJECTED — 2026-04-18

**Redundant with `Bigram` (058-013's new named stdlib shortcut).**

Chain's proposed expansion — `(Bundle (pairwise-map (λ a b → (Sequential (list a b))) xs))` — is exactly `(Ngram 2 xs)` under the reframed Sequential (058-009, now bind-chain). Ngram at n=2 produces pairs, each Sequential-encoded, bundled. That's Bigram.

058-013 Ngram's reframe ships **Bigram** (`(:wat::std::Ngram 2 xs)`) as a named stdlib macro. Chain and Bigram are the same form. Keep the clearer name and the family (Bigram, Trigram, user-defined Pentagram, ...) — reject the redundant alias.

**What users who said "chain" write instead:**
- `(:wat::std::Bigram xs)` — the canonical name for pairwise transitions.
- `(:wat::std::Ngram 2 xs)` — the direct form if they prefer parameter-explicit.

**What this doesn't affect:**
- Ngram (058-013) stays ACCEPTED with its reframe.
- Sequential (058-009) stays ACCEPTED with its reframe.
- Bigram ships as a new named stdlib macro within 058-013's updated proposal.

Algebra stdlib: −1 form (Chain). +2 forms (Bigram, Trigram in 058-013). Net +1.

See FOUNDATION-CHANGELOG 2026-04-18 entry for the rejection + reframe record.

---

## Historical content (preserved as audit record)

## The Candidate

A wat stdlib macro (per 058-031-defmacro) that encodes a LIST of events as pairwise transitions:

```scheme
(:wat::core::defmacro (:wat::std::Chain (holons :AST) -> :AST)
  `(:wat::algebra::Bundle
    (pairwise-map
      (:wat::core::lambda ((a :Holon) (b :Holon) -> :Holon)
        (:wat::std::Sequential (:wat::core::vec a b)))
      ,holons)))
```

Where `pairwise-map` produces pairs of consecutive items. Each pair is wrapped in a binary `Sequential` (equivalent to `(Bundle (list a (Permute b 1)))` — position 0 for the first, position 1 for the second). All pairs are then bundled into one vector. The expansion at parse time resolves to only algebra-core operations (Bundle, Permute).

### Semantics

Chain captures "this sequence of events unfolded in this order, with each transition visible." Unlike Sequential (which encodes each item at its position relative to the start), Chain encodes each ADJACENT TRANSITION as a binary Sequential, then bundles all transitions together.

Reader intent: "these things happened in sequence; the sequence itself is the encoded information."

## Example

For `holons = (list a b c d)`:

```
pairwise pattern = (list (Sequential (list a b))
                         (Sequential (list b c))
                         (Sequential (list c d)))
                 = (list (Bundle (list a (Permute b 1)))
                         (Bundle (list b (Permute c 1)))
                         (Bundle (list c (Permute d 1))))

Chain = (Bundle (list (Sequential (list a b))
                      (Sequential (list b c))
                      (Sequential (list c d))))
```

Three pairwise transitions, bundled into one vector. The resulting vector contains evidence of the TRANSITIONS, not the absolute positions.

## Why Stdlib Earns the Name

**1. Its expansion uses only existing core/stdlib forms.** Bundle is core, Permute is core, Then is stdlib (058-011). Chain is a stdlib composition over stdlib and core primitives. Valid composition chain.

**2. It reduces ambiguity for readers.** `(Chain (list rsi-divergent price-rise volume-spike entry))` reads as "these four stages unfolded in order." Without the named form, the vocab code must write the explicit pairwise Then bundling, and readers must infer the intent.

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

Chain is superior for invariance to starting offset — a chain `(list a b c)` and its shifted version in a longer sequence `(list x a b c y)` share transitions `a→b` and `b→c`. Sequential doesn't share this invariance.

**3. Dimensionality efficient.**

Each transition is one bundled item. For a chain of length `n`, Chain produces `n-1` Then-bundled transitions, then bundles them together. The full Chain is a bundle of `n-1` elements. Fits within ternary vector capacity for reasonable `n` (the capacity limit of Bundle is ~d/2 before similarity breaks down).

**4. Composes with Ngram (058-013).**

Ngram generalizes Chain: n-wise adjacency rather than pairwise. For `n=2`, Ngram IS Chain. For `n=3`, Ngram encodes triplet-transitions. Chain is the `n=2` specialization with a short, readable name.

## Arguments Against

**1. Redundancy with Sequential at composition time.**

Chain and Sequential are both "encode a list of things in some order-aware way." Having both in stdlib means two names for "ordered list of holons," with subtly different encodings.

**Counter:** the encodings really are different. Sequential uses positional permutations; Chain uses pairwise Thens. Downstream operations (similarity, cleanup) behave differently on the two encodings. The name distinction corresponds to an encoding distinction, not a reader-style distinction.

**2. ~~Dependency chain~~ — resolved 2026-04-18.**

058-011 Then was REJECTED. Chain no longer depends on it; expansion inlines the binary Sequential pattern directly:

```scheme
(:wat::core::defmacro (:wat::std::Chain (holons :AST) -> :AST)
  `(:wat::algebra::Bundle
     (pairwise-map
       (:wat::core::lambda ((a :Holon) (b :Holon) -> :Holon)
         (:wat::std::Sequential (:wat::core::vec a b)))
       ,holons)))
```

Chain stays in stdlib because its encoding (transitional) is distinct from Sequential's (absolute-positional) — different pattern, different similarity semantics. Only the expansion changed, not the algebraic status.

**3. `pairwise-map` may not exist in the wat stdlib.**

The expansion assumes a `pairwise-map` combinator (or equivalent: `map-pairs`, `zip-with-next`, `sliding-2`). If the wat stdlib does not yet have one, this proposal depends on its addition.

**Mitigation:** pairwise-map is easy to define:

```scheme
(:wat::core::define (:wat::std::pairwise-map f xs)
  (:wat::core::if (:wat::core::or (:wat::core::empty? xs) (:wat::core::empty? (:wat::core::rest xs)))
      '()
      (:wat::core::cons (f (:wat::core::first xs) (:wat::core::second xs))
            (:wat::std::pairwise-map f (:wat::core::rest xs)))))
```

Bundle this into Chain's definition or define it separately in the wat stdlib. Minor hygiene issue, not a blocker.

**4. Edge cases: empty or singleton input.**

What does `(Chain (list))` mean? `(Chain (list a))`? Both produce empty pairwise lists; bundling an empty list is degenerate (zero vector or error).

**Mitigation:** document the semantics:
- `(Chain (list))` → zero vector or error
- `(Chain (list a))` → `a` unchanged (or `(Bundle (list a))` which equals `a`)
- `(Chain (list a b))` → `(Sequential (list a b))` — the binary-Sequential pattern
- `(Chain (list a b c ...))` → full pairwise bundle

These conventions should be consistent with Bundle's handling of short lists.

## Comparison

| Form | Class | Encoding | Invariance |
|---|---|---|---|
| `Sequential(xs)` | STDLIB | Position-permuted bundle | Position-sensitive (shift changes vector) |
| `Chain(xs)` | STDLIB (this) | Pairwise binary-Sequential bundle | Shift-invariant (transitions preserved) |
| `Ngram(n, xs)` | STDLIB (058-013) | n-wise pairwise bundle | Adjacent-n invariance |

Chain sits between Sequential (stricter, position-based) and Ngram (more general, n-wise windowed).

## Algebraic Question

Does Chain compose with the existing algebra?

Yes. Output is a vector in the ternary output space `{-1, 0, +1}^d` (Bundle of Bundles of Permutes, thresholded; see FOUNDATION's "Output Space" section). Same dimensional space. All downstream operations unchanged.

Is it a distinct source category?

No — it is a composition over Bundle and Sequential. Stdlib idiom, distinct encoding pattern.

## Simplicity Question

Is this simple or easy?

Simple — one line, clear intent.

Is anything complected?

No. Chain's role is "pairwise binary-Sequential bundle"; no other concerns smuggled in.

Could existing forms express it?

Yes — `(Bundle (pairwise-map (lambda (a b) (Sequential (list a b))) xs))`. Chain earns its name through the distinct transitional-encoding pattern and reader-clarity on a common use case.

## Implementation Scope

**Zero Rust changes beyond 058-031-defmacro's macro-expansion pass.** Pure wat.

**wat stdlib addition** — one macro, registered at parse time:

```scheme
;; wat/std/sequences.wat (or similar)
(:wat::core::defmacro (:wat::std::Chain (holons :AST) -> :AST)
  `(:wat::algebra::Bundle
     (pairwise-map
       (:wat::core::lambda ((a :Holon) (b :Holon) -> :Holon)
         (:wat::std::Sequential (:wat::core::vec a b)))
       ,holons)))
```

`pairwise-map` itself is a list combinator, not an AST-rewriting macro — it is a regular stdlib function used inside the macro expansion. If it doesn't exist yet:

```scheme
(:wat::core::define (:wat::std::pairwise-map (f :fn(Holon,Holon)->Holon) (xs :Vec<Holon>) -> :Vec<Holon>)
  (:wat::core::if (:wat::core::or (:wat::core::empty? xs) (:wat::core::empty? (:wat::core::rest xs)))
      '()
      (:wat::core::cons (f (:wat::core::first xs) (:wat::core::second xs))
            (:wat::std::pairwise-map f (:wat::core::rest xs)))))
```

The macro is registered at parse time (per 058-031-defmacro); every `(Chain ...)` invocation is rewritten to the pairwise-Bundle form before hashing. Nested `(Sequential ...)` forms expand further to core `(Bundle (list a (Permute b 1)))` in the same pass.

## Questions for Designers

1. **Edge case semantics.** What does `(Chain (list))` produce? What does `(Chain (list a))` produce? Proposal: empty → zero vector (or error, matching Bundle's empty behavior); singleton → `a` unchanged. Confirm conventions.

2. **Dependency on Then's resolution.** If Then (058-011) is rejected, Chain must re-express directly. Should this sub-proposal be explicitly deferred until Then resolves, or should both be reviewed together?

3. **Bounded vs. unbounded chain length.** For very long chains (hundreds of holons), the bundle's capacity is exhausted and individual transitions may not be recoverable via cleanup. Should Chain carry a length warning/limit, or is this a documentation concern only?

4. **Position information or not.** Chain encodes pairwise transitions but loses absolute position information (transition `a→b` in a long chain is indistinguishable from `a→b` at the start of a short chain). Is this the right tradeoff, or should Chain optionally encode starting position too?

5. **Relationship to Sequential.** Both are ordered encodings of lists. Should vocab modules prefer Chain (transition-aware) or Sequential (position-aware), and under what circumstances? Documentation guidance would help vocab authors choose.

6. **`Chain2`, `Chain3`, etc.?** If Chain becomes too restrictive (always pairwise), there may be pressure to add `Chain3` (triplet adjacency) and beyond. Ngram (058-013) generalizes this — the n=2 case is Chain, higher `n` is Ngram. Resolve by keeping Chain as the n=2 idiom and using Ngram for everything else.
