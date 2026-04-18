# 058-014: `Analogy` — Stdlib Idiom for "A Is To B As C Is To ?"

**Scope:** algebra
**Class:** STDLIB
**Parent:** 058-ast-algebra-surface
**Foundation:** ../FOUNDATION.md
**Depends on:** 058-004-difference (or 058-019-subtract) — the named delta form

## The Candidate

A wat stdlib function that produces the classic VSA analogy completion:

```scheme
(define (Analogy a b c)
  (Bundle (list c (Difference b a))))
```

Expands to `c + (b - a)` — the classic "A is to B as C is to ?" vector arithmetic. The result is a vector that, under cleanup against a codebook of candidate answers, retrieves the fourth term of the analogy.

### Semantics

Given three thoughts forming the first three terms of an analogy (A, B, C), Analogy produces a thought that represents the FOURTH term — the completion. The vector-space intuition:

- The delta `B - A` captures the transformation from A to B.
- Applying the same transformation to C: `C + (B - A)`.
- Under cleanup to a codebook, this retrieves the element that has the same relationship to C as B has to A.

Classic example: `Analogy(king, queen, man)` ≈ `woman`.

## Why Stdlib Earns the Name

**1. Its expansion uses only existing core/stdlib forms.** Bundle is core; Difference is stdlib (058-004). Valid composition.

**2. It reduces ambiguity for readers.** `(Analogy king queen man)` reads as "king is to queen as man is to ?" — the analogy semantics are explicit. The raw `(Bundle (list man (Blend queen king 1 -1)))` is mechanically identical but requires the reader to decode the pattern.

Both criteria met.

## Arguments For

**1. Analogy is a foundational VSA operation with decades of literature.**

The analogical reasoning capability of VSA is one of its most-cited strengths. Kanerva, Plate, Eliasmith all describe analogy via the `A is to B as C is to ?` structure. Giving this pattern a named stdlib form acknowledges its centrality.

**2. The expansion is short but non-obvious.**

Three lines of decomposition explain what `Bundle(c, Difference(b, a))` does. Not immediately readable without VSA background. The name `Analogy` carries the semantic weight — readers who know VSA recognize it instantly.

**3. Composes with cleanup for the full retrieval pattern.**

The typical usage is:

```scheme
(cleanup
  (Analogy king queen man)
  candidates)
```

Where `cleanup` finds the nearest codebook entry. With `Analogy` named, this reads as "complete this analogy against the candidate pool." Without `Analogy`, the expression becomes `(cleanup (Bundle (list man (Difference queen king))) candidates)` — dense.

**4. Parallel structure with other VSA stdlib.**

If the algebra exposes `Bind`, `Bundle`, `Permute`, `Cleanup`, `Difference`, `Analogy` as a coherent set, users get the standard VSA toolkit with familiar names. Missing `Analogy` would force every VSA example to hand-roll the composition.

## Arguments Against

**1. It's one line of code.**

```scheme
(define (Analogy a b c)
  (Bundle (list c (Difference b a))))
```

One line. Is a named form earning its place for one line of expansion?

**Counter:** the stdlib criterion admits reader-clarity as sufficient justification. "One line of code that carries a famous semantic concept" is exactly the case where naming wins. Analogy is that case.

**2. Argument order: `(Analogy a b c)` for "a is to b as c is to ?"**

The order `a, b, c` is conventional, but the operation is asymmetric: `a → b` is the transformation, applied to `c`. Users might naturally write `(Analogy a b c)` expecting `b → c` (applied to `a`). Documentation must clarify.

**Mitigation:** the standard convention in VSA literature is `a, b, c` for "a is to b as c is to ?". Follow that. Document prominently.

**3. Depends on Difference (or Subtract).**

If 058-004-difference is rejected (e.g., in favor of just calling `Subtract`), the Analogy definition must use whichever named form wins. Not a structural blocker — just a naming concern.

