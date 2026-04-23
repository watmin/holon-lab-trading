# 058-020: `Flip` — Stdlib Idiom for Linear Component Inversion

**Scope:** algebra
**Class:** ~~STDLIB~~ **REJECTED**
**Parent:** 058-ast-algebra-surface
**Foundation:** ../FOUNDATION.md

---

## REJECTED — 2026-04-18

**Three converging reasons.**

**(1) The proposal's Flip is a different operation from the primer's `flip`.** The primer (`series-001-002-holon-ops.md`) documents `flip(vec)` as **elementwise negation of a single vector** — `similarity(vec, flip(vec)) ≈ -1.0`, the "logical NOT of a vector." This proposal's `Flip(x, y)` is a **2-argument gated inversion** that expands to `(:wat::holon::Blend x y 1 -2)` — fundamentally a different operation. Two distinct operations wearing the same name would confuse readers who move between the primer and wat source.

**(2) Hickey's `-2` callout cannot be defended cleanly.** The proposal claimed `-2` is "the minimum inversion weight," but this is not quite true — any weight `w < -1` flips agreed dimensions after threshold (`-1.01`, `-1.5`, `-2`, `-10` all produce the same thresholded result). `-2` is the smallest convenient integer, not the minimum. The choice is a tradition-matching convention, not an algebraic property. The specific pre-threshold magnitude produced at `-2` vs `-3` matters only if a downstream consumer reads the pre-threshold float, which no operation in the 058 surface does.

**(3) No cited production use.** The proposal's rationale — "adversarial inversion, counter-signaling, trust inversion" — is described in the abstract; no challenge batch citation, no DDoS lab citation, no trading lab citation. Same pattern as Resonance (058-006) and ConditionalBind (058-007) — speculative primitive with no concrete application beyond unit tests.

**What users who need this write instead.** The operation exists regardless of the name: `(:wat::holon::Blend x y 1 -2)` inline, with a comment explaining the intent. No stdlib name required for a pattern nobody has used.

**What we preserve.** If the primer's single-arg elementwise negation ever needs a home, that is a different proposal — `(:wat::std::Negate v)` taking ONE argument, classical VSA "anti-vector" semantics, trivially expressed via Blend (`(Blend v v -1 0)` produces `-v` after threshold). That is a separately defensible addition when a real application motivates it; 058-020 as written did not make that case.

**What this doesn't affect.** Blend (058-002) stays accepted — Flip was only one of several downstream users, and the others (Amplify, Subtract, Circular) have documented applications. Subtract and Amplify remain stdlib macros; they are not at risk.

Algebra stdlib inventory loses one form: **16 stdlib forms** instead of 17.

See FOUNDATION-CHANGELOG 2026-04-18 entry for the rejection record.

---

## Historical content (preserved as audit record)

## The Candidate

A wat stdlib macro (per 058-031-defmacro) that inverts `y`'s contribution in a blend with `x`:

```scheme
(:wat::core::defmacro (:wat::std::Flip (x :AST) (y :AST) -> :AST)
  `(:wat::holon::Blend ,x ,y 1 -2))
;; Expands at parse time to: (:wat::holon::Blend x y 1 -2)
;; which computes: threshold(1·x + (-2)·y) — inverts y's sign contribution, double weighted
```

A Blend call with literal weights `(1, -2)`. Unlike Subtract (weight `-1`), Flip uses weight `-2` — enough to OVERPOWER `x` on dimensions where `y` agrees, effectively flipping the sign. Expansion happens at parse time, so `hash(AST)` sees only the canonical `Blend` form.

### Semantics

"Invert `y`'s contribution in `x`." Where `x` and `y` agreed (both +1 or both -1), the double-weighted negative of `y` dominates, so the result is pushed toward `-y`. Where `x` and `y` disagreed, `x` retains its sign.

This is one of the three classical "negation" modes in VSA. FOUNDATION originally considered it part of a multi-mode `Negate` form; 058-005 split it out (orthogonalize kept its own core form; subtract and flip became stdlib Blend idioms).

## Example

With `d = 5`, for dense-bipolar ternary inputs (all entries in `{-1, +1}`, no zeros in this example):

```
x      = [+1, -1, +1, -1, +1]
y      = [+1, -1, +1, +1, -1]
1·x    = [+1, -1, +1, -1, +1]
-2·y   = [-2, +2, -2, -2, +2]
sum    = [-1, +1, -1, -3, +3]
threshold = [-1, +1, -1, -1, +1]

