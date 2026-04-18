# 058-015: `Amplify`, `Subtract`, `Flip` — Stdlib Blend Idioms

**Scope:** algebra
**Class:** STDLIB (three related named forms)
**Parent:** 058-ast-algebra-surface
**Foundation:** ../FOUNDATION.md
**Depends on:** 058-002-blend (all three are Blend specializations)

## The Candidates

Three wat stdlib functions, each a named specialization of `Blend`:

```scheme
(define (Amplify x y s)
  (Blend x y 1 s))
;; Expands to: threshold(1·x + s·y) — boost component y in x by factor s

(define (Subtract x y)
  (Blend x y 1 -1))
;; Expands to: threshold(1·x + (-1)·y) — remove y's component from x linearly

(define (Flip x y)
  (Blend x y 1 -2))
;; Expands to: threshold(1·x + (-2)·y) — invert y's contribution, flipping dominance
```

All three are Blend calls with LITERAL weight combinations. Each has a distinct semantic intent.

### Semantics

- `Amplify(x, y, s)`: "increase the importance of y relative to x" by scalar factor `s`. If `y` is a direction you want to emphasize in `x`, Amplify with `s > 1`. If you want to slightly reduce, `0 < s < 1`.
- `Subtract(x, y)`: "remove y linearly from x." Sibling to `Difference` (058-004) — same expansion, different reader intent.
- `Flip(x, y)`: "invert y's contribution in x." Where `x` and `y` agree (both +1 or both -1), the result is pushed toward `-y`; where they disagree, result retains `x`. Used for adversarial inversion.

## Why Stdlib Earns the Name

Each is Blend with a specific weight combination. Under FOUNDATION's stdlib criterion:

1. **Its expansion uses only existing core forms.** Blend is core (058-002).
2. **It reduces ambiguity for readers.** Each named form communicates a distinct intent that raw Blend does not.

Both criteria met for all three.

## Arguments For

**1. Amplify has distinct semantic intent.**

"Boost this component" is a separate reader intent from "linearly combine these two vectors." `(Amplify x y 2)` says "make y twice as prominent in x." `(Blend x y 1 2)` says "weighted sum with weights 1 and 2." Both correct; the named form carries the INTENT.

**2. Subtract and Difference serve different reader contexts.**

- `Subtract(x, y)`: "remove y from x" — imperative framing, used in composition.
- `Difference(a, b)`: "the delta from b to a" — noun framing, used in observation.

Same math. Different reader contexts. See 058-004's Argument Against #1 for the full discussion; this proposal accepts both names.

**3. Flip captures an unusual but useful pattern.**

Flipping (weight `-2` instead of `-1`) is an operation some VSA implementations expose as "negation" or "inversion." It is NOT the same as negation-by-orthogonalization (058-005) — it is a SCALED LINEAR inversion. Having a name for it avoids confusion about which "negation" is meant.

**4. Together they enumerate the meaningful Blend weight combinations.**

FOUNDATION's original `Negate` proposal had three modes: subtract (weight `-1`), flip (weight `-2`), orthogonalize (computed weight). The first two are now Blend idioms (this proposal); the third is its own CORE form (058-005). This proposal closes out the original Negate concept by making the two linear modes stdlib.

## Arguments Against

**1. Proliferation: is each specialization worth a name?**

Three named forms for three weight combinations. Could argue each is trivial; just teach users to write `Blend` with the appropriate weights.

**Counter:** the same argument against every stdlib name. The threshold is "does this name communicate intent the core form does not?" For Amplify: yes (scaled emphasis vs. generic blend). For Subtract: yes (removal vs. generic blend). For Flip: yes (inversion vs. generic blend). All three earn their names.

**2. `Flip` may be misunderstood as bipolar negation.**

In many contexts, "flip" a bipolar vector means "multiply by -1" — the element-wise sign-flip. But `Flip(x, y)` uses weights `(1, -2)` — not `(-1, -1)` or `(-1, 0)`. Users reading "Flip" may expect the former.

**Mitigation:** document Flip's meaning as "invert y's contribution in x" (not "negate x"). If the word is too overloaded, consider alternatives: `Invert`, `Counter`, `Oppose`. Recommendation: the original holon library's term for this mode is "flip"; keep the name for consistency but document clearly.

**3. Amplify with `s = 1` is just Bundle of a pair.**