**Mitigation:** Analogy's definition uses "the named delta form." If the name is `Difference`, use that. If it's `Subtract`, use that. Resolve after the delta-naming question settles.

**4. Compositional redundancy with rich direct VSA literature.**

Some users already write analogies inline. Adding a named form might not be used — users continue to write `(Bundle c (Difference b a))` out of habit.

**Mitigation:** the existence of a name doesn't force its use; it enables more readable code for those who want it. Adoption is organic. Stdlib's value is discoverability — an `Analogy` function in the stdlib announces "this pattern is supported and named."

## Example Usage

```scheme
;; Classical king-queen-man analogy
(define completion
  (cleanup (Analogy king queen man) vocabulary))

;; Trading analogy: "uptrend was to breakout as reversal is to ?"
(define predicted
  (cleanup (Analogy uptrend breakout reversal) candidate-patterns))

;; Sequence continuation
(define next-step
  (cleanup (Analogy step1 step2 step2) step-codebook))
```

The pattern is always: `cleanup` of `Analogy` against a candidate pool.

## Comparison

| Form | Class | Arity | Semantic |
|---|---|---|---|
| `Bundle(xs)` | CORE | list | Superposition |
| `Difference(a, b)` | STDLIB (058-004) | 2 | Delta from b to a |
| `Analogy(a, b, c)` | STDLIB (this) | 3 | c + (b - a) |

Analogy builds directly on Bundle and Difference — a two-level stdlib composition.

## Algebraic Question

Does Analogy compose with the existing algebra?

Yes — output is a vector in the ternary output space `{-1, 0, +1}^d` (Bundle of two ternary inputs, thresholded; see FOUNDATION's "Output Space" section). Composes cleanly with cleanup, similarity, further bundling.

Is it a distinct source category?

No — stdlib composition over Bundle + Difference.

## Simplicity Question

Is this simple or easy?

Simple. One line of expansion. Well-defined semantics.

Is anything complected?

No. Analogy has one role: "produce the completion of a three-term analogy." No other concerns mixed in.

Could existing forms express it?

Yes — `(Bundle (list c (Difference b a)))`. Name earns its place through reader clarity and canonical status in VSA literature.

## Implementation Scope

**Zero Rust changes.** Pure wat.

**wat stdlib addition** — one line:

```scheme
;; wat/std/reasoning.wat (or similar)
(define (Analogy a b c)
  (Bundle (list c (Difference b a))))
```

Depends on `Bundle` (core), `Difference` (stdlib, 058-004).

## Questions for Designers

1. **Dependency on 058-004's delta name.** This proposal uses `Difference`. If 058-019 names it `Subtract` instead, the expansion changes to `(Subtract b a)` or `(Blend b a 1 -1)` direct. The resolution should be consistent — one delta name in stdlib, used by Analogy.

2. **Argument order convention.** The standard `(a, b, c)` is "a is to b as c is to ?". Could alternatively be `(a, b, c, d)` returning a cleanup match, or `(from, to, apply-to)` with keyword-ish naming. Recommendation: stick with the three-term positional form, document clearly.

3. **Should the stdlib also provide the four-term `AnalogyCleanup`?** A convenience form that runs cleanup against a candidate pool:

```scheme
(define (AnalogyCleanup a b c candidates)
  (cleanup (Analogy a b c) candidates))
```

Over-naming risk, but this is the most common use case. Worth a second named form, or let users compose cleanup around Analogy manually?

4. **Domain applications.** In holon-lab-trading, are there specific analogy use cases? E.g., "trend phase X was to breakout as trend phase Y is to ?" This proposal's existence opens the door; concrete vocab applications should be tracked.

5. **Relationship to Plate/Kanerva's formulations.** Different VSA literature has subtly different analogy completions (circular convolution-based, binding-based, etc.). Is this formulation (Bundle-based with Difference) compatible with all of them? Document the chosen formulation.
