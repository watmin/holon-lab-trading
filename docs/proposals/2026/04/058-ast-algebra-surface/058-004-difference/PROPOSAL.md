# 058-004: `Difference` — Stdlib Idiom over `Blend`

**Scope:** algebra
**Class:** STDLIB (reclassified from CORE during sub-proposal review)
**Parent:** 058-ast-algebra-surface
**Foundation:** ../FOUNDATION.md
**Depends on:** 058-002-blend (pivotal — if Blend is rejected, this proposal must be rewritten)

## Reclassification Note

FOUNDATION.md originally listed `Difference` as a CORE candidate — element-wise subtraction + threshold, characterized as an operation not expressible in existing primitives. That characterization was correct ONLY IF `Blend` did not exist.

Once `Blend(a, b, w1, w2) = threshold(w1·a + w2·b)` is admitted as core, `Difference(a, b) = threshold(a - b)` is algebraically identical to `Blend(a, b, 1, -1)`. The subtraction operation disappears as a new algebraic primitive; it reappears as a specific Blend weighting.

This proposal now argues `Difference` as a STDLIB form — a wat function that expands to `Blend` with a specific weight combination — rather than as a new core variant.

## The Candidate

A wat stdlib function that produces the element-wise difference of two thoughts:

```scheme
(define (Difference a b)
  (Blend a b 1 -1))
;; Expands to: threshold(1·a + (-1)·b) = threshold(a - b)
```

### Semantics

The delta from `b` to `a`. Dimensions where `a` is +1 and `b` is -1 (or vice versa) produce strong signal. Dimensions where they agree cancel toward zero.

### Usage patterns

```scheme
;; "What changed between two thoughts?"
(Difference thought-new thought-old)

;; "What is anomalous in a relative to baseline?"
(Difference observed baseline)

;; "Feature extraction via contrast:"
(Difference candle-now candle-previous)
```

## Why Stdlib Earns the Name

`Difference` is a SPECIFIC use case of `Blend` that reads clearly in vocab code. A module that computes "the change between two observations" wants to write `(Difference obs-now obs-prev)`, not `(Blend obs-now obs-prev 1 -1)`. The named form communicates intent.

Under FOUNDATION's stdlib criterion:
1. **Its expansion uses only existing core forms.** `Blend` is core (per 058-002).
2. **It reduces ambiguity for readers.** Without the named form, every vocab module that computes deltas writes `Blend(..., 1, -1)` — and readers must recognize the pattern. With the named form, the intent is explicit.

Both criteria met.

## Arguments For

**1. Differences are a recurring semantic concept.**

Across vocab modules, distinctions between "current vs prior," "observed vs baseline," "snapshot vs reference" are common. The delta operation has its own name in the domain because it has its own role.

**2. The stdlib form is one line.**

```scheme
(define (Difference a b) (Blend a b 1 -1))
```

No implementation complexity. Just a named composition over Blend.

**3. Analogy needs it.**

058-014-analogy defines `(Analogy a b c) → (Bundle (list c (Difference b a)))` — "A is to B as C is to ?", computing `C + (B - A)`. Having a named `Difference` form makes Analogy's definition readable.

Without `Difference`, Analogy's body is `(Bundle (list c (Blend b a 1 -1)))` — mechanically correct but harder to read.

**4. It composes cleanly with other stdlib idioms.**

```scheme
;; "how different is x from y, in the direction of z?"
(Resonance (Difference x y) z)

;; "the delta, amplified:"
(Amplify (Difference x y) reference strength)
```

Stdlib idioms compose with each other naturally.

## Arguments Against

**1. Potential redundancy with `Subtract`.**

058-015-blend-idioms proposes `Subtract(x, y) = Blend(x, y, 1, -1)`. That is the SAME expansion as `Difference(a, b)`. Two names for the identical operation.

Should both exist, or should they unify into one name?

- Case for both: they serve different READER contexts. `Difference` implies "delta between two observations." `Subtract` implies "remove a component." Different intents, same math.
- Case for one: the algebra doesn't distinguish the use cases — the operation is identical. Having two names for one operation is complection by redundancy.

The designers should resolve. My lean: keep both, because they aid READER clarity without changing the algebra. But it is a design choice, not a technical necessity.

**2. If `Blend` is rejected, this proposal collapses.**

This sub-proposal has a hard dependency on `Blend`. If Blend doesn't pass, `Difference` must re-propose as a new core operation (the original classification) — `threshold(a - b)` is not derivable from Bind/Bundle/Permute alone.