`(Amplify x y 1)` → `(Blend x y 1 1)` → `(Bundle (list x y))`. Redundant naming at `s = 1`. But Amplify with `s > 1` or `s < 0` is distinct. Edge case, not a blocker.

**Mitigation:** either document "Amplify at s=1 is Bundle" as a known identity, OR restrict Amplify to `s ≠ 1`. Former is cleaner.

**4. Could be a single parameterized form.**

One could argue for a single `BlendNamed(x, y, intent)` where `intent` is a keyword (:amplify :subtract :flip), and the stdlib dispatches to the appropriate weights.

**Counter:** stringly-typed intent dispatch is worse than three clear-named functions. Keep three distinct names.

## Comparison

| Form | Class | Weights | Semantic |
|---|---|---|---|
| `Blend(x, y, w1, w2)` | CORE | arbitrary literals | Generic weighted sum |
| `Amplify(x, y, s)` | STDLIB (this) | `(1, s)` | Boost component y by factor s |
| `Subtract(x, y)` | STDLIB (this) | `(1, -1)` | Remove y linearly from x |
| `Flip(x, y)` | STDLIB (this) | `(1, -2)` | Invert y's contribution |
| `Difference(a, b)` | STDLIB (058-004) | `(1, -1)` | The delta from b to a |
| `Orthogonalize(x, y)` | CORE (058-005) | `(1, -(x·y/y·y))` COMPUTED | Project-remove y's direction |

Four stdlib specializations plus one core form. `Subtract` and `Difference` share weights but differ in reader intent. `Orthogonalize` uses a computed weight (hence its core status).

## Algebraic Question

Do these idioms compose with the existing algebra?

Trivially — each is a Blend call. All downstream operations work unchanged.

Are they distinct source categories?

No — all are Blend specializations. Reader clarity is the reason for the naming.

## Simplicity Question

Is this simple or easy?

Simple. Three one-line stdlib forms.

Is anything complected?

Potentially, if the naming taxonomy becomes muddled. Mitigated by clear documentation: Amplify (scale), Subtract (remove), Flip (invert), Difference (delta), Orthogonalize (project-remove). Five operations; four linear, one projection-based. Clear roles.

Could existing forms express them?

Yes — all via Blend. Stdlib status is for reader clarity.

## Implementation Scope

**Zero Rust changes.** Pure wat.

**wat stdlib additions** — three one-line functions:

```scheme
;; wat/std/blends.wat (or similar)

(define (Amplify x y s)
  (Blend x y 1 s))

(define (Subtract x y)
  (Blend x y 1 -1))

(define (Flip x y)
  (Blend x y 1 -2))
```

## Questions for Designers

1. **`Subtract` vs `Difference`: keep both or unify?** Same math. The proposal keeps both (different reader contexts: imperative-removal vs. noun-delta). Alternative: keep only one and document the other as a pseudonym. Recommendation: keep both; the names aid clarity without harming the algebra.

2. **`Flip`'s naming clarity.** The weight `-2` is unintuitive. Is `Flip` the right word, or is there a better term for "linearly invert y's contribution with double-weight counter"? Alternatives: `InvertComponent`, `Counter`, `Oppose`. Recommendation: keep `Flip` (matches holon precedent), document carefully.

3. **Amplify with negative s.** `(Amplify x y -2)` = `(Flip x y)`. Should these be ENFORCED distinct (Amplify requires `s > 0`) or freely overlap (Flip is Amplify at `s = -2`)? Recommendation: allow overlap; document the relationship.

4. **Standalone `Boost`, `Attenuate` forms?** `Boost` (s > 1), `Attenuate` (0 < s < 1) are sometimes distinct enough to warrant names. Or are they just Amplify with conventional s values? Recommendation: stop at Amplify; avoid further proliferation.

5. **Dependency on 058-002-blend.** All three proposals depend on Blend passing. If Blend is rejected, these collapse — Subtract and Difference re-propose as core, Amplify and Flip disappear. Resolution order: Blend first, then these.

6. **Relation to `Orthogonalize` (058-005).** This proposal resolves the Negate three-modes question by splitting: subtract mode → Subtract (here), flip mode → Flip (here), orthogonalize mode → Orthogonalize (058-005). The three-mode Negate concept is gone. Are designers comfortable with this decomposition?
