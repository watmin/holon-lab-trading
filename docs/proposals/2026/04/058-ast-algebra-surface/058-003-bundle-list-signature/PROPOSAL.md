# 058-003: `Bundle` — List-Argument Signature

**Scope:** algebra
**Class:** CORE (signature clarification, not a new variant)
**Parent:** 058-ast-algebra-surface
**Foundation:** ../FOUNDATION.md

## The Candidate

Clarify and lock `Bundle`'s signature as taking a single LIST argument (not variadic).

```scheme
(Bundle list-of-holons)    ; one argument — a list
```

Not:

```scheme
(Bundle a b c d)             ; variadic
```

## Current Ambiguity

Different descriptions of Bundle across the codebase, prior proposals, and holon documentation have used both forms. The implementation in holon-rs accepts a list, and the Python primer describes it as taking a list. But wat examples in the book and in earlier foundation drafts sometimes wrote Bundle as variadic.

The inconsistency is not harmful (variadic and list-taking are equivalent in expressive power), but it is a source of reader confusion and translation awkwardness. This proposal locks the signature.

## The Claim

`(Bundle list-of-holons)` is the canonical form.

- Takes exactly one argument
- That argument is a list of holons
- Produces `threshold(Σ encode(holon_i))` — element-wise sum + threshold

## Arguments For

**1. Consistency with holon-rs.**

The existing holon-rs `bundle` function accepts a list/vector of vectors and returns one vector. The wat form matching this signature eliminates translation friction between wat and Rust.

**2. Lisp idiomatic.**

List-taking is the natural Lisp form for any operation over a variable number of items:

```scheme
;; Composes with map:
(Bundle (map some-encoder raw-values))

;; Composes with filter:
(Bundle (filter proven? candidates))

;; Explicit list when needed:
(Bundle (list a b c))
```

Variadic Bundle forces `(apply Bundle (some-list))` at every indirection. The list-taking form composes cleanly without `apply`.

**3. Consistency with `Concurrent`, `Chain`, `Ngram`, `Array`, `Set`.**

These stdlib forms all take a single list argument, because they all delegate to Bundle internally. The list-taking form reads identically across the algebra — if you know one list-taking form, you know them all.

**4. No ambiguity at the parser level.**

`(Bundle a b c d)` could be parsed as "Bundle applied to 4 arguments" (variadic) or "Bundle applied to a, with b, c, d leftover" (error). `(Bundle (list a b c d))` is unambiguous.

## Arguments Against

**1. Lisp tradition has variadic operators.**

`(and a b c)`, `(or a b c)`, `(+ 1 2 3 4)` are variadic. Bundle could follow this convention.

**Counter:** Bundle's arguments are not atoms — they are holons (potentially complex ASTs). The Lisp tradition varies: variadic is natural for atomic arguments (boolean combinators, arithmetic); list-taking is natural for list-operating functions (`reduce`, `map`, `filter`). Bundle is more the latter — it REDUCES a list to a single vector.

**2. Variadic looks shorter for literal cases.**

`(Bundle a b c)` is three characters shorter than `(Bundle (list a b c))`.

**Counter:** Real-world uses of Bundle rarely have literal-known arguments. Vocab modules produce lists via `map`, and those go into Bundle. The literal case is the minority. Optimizing the syntax for the minority harms the common case.

**3. Breaking change for any code that used variadic Bundle.**

If any existing code was written as variadic, this is a breaking change.

**Counter:** The holon-rs implementation has always taken a list. Any wat code that was variadic was either conceptual (in design docs) or buggy (the interpreter would not handle it). Locking the signature at list-taking makes the wat match the implementation.

## Comparison to Nearest Existing Forms

| Form | Signature | Rationale |
|---|---|---|
| `Bundle` (this proposal) | `(Bundle list)` | Reduces list of holons to one vector |
| `Sequential` | `(Sequential list)` | Positional encoding of a list of holons |
| `Concurrent` | `(Concurrent list)` | Bundle wrapper |
| `Chain` | `(Chain list)` | Pairwise Thens bundled |
| `Ngram n` | `(Ngram n list)` | Sized windows, bundled |
| `Array` | `(Array list)` | Indexed bundle of holons |
| `Set` | `(Set list)` | Semantic alias for Bundle |
| `Bind` | `(Bind a b)` | Fixed-arity binary |
| `Blend` | `(Blend a b w1 w2)` | Fixed-arity 4-parameter |