The dependency is acknowledged explicitly. This sub-proposal should not be resolved before 058-002-blend resolves.

**3. Hickey's bar: a stdlib form for a one-line expansion?**

`(Blend a b 1 -1)` is six tokens. `(Difference a b)` is three. The savings are real but modest. Is the clarity gain worth adding a stdlib name?

Mitigation: the clarity gain is not just in token count. It is in the intent that the name communicates. Readers scanning vocab code recognize `Difference` semantically; they have to decode `Blend(..., 1, -1)` into "oh, this is subtraction" before the meaning lands. The name is ergonomic; the savings are cognitive.

## Comparison

| Form | Class | Weights | Semantic |
|---|---|---|---|
| `Blend(a, b, w1, w2)` | CORE | arbitrary | General scalar-weighted combination |
| `Amplify(x, y, s)` | STDLIB | `(1, s)` | Boost component y in x by factor s |
| `Subtract(x, y)` | STDLIB | `(1, -1)` | Remove y from x |
| `Difference(a, b)` | STDLIB (this) | `(1, -1)` | The delta from b to a |

`Subtract` and `Difference` have identical weights and identical math. The only difference is the NAME — and the READER CONTEXT that name invokes.

## Algebraic Question

Does `Difference` compose with the existing algebra?

Yes — trivially. It is a named form over `Blend`, which is core. All downstream operations work on the output of `Difference` without modification.

Is it a distinct source category?

No — it is the same source category as `Blend`. The naming is for reader clarity, not for categorical distinctness.

## Simplicity Question

Is this simple or easy?

Simple, but adds a name. Whether the name earns its place depends on the reader-clarity bar — which FOUNDATION's stdlib criterion admits as valid.

Is anything complected?

Potentially — if `Subtract` also exists as a separate stdlib name for the same operation, we have two names for one thing. Mitigated by context: `Subtract` is the "remove component" idiom, `Difference` is the "compute delta" idiom. Different reader intents.

Could existing forms express it?

Yes — `(Blend a b 1 -1)`. The proposal argues that the named form improves readability in vocab code.

## Implementation Scope

**Zero Rust changes.** This is pure wat.

**wat stdlib addition:**

```scheme
(define (Difference a b)
  (Blend a b 1 -1))
```

Lives in whichever wat file holds the stdlib (likely `wat/std/thoughts.wat` or similar — see open question 1 in FOUNDATION.md).

**Cache behavior:**

`(Difference a b)` and `(Blend a b 1 -1)` produce the same vector. The cache key is on the AST — so `Difference(a, b)` and `Blend(a, b, 1, -1)` get DIFFERENT cache entries (different AST shapes) that happen to share the same vector.

If this redundancy is a problem (it probably isn't, at sub-thousand-entries scale), a canonicalization pass could rewrite stdlib forms to their expansions before caching. Or the stdlib form could be fully desugared at parse time, at the cost of losing the semantic name in AST-walking contexts. This is a tooling decision outside FOUNDATION.

## Questions for Designers

1. **Should `Difference` and `Subtract` both exist?** Same math. Different reader intent. Case for both: serves readers scanning for different patterns. Case for one: avoid complection by redundancy. Which way does Hickey's simplicity principle lean here?

2. **If only one, which?** "Subtract" is imperative-ish. "Difference" is noun-ish. The stdlib of most Lisps would use `Subtract` for the operation and `Difference` for the result of applying it to observations. Under that convention, `Subtract` might be the primary name and `Difference` a documentation alias.

3. **Dependency on Blend's resolution.** This sub-proposal CANNOT resolve before 058-002-blend. If Blend is rejected, Difference must re-propose as a core variant (subtraction is then genuinely a new operation not expressible in existing primitives). Should the resolution of this sub-proposal be explicitly deferred until Blend resolves?

4. **Stdlib name for the `Analogy` context.** Analogy needs a named delta operation: `C + (B - A)`. Both `Difference(B, A)` and `Subtract(B, A)` work mathematically. The Analogy sub-proposal (058-014) should be consistent with whichever stdlib name wins here.

5. **Classification change precedent.** This sub-proposal was moved from CORE to STDLIB during sub-proposal review, after realizing the Blend dependency. Is this the right procedure — reclassifying mid-review when downstream effects become clear — or should it have been anticipated earlier? Lessons for future batch proposals.
