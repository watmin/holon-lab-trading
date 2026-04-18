# 058-015: `Amplify` — Stdlib Idiom for Scaled Component Emphasis

**Scope:** algebra
**Class:** STDLIB
**Parent:** 058-ast-algebra-surface
**Foundation:** ../FOUNDATION.md
**Depends on:** 058-002-blend
**Companion proposals:** 058-019-subtract, 058-020-flip

## The Candidate

A wat stdlib macro (per 058-031-defmacro) that scales the contribution of `y` in a blend with `x`:

```scheme
(defmacro Amplify (x y s)
  `(Blend ,x ,y 1 ,s))
;; Expands at parse time to: (Blend x y 1 s)
;; which computes: threshold(1·x + s·y) — boost component y in x by factor s
```

A Blend call with literal weights `(1, s)`. The first weight stays at 1 (anchor `x` at unit emphasis); the second is a user-supplied scalar `s` (control the relative weight of `y`). Expansion happens at parse time, so `hash(AST)` sees only the canonical `Blend` form.

### Semantics

Amplify means "increase the importance of `y` relative to `x`." If `y` is a direction or pattern you want to emphasize in `x`:
- `s > 1`: boost `y` above `x`'s weight
- `0 < s < 1`: partial dampening of `y`
- `s = 1`: equal blend (same as `Bundle [x y]`)
- `s = 0`: `x` only, `y` silenced
- `s < 0`: negative emphasis — `y` counteracts

## Why Stdlib Earns the Name

Under FOUNDATION's stdlib criterion:

1. **Its expansion uses only existing core forms.** Blend is core (058-002).
2. **It reduces ambiguity for readers.** `(Amplify x y 2)` communicates "make `y` twice as prominent in `x`." `(Blend x y 1 2)` communicates "weighted sum with weights 1 and 2" — the reader must infer the emphasis intent.

Both criteria met.

## Arguments For

**1. The "boost a component" intent is distinct from generic blending.**

Amplify frames the operation as "take `x` as the anchor, scale `y`'s emphasis by `s`." Generic Blend frames it as "weighted sum with two weights." Same math, different reader framings.

Vocab modules that want to emphasize a detected pattern in a noisy observation can write:

```scheme
(Amplify observation pattern 3)   ; triple the pattern's weight
```

Rather than:

```scheme
(Blend observation pattern 1 3)   ; mechanically equivalent
```

The first reads as intent. The second reads as mechanics.

**2. Parameterization with one scalar is ergonomic.**

Blend takes two weight scalars. Amplify takes one — the amplification factor. The implicit "anchor weight = 1" is conventional and convenient.

For attention-like operations: `(Amplify context focus-strength)` reads cleanly. `(Blend context focus 1 strength)` forces the reader to understand why one weight is 1.

**3. Parallel to `Subtract` and `Flip` in 058-019 and 058-020.**

Amplify, Subtract, Flip are all Blend idioms with specific literal weight patterns. Each has distinct reader intent:
- Amplify: variable emphasis factor
- Subtract: linear removal at weight -1
- Flip: linear inversion at weight -2

Different idioms, same underlying primitive.

## Arguments Against

**1. Trivial expansion.**

```scheme
(defmacro Amplify (x y s)
  `(Blend ,x ,y 1 ,s))
```

One-line expansion. Three tokens replaced by three tokens (`Amplify x y s` ≈ `Blend x y 1 s`). Is the name earning its place for a one-token "savings"?

**Counter:** the savings are cognitive, not tokens. "Amplify y by s" is read-once intent. "Blend x y 1 s" is three-step decoding: "blend, first weight 1, second weight s, so weighted emphasis." The named form carries the semantic directly.

**2. Overlap with Bundle at `s = 1` and with `Subtract`/`Flip` at specific negatives.**

- `(Amplify x y 1)` ≡ `(Bundle [x y])` — redundant at `s = 1`
- `(Amplify x y -1)` ≡ `(Subtract x y)` — redundant at `s = -1`
- `(Amplify x y -2)` ≡ `(Flip x y)` — redundant at `s = -2`

Three redundancies. Each specific value collapses to a more-specific name.

**Mitigation:** Amplify is the GENERAL parameterized form. Subtract and Flip are specific named values. Overlap is expected; it is how parameterized forms relate to their specific specializations. Readers pick the most specific name that applies.

**3. Could be a method on Bundle / parameter on Blend.**

Alternative: extend Blend's interface to accept "amplify" as a keyword-ish convention:

```scheme
(Blend x y :amplify 2)  ; syntactic sugar for weights (1, 2)
```

Or make Bundle variadic with weights:

```scheme
(Bundle [x y] :weights [1 2])
```

**Counter:** both alternatives complicate core interfaces. Keeping Amplify as a stdlib form preserves Blend's clean 4-arg signature and keeps the naming explicit. Stringly-typed keyword dispatch is WORSE than a named wrapper.

**4. Is this just a rename?**

`(Amplify x y s)` and `(Blend x y 1 s)` are mechanically identical. The named form is sugar. Does sugar earn its place?

**Counter:** same argument as Subtract (058-019) vs Blend(1, -1). FOUNDATION's stdlib criterion explicitly admits reader clarity as justification for a name. Amplify passes that criterion.

## Comparison

| Form | Class | Weights | Semantic |
|---|---|---|---|
| `Blend(x, y, w1, w2)` | CORE | arbitrary literals | Generic weighted sum |
| `Amplify(x, y, s)` | STDLIB (this) | `(1, s)` | Scale y's emphasis by factor s |
| `Subtract(x, y)` | STDLIB macro (058-019) | `(1, -1)` | Remove y linearly from x |
| `Flip(x, y)` | STDLIB macro (058-020) | `(1, -2)` | Invert y's contribution |
| `Bundle([x, y])` | CORE | `(1, 1)` | Equal superposition |

Amplify is the parameterized macro; Subtract and Flip are specific-weight macros; Bundle-of-pair is the core form at `(1, 1)`. 058-004-difference is REJECTED; Subtract is the canonical delta macro.

## Algebraic Question

Does Amplify compose with the existing algebra?

Trivially — it IS Blend. All downstream operations work.

Is it a distinct source category?

No — Blend specialization. The naming carries intent.

## Simplicity Question

Is this simple or easy?

Simple. One-line stdlib form.

Is anything complected?

Potentially if users pick the wrong idiom. Mitigated by documentation: use Amplify for general scaling, Subtract for removal, Flip for inversion, Difference for deltas.

Could existing forms express it?

Yes — `(Blend x y 1 s)`. Named form earns its place via reader clarity.

## Implementation Scope

**Zero Rust changes beyond 058-031-defmacro's macro-expansion pass.** Pure wat.

**wat stdlib addition** — `wat/std/blends.wat`:

```scheme
(defmacro Amplify (x y s)
  `(Blend ,x ,y 1 ,s))
