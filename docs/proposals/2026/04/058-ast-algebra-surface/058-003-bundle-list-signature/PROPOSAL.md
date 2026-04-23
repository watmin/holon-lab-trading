# 058-003: `Bundle` — List-Argument Signature

**Scope:** algebra
**Class:** CORE (signature clarification, not a new variant) — **INSCRIPTION amendment 2026-04-19**
**Parent:** 058-ast-algebra-surface
**Foundation:** ../FOUNDATION.md

---

## INSCRIPTION — 2026-04-19 — Capacity-guard cascade: return type becomes `:Result<wat::holon::HolonAST, :wat::holon::CapacityExceeded>`

Bundle's return type changed during the capacity-guard arc (session 2026-04-19). The shipped implementation — wat-rs commit `e63e428` — returns `:Result<wat::holon::HolonAST, :wat::holon::CapacityExceeded>`, not the bare `:wat::holon::HolonAST` this proposal originally locked. The "List-Argument Signature" lock remains unchanged: Bundle still takes exactly one `:Vec<wat::holon::HolonAST>` argument. What changed is the return type.

### Why the Result wrap

FOUNDATION's `:wat::config::capacity-mode` specifies four modes (`:silent` / `:warn` / `:error` / `:abort`) for handling frames whose constituent count exceeds Kanerva's capacity budget. Prior art in `holon-lab-trading/src/encoding/rhythm.rs` trimmed the list *before* Bundle by caller discipline; the new runtime guard enforces budget at dispatch time *inside* Bundle.

Under `:error` mode, the over-budget path needs a FIRST-CLASS error value — not a halt, not a panic, not a magic side-effect. `:Result<T, E>` is the algebra's existing sum-type machinery for fallible operations; Bundle joins the Result-returning tier that was previously occupied only by `:wat::core::eval-*!` and Rust-deps-shim output. Callers are *forced by the type system* to acknowledge the capacity case — either `match` explicitly or propagate via `:wat::core::try` (see 058-033-try).

Under `:silent` and `:warn`, Bundle still returns `Ok(h)` — the substrate produces the degraded vector; the author opted into the risk. Under `:abort`, the dispatcher never returns; `panic!` fires.

### Budget formula pinned

FOUNDATION's "Dimensionality" section used Kanerva's `d / (2·ln K)` with an informal "~100 at d=10k" footnote. The shipped implementation uses `budget = floor(sqrt(dims))`. At d=10_000 → 100 (matches the informal number exactly); at d=4_096 → 64; at d=1_024 → 32. The `K` factor drops away because the wat algebra is AST-primary — there is no codebook to distinguish against; the binding physical constraint is the noise floor, and `sqrt(d)` is the safe-side item count that keeps a bundle's single-element presence comfortably above the 5σ threshold. See FOUNDATION amendment 2026-04-19 for the detailed reasoning.

### Cascade to the stdlib

Every stdlib macro that expands to a Bundle now inherits the Result wrap:

- `:wat::holon::Ngram` — return type is now `:AST<Result<wat::holon::HolonAST, wat::holon::CapacityExceeded>>`.
- `:wat::holon::Bigram` — same (expands to `:wat::holon::Ngram 2 ...`).
- `:wat::holon::Trigram` — same (expands to `:wat::holon::Ngram 3 ...`).
- `:wat::std::HashMap`, `:wat::std::HashSet`, `:wat::std::Vec` — checker schemes updated when the constructor dispatchers route through Bundle (not all of them do today; tracked).
- `:wat::holon::Reject`, `:wat::holon::Project` — these use Blend, not Bundle; unaffected.

Callers of any Result-returning stdlib form either match or `try` at the call site.

### New CapacityExceeded struct

Per 058-030 amendment (struct runtime inscription 2026-04-19), the algebra gains a built-in struct:

```scheme
(:wat::core::struct :wat::holon::CapacityExceeded
  (cost   :i64)
  (budget :i64))
```

Fields match the struct's field declaration order: `cost` is what the Bundle was asked to hold; `budget` is what the substrate could hold. The auto-generated `:wat::holon::CapacityExceeded/cost` and `/budget` accessors read each field. Registered in `TypeEnv::with_builtins` — wat-rs's self-trust path for declaring its own `:wat::*` types.

### The canonical usage pattern

```scheme
(:wat::core::define (:app::build (items :Vec<wat::holon::HolonAST>)
                                 -> :Result<wat::holon::HolonAST, wat::holon::CapacityExceeded>)
  (Ok (:wat::core::try (:wat::holon::Bundle items))))

(:wat::core::define (:user::main -> :i64)
  (:wat::core::match (:app::build huge-list)
    ((Ok _) 0)
    ((Err e)
      (:wat::core::i64::-
        (:wat::holon::CapacityExceeded/cost e)
        (:wat::holon::CapacityExceeded/budget e)))))
```

### Implementation Reference

- wat-rs commit `e63e428` (2026-04-19) — Bundle dispatcher + checker scheme update
- `tests/wat_bundle_capacity.rs` — 9 end-to-end cases covering the four modes, the struct accessor round-trip, and the return-type mismatch refusal
- `src/runtime.rs::eval_algebra_bundle` — the runtime implementation with all four mode branches

### What did NOT change

- **List-argument signature.** Still `(Bundle list-of-holons)`. The 2026-04-18 lock holds.
- **Ternary output.** Still `threshold(Σ encode(holon_i))` — the addition of the Result wrap does not touch the algebraic operation itself.
- **Holon cost accounting.** The `Bundle(list) = N` cost rule (FOUNDATION "Capacity accounting per operation") is unchanged.

---

## The Candidate

Clarify and lock `Bundle`'s signature as taking a single LIST argument (not variadic).

```scheme
(:wat::holon::Bundle list-of-holons)    ; one argument — a list
```

Not:

```scheme
(:wat::holon::Bundle a b c d)             ; variadic
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
(:wat::holon::Bundle (:wat::core::map some-encoder raw-values))

;; Composes with filter:
(:wat::holon::Bundle (:wat::core::filter proven? candidates))

;; Explicit list when needed:
(:wat::holon::Bundle (:wat::core::vec a b c))
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
