# 058-019: `Subtract` — Stdlib Idiom for Linear Component Removal

**Scope:** algebra
**Class:** STDLIB
**Parent:** 058-ast-algebra-surface
**Foundation:** ../FOUNDATION.md
**Depends on:** 058-002-blend
**Companion proposals:** 058-015-amplify, 058-020-flip, 058-004-difference (shares expansion)

## The Candidate

A wat stdlib function that linearly removes `y`'s contribution from `x`:

```scheme
(define (Subtract x y)
  (Blend x y 1 -1))
;; Expands to: threshold(1·x + (-1)·y) — linearly subtract y from x
```

A Blend call with literal weights `(1, -1)`. Identical math to `Difference(a, b)` (058-004) — the only distinction is reader intent.

### Semantics

"Remove `y`'s contribution from `x`." Dimensions where `y` contributes the same sign as `x` get attenuated toward zero; dimensions where they differ survive or flip. Classical element-wise linear subtraction with threshold.

## Why Stdlib Earns the Name

Under FOUNDATION's stdlib criterion:

1. **Its expansion uses only existing core forms.** Blend is core (058-002).
2. **It reduces ambiguity for readers.** `(Subtract x y)` reads as "remove y from x." The raw `(Blend x y 1 -1)` requires the reader to recognize the weight pattern and infer the intent.

Both criteria met.

## Arguments For

**1. "Remove a component" is a distinct reader intent.**

Vocab modules that want to cleanse an observation of a known pattern use subtraction framing:

```scheme
(Subtract observation known-noise)     ; strip the known noise
(Subtract signal trend)                 ; detrend the signal
(Subtract candidate prototype)          ; extract deviation
```

Reading as "strip, detrend, extract" is immediate. Reading as `Blend(..., 1, -1)` forces mechanical decoding.

**2. Imperative framing complements Difference's noun framing.**

- `Subtract(x, y)`: "remove y from x" — imperative, emphasizes the action
- `Difference(a, b)`: "the delta from b to a" — noun, emphasizes the result

Same math. Two names for two reader contexts. Discussed in detail in 058-004's Argument Against #1.

**3. Aligns with holon-rs library surface.**

Holon's Python and Rust libraries expose both `subtract` (as a vector operation) and conceptual "differences" (as observations). Having both named forms in wat matches the existing abstraction boundary.

**4. Completes the pair with Amplify and Flip.**

Amplify (variable `s`), Subtract (`s = -1`), Flip (`s = -2`) form the linear-Blend-idiom trio. Each has distinct intent. Having Subtract as its own stdlib form gives the canonical `s = -1` case a short direct name.

## Arguments Against

**1. Redundant with Difference (058-004).**

Identical expansion. Identical math. Two names for one operation.

Case for keeping both:
- Different reader intents (imperative vs noun)
- Different grammatical usage in vocab code
- Minimal cost (one-line stdlib, well-understood overlap)

Case for keeping one:
- Hickey's simplicity: one form per operation
- Avoiding alias proliferation

Resolution: both are accepted. The cost of the overlap is small; the clarity gain of having both in reader's vocabulary is concrete.

**2. `Subtract` may be confused with scalar arithmetic.**

In most languages, `subtract` is a scalar operation. `Subtract` here is a VECTOR operation (Blend with specific weights). Readers from non-VSA backgrounds may expect a different operation.

**Mitigation:** documentation. The wat stdlib is unambiguously vector-operation; there are no scalar `subtract` alternatives to confuse with.

**3. Overlap with `Amplify(x, y, -1)`.**

`(Subtract x y)` ≡ `(Amplify x y -1)` ≡ `(Blend x y 1 -1)`. Three names for one operation.

**Mitigation:** name-precedence convention. The most-specific applicable name wins. For `s = -1`, use `Subtract`. For `s = -2`, use `Flip`. For other `s`, use `Amplify`. For explicit weight control, use `Blend`.

**4. Is stdlib the right layer?**

Could argue `Subtract` is such a basic operation that it should be core. But:
- It's trivially expressible in Blend (058-002).
- Making it core would duplicate Blend's operation.
- Stdlib is the right layer for named idioms.

**Mitigation:** keep at stdlib; use Blend for the primitive.

## Comparison

| Form | Class | Weights | Semantic |
|---|---|---|---|
| `Blend(x, y, w1, w2)` | CORE | arbitrary | Generic weighted sum |
| `Subtract(x, y)` | STDLIB (this) | `(1, -1)` | Remove y linearly from x |
| `Difference(a, b)` | STDLIB (058-004) | `(1, -1)` | Delta from b to a |
| `Amplify(x, y, -1)` | STDLIB (058-015) | `(1, -1)` | Special case: s = -1 |

`Subtract`, `Difference`, and `Amplify(_, _, -1)` are mechanically identical. Three names, three reader intents.

## Algebraic Question

Does Subtract compose with the existing algebra?

Trivially — it IS Blend. All downstream operations work.

Is it a distinct source category?

No. Blend specialization. Stdlib.

## Simplicity Question

Is this simple or easy?

Simple. One-line stdlib.

Is anything complected?

The tri-name overlap (Subtract, Difference, Amplify at -1) is the only complection concern. Mitigated by documentation of reader intents.

Could existing forms express it?

Yes — `(Blend x y 1 -1)` or `(Difference x y)` or `(Amplify x y -1)`. Named form earns its place via the imperative-removal reader intent.

## Implementation Scope

**Zero Rust changes.** Pure wat.

**wat stdlib addition** — `wat/std/blends.wat`:

```scheme
(define (Subtract x y)
  (Blend x y 1 -1))
```

## Questions for Designers

1. **Subtract vs Difference: keep both or unify?** Same math. Different reader intents. This proposal keeps both. Alternative: pick one, deprecate the other. Recommendation: keep both; the cost is trivial and the clarity gain is real.

2. **Naming: `Subtract` or `Remove`?** "Subtract" has mathematical connotations; "Remove" has more direct intent ("remove the noise"). Recommendation: keep `Subtract` — aligns with holon-rs's `subtract` function; readers recognize it.

3. **Imperative `Subtract!` variant for in-place?** In some languages, exclamation suffix denotes mutation. Here all operations are pure (ASTs are immutable). Irrelevant, noted for consistency.

4. **Dependency on 058-002-blend.** If rejected, Subtract re-proposes as core (it is one of the three original Negate modes, per FOUNDATION's history). Resolution order: Blend first.

5. **Subtract's relationship to Orthogonalize (058-005).** Subtract removes `y` linearly. Orthogonalize removes `y`'s DIRECTION proportionally. Different operations, different invariants. Subtract is stdlib; Orthogonalize is core (has a computed weight). Documentation should make the distinction explicit to avoid confusion.