result = [-1, +1, -1, -1, +1]

Compare to y:    [+1, -1, +1, +1, -1]
Compare to -y:   [-1, +1, -1, -1, +1]

Flip pushes result toward -y on agreed dimensions (0, 1, 2, 4).
On disagreed dimension (3), x's sign (-1) is preserved.
```

## Why Stdlib Earns the Name

Under FOUNDATION's stdlib criterion:

1. **Its expansion uses only existing core forms.** Blend is core (058-002).
2. **It reduces ambiguity for readers.** `(Flip x y)` communicates a specific operation (linear inversion). The raw `(Blend x y 1 -2)` doesn't reveal the purpose of the specific weight `-2`.

Both criteria met.

## Arguments For

**1. The `-2` weight is not obvious.**

Subtract uses weight `-1` (intuitive: subtract the thing). Flip uses `-2` (less intuitive: double-negate to overpower). Readers encountering `(Blend x y 1 -2)` in vocab code must decode: "why -2? what's the intent?"

`(Flip x y)` communicates the intent directly — "flip y's role in x."

**2. Flip is the original Negate mode's stdlib home.**

FOUNDATION's predecessor `Negate(x, y, mode)` had three modes:
- `subtract`: weight `-1` → now Subtract (058-019)
- `flip`: weight `-2` → now Flip (this proposal)
- `orthogonalize`: computed weight → now Orthogonalize (058-005, core)

The split put subtract and flip in stdlib (they're Blend idioms) and kept orthogonalize in core (it has a computed weight that Blend doesn't support). This proposal is where flip lands.

**3. Used in adversarial/counter-pattern contexts.**

Flip's specific weight pattern `(1, -2)` is useful for:
- Adversarial inversion: "what is the opposite of y in x's context?"
- Counter-signaling: boost the anti-pattern when y is present
- Trust inversion: the complement of y's directional contribution

These are domain-specific vocabularies that benefit from a short, named form.

## Arguments Against

**1. The name "Flip" is overloaded.**

"Flip a vector" commonly means "multiply by -1" elementwise (negate the sign). `(Flip x y)` here does NOT mean "negate x" — it means "invert y's contribution in x's blend." The overload may confuse readers.

**Mitigation:** document the semantics carefully. Alternative names: `Invert`, `Counter`, `Oppose`. But `Flip` is the term used in the original holon library for this operation, and changing it introduces inconsistency with existing code. Recommendation: keep `Flip`; document thoroughly.

**2. The weight `-2` is arbitrary-looking.**

Why -2 and not -3 or -1.5? The specific value `-2` is chosen because:
- `-2y` is enough to flip agreed dimensions: `1·x + (-2)·y` where `x[i] = y[i] = +1` gives `-1`, i.e., flipped from `+1`
- Stronger weights (e.g., `-3`) produce the same flipped sign but with larger magnitude before threshold
- `-1` (Subtract's weight) is NOT strong enough to flip; `x[i] - y[i] = 0`, which thresholds ambiguously

So `-2` is the MINIMUM inversion weight. Not arbitrary, but the convention is worth naming explicitly.

**Mitigation:** document the weight's derivation — "Flip uses `-2` as the minimum inversion weight for dense-bipolar inputs; this is the conventional value. For ternary inputs with zero entries, those positions contribute nothing to the weighted sum and threshold to `0` per FOUNDATION's 'Output Space' section."

**3. Overlap with `Amplify(x, y, -2)`.**

`(Flip x y)` ≡ `(Amplify x y -2)` ≡ `(Blend x y 1 -2)`. Three names for one operation at the specific weight.

**Mitigation:** precedence by specificity. For `s = -2` specifically, use `Flip`. For arbitrary `s`, use `Amplify`. For explicit weight control, use `Blend`. Matches the convention for Subtract/Amplify/Blend overlap.

**4. Low usage frequency.**

Flip's use cases (adversarial contexts, counter-patterns) are narrower than Subtract (removal, detrending) or Amplify (emphasis). If usage is rare, does it merit a dedicated stdlib name?

**Counter:** stdlib names exist to MAKE operations discoverable and readable when they are used. Rare-but-important use cases benefit most from a clear name — when Flip is written, readers need to recognize it immediately. A rare pattern hiding in a `(Blend x y 1 -2)` call is WORSE than a rare pattern named `(Flip x y)`. Stdlib clarity serves rare cases as much as common ones.

## Comparison

| Form | Class | Weights | Semantic |
|---|---|---|---|
| `Blend(x, y, w1, w2)` | CORE | arbitrary | Generic weighted sum |
| `Amplify(x, y, s)` | STDLIB macro (058-015) | `(1, s)` | Parameterized emphasis |
| `Subtract(x, y)` | STDLIB macro (058-019) | `(1, -1)` | Linear removal |
| `Flip(x, y)` | STDLIB macro (this) | `(1, -2)` | Linear inversion |
| `Orthogonalize(x, y)` | CORE (058-005) | `(1, computed)` | Project-remove direction |

Flip is the specific `-2` case; Amplify is the parameterized form; Subtract is the specific `-1` case; Orthogonalize is the COMPUTED-weight case (can't be Blend-expressed).

## Algebraic Question

Does Flip compose with the existing algebra?

Trivially — it IS Blend. All downstream operations work.

Is it a distinct source category?

No. Blend specialization. Stdlib.

## Simplicity Question

Is this simple or easy?

Simple. One-line stdlib.

Is anything complected?

The name Flip is semantically loaded (overlaps with generic "negate"). Documentation mitigates. Overlap with Amplify(-2) is expected name-precedence.

Could existing forms express it?

Yes — `(Blend x y 1 -2)`. Named form earns its place via the inversion-intent reader clarity.

## Implementation Scope

**Zero Rust changes beyond 058-031-defmacro's macro-expansion pass.** Pure wat.

**wat stdlib addition** — `wat/std/blends.wat`:

```scheme
(:wat::core::defmacro (:wat::std::Flip (x :AST) (y :AST) -> :AST)
  `(:wat::holon::Blend ,x ,y 1 -2))
```

Registered at parse time (per 058-031-defmacro): every `(Flip x y)` invocation is rewritten to `(Blend x y 1 -2)` before hashing.

## Questions for Designers

1. **Naming: `Flip` or alternative?** "Flip" overloads with "negate a vector" in general VSA usage. Alternatives: `Invert`, `Counter`, `Oppose`. Recommendation: keep `Flip` to match holon's existing naming; document clearly.

2. **Rigor of the `-2` weight.** Flip's weight `-2` is the MINIMUM value that flips agreed dimensions. Larger negative weights (`-3`, `-4`) produce the same flipped sign but differ in pre-threshold magnitude. Should Flip's stdlib form offer a strength parameter (`Flip(x, y, strength)`) or fix at `-2`? Recommendation: fix at `-2` (canonical minimum); users wanting stronger inversion use Amplify with their chosen negative weight.

3. **Usage patterns in holon-lab-trading.** Are there domain vocabularies that need Flip specifically? If not, the stdlib name is theoretical — useful for completeness but not load-bearing for current work.

4. **Dependency on 058-002-blend.** If rejected, Flip re-proposes as part of a core Negate variant (reverts to FOUNDATION's original 3-mode plan).

5. **Relationship to Orthogonalize.** Flip is linear inversion; Orthogonalize removes the projected direction. Flip is cheap; Orthogonalize requires a dot product. Documentation should distinguish when to use each — "are you removing y linearly (Flip) or removing y's direction geometrically (Orthogonalize)?"

6. **Is Flip the right completion of the Negate trilogy?** Original Negate had subtract/flip/orthogonalize modes. This proposal completes the trilogy with Flip as the stdlib companion to Subtract and the non-core companion to Orthogonalize. Are designers satisfied with this split, or would they prefer a different decomposition?