```

Registered at parse time (per 058-031-defmacro): every `(Amplify x y s)` invocation is rewritten to `(Blend x y 1 s)` before hashing.

## Questions for Designers

1. **`s = 1` degeneracy.** `(Amplify x y 1)` ≡ `(Bundle [x y])`. Should Amplify document this, or restrict `s ≠ 1`? Recommendation: document, don't restrict.

2. **Negative `s` overlap with Subtract / Flip.** `(Amplify x y -1)` ≡ `(Subtract x y)`, `(Amplify x y -2)` ≡ `(Flip x y)`. Recommendation: freely allow overlap; stylistic preference picks the most specific name.

3. **Attenuation variant?** Some applications want "reduce `y`'s contribution" specifically (`0 < s < 1`). Could be a named variant `Attenuate` for clarity. Recommendation: no — avoid further proliferation. `(Amplify x y 0.5)` suffices; if users want a name for attenuation they can define their own stdlib macro.

4. **Dependency on Blend.** If 058-002 rejects, Amplify cannot exist. Resolution order: Blend first.

5. **Related trading-domain idioms.** In holon-lab-trading, the manager aggregates observer opinions — an Amplify pattern (observer X is weighted higher based on its conviction). Does this vocab fit Amplify cleanly? Concrete usage would validate the form.