Pattern: list-operating forms take lists; fixed-arity forms take positional arguments. Bundle belongs to the list-operating family.

## Algebraic Question

Does the list signature compose with the algebra?

Yes — it IS the algebra. Every upstream form that needs to combine multiple holons produces a list and hands it to Bundle (directly or via stdlib wrappers like Concurrent, Chain).

Does this change any algebraic property?

No. Bundle's semantics (element-wise sum + threshold, commutative over inputs) are unchanged. Only the surface form of the argument is clarified.

### Algebraic properties of Bundle

Under the algebra's ternary output space (FOUNDATION's "Output Space" section, `threshold(0) = 0`), Bundle is:

- **Commutative**: `Bundle([a, b]) = Bundle([b, a])` — order does not matter.
- **Similarity-associative under capacity budget**: `Bundle([a, b, c])` and its nested forms `Bundle([Bundle([a, b]), c])` / `Bundle([a, Bundle([b, c])])` produce vectors that are EQUIVALENT UNDER COSINE SIMILARITY at high d within the capacity budget. Elementwise associativity does NOT hold in general — intermediate thresholds clamp magnitudes ≥ 2 back to ±1, losing signal that would have been preserved in a flat sum. At d=1 with `x=+1, y=+1, z=-1`, the three forms produce `+1, 0, +1` respectively. At `d = 10,000` with bundle sizes inside the ~100-item budget, the similarity between nested and flat forms stays above 5σ, and downstream similarity-based consumers treat them as equivalent. Nesting costs capacity (same budget as crosstalk, sparse keys, cascading compositions); within budget, it's transparent. See FOUNDATION's "Algebraic laws under similarity measurement" for the full story.
- **Identity element**: the all-zero vector. `Bundle([a, 0⃗]) = a`.

These properties let Chain, Ngram, Sequential, and other list-operating stdlib forms compose cleanly at arbitrary nesting depth without accumulating representation error.

## Simplicity Question

Is this simple or easy?

Simple. One form. One argument. One semantic.

Is anything complected?

No. The signature names what Bundle IS — a reducer over a list of holons. The list-taking form is how the body is expressed; it doesn't smuggle other concerns.

Could existing forms express it?

Bundle already takes a list in holon-rs. This proposal is just locking the wat's surface form to match. No new expressiveness is needed or introduced.

## Implementation Scope

**Zero Rust changes.** holon-rs already takes a list.

**wat parser changes** — if the current wat parser accepts variadic Bundle (and normalizes to a list internally), the proposal narrows the accepted forms to one: the list-taking form. Variadic invocations, if ever permitted, should be rejected at parse time or automatically wrapped into a list with a deprecation warning.

**Documentation changes** — any prior docs, examples, or proposals that showed Bundle as variadic get updated to the list-taking form. FOUNDATION.md has already been updated.

## Questions for Designers

1. **Is the list form the right ergonomic tradeoff?** List-taking composes cleanly with `map` and `filter`, but requires `(list ...)` for literal cases. Does this serve the common use case well, given that vocab modules almost always generate Bundle inputs via list-producing operations?

2. **Should the parser accept both forms as aliases?** Lenient parsing would accept `(Bundle a b c)` and internally wrap into `(Bundle (list a b c))`. Strict parsing would reject variadic form. Lenient is user-friendly; strict preserves the one-form-one-meaning principle.

3. **Does this constrain future extensibility?** If we ever wanted Bundle to take additional parameters (e.g., `(Bundle list options)` for hypothetical parameterization), would the list-taking form make that addition awkward? Probably not — options could be a map parameter, same pattern as `Ngram n list`.

4. **Other list-operating forms.** Sequential, Concurrent, Chain, Ngram, Array, Set, Map — do all of them follow the list-taking convention, and is this proposal implicitly locking the convention across all of them? FOUNDATION.md uses the list form throughout; this proposal formalizes it.

5. **Is this worth its own proposal?** The change is small (documentation + possible parser strictness). Could have been bundled into a broader "wat form conventions" proposal. Arguments for its own proposal: the ambiguity was visible enough to be worth a named decision; the designers should review the form convention explicitly rather than having it slide in with other changes.
