# 058-005: `Orthogonalize` — Project Out a Component

**Scope:** algebra
**Class:** CORE (renamed and narrowed from FOUNDATION's `Negate`)
**Parent:** 058-ast-algebra-surface
**Foundation:** ../FOUNDATION.md
**Depends on:** 058-002-blend (see reclassification note)

## Reclassification Note

FOUNDATION.md originally listed `Negate(x, y, mode)` as a core candidate with three modes: subtract, orthogonalize, flip. During sub-proposal review, the three modes separate into different classifications:

- **Subtract mode** — `threshold(x - y)` — is algebraically identical to `Blend(x, y, 1, -1)`. Reclassified as a stdlib idiom (see 058-019-subtract and 058-004-difference).
- **Flip mode** — `threshold(x - 2y)` — inverts `y`'s contribution in a superposition. Algebraically identical to `Blend(x, y, 1, -2)`. Reclassified as a stdlib idiom (see 058-020-flip).
- **Orthogonalize mode** — `X - ((X·Y)/(Y·Y))·Y` — geometric projection removal. Requires a SCALAR WEIGHT COMPUTED FROM THE INPUTS.

The first two modes dissolve into Blend idioms. The third is the genuinely new operation. This sub-proposal therefore renames from `Negate` to `Orthogonalize` and focuses on the projection-removal operation specifically.

## The Candidate

A new core variant that removes a component's geometric direction from a vector:

```scheme
(:wat/algebra/Orthogonalize x y)
```

Semantically: given vectors `x` and `y`, produce a new vector that is `x` with `y`'s direction projected out. The result is **orthogonal to `y` under similarity measurement** — the algebra's primary evaluation framework (see FOUNDATION's "Algebraic laws under similarity measurement").

**Exact elementwise orthogonality holds for the degenerate case `X = Y`:** the projection coefficient is 1, `X - Y = [0, 0, ..., 0]`, threshold preserves the all-zero vector (`threshold(0) = 0` per FOUNDATION's ternary rule), and the all-zero result has dot product 0 with any vector — including `Y`. This case resolves cleanly.

**For general X, Y, elementwise orthogonality is approximate.** When the projection coefficient `(X·Y)/(Y·Y)` is fractional, `X - coeff·Y` produces non-integer components. Thresholding to `{-1, 0, +1}` rounds these back to sign values, reintroducing correlation with `Y`. Concrete counter-example at d=4: `X = [+1, +1, +1, -1]`, `Y = [+1, +1, +1, +1]`, coefficient = 0.5, `X - 0.5·Y = [+0.5, +0.5, +0.5, -1.5]`, threshold → `[+1, +1, +1, -1] = X`, dot with `Y` = 2 (not 0).

At high d with typical operands, `cosine(Orthogonalize(X, Y), Y)` falls below the 5σ noise threshold — downstream similarity-based consumers (Cleanup, cosine queries, discriminant tests) treat the result as orthogonal to `Y` under the algebra's measurement framework. The elementwise counter-example is a capacity expenditure: the projection-and-threshold step costs a fraction of the per-frame budget, same as Bundle crosstalk, sparse-key decoding, cascading compositions. Within budget, similarity-orthogonality holds; beyond budget, the similarity score tells you honestly that the operation didn't clear the noise floor.

### Operation

```
Orthogonalize(X, Y) = threshold(X - ((X·Y) / (Y·Y)) × Y)
```

Where:
- `X·Y` is the dot product of the two bipolar vectors
- `Y·Y` is the squared magnitude of `Y` (equal to the count of non-zero entries for bipolar)
- The quotient `(X·Y)/(Y·Y)` is the projection coefficient — how much `Y` is present in `X`
- `((X·Y)/(Y·Y)) × Y` is the projection of `X` onto `Y`
- Subtracting the projection from `X` yields a vector orthogonal to `Y`

### AST shape

```rust
pub enum HolonAST {
    // ... existing variants ...
    Orthogonalize(Arc<HolonAST>, Arc<HolonAST>),
}
```

Two holon arguments. No scalar parameters in the AST itself — the projection coefficient is computed from the encoded vectors at evaluation time.

## Why This Earns Core Status

**1. It is not expressible via existing or pending core forms.**

`Blend(a, b, w1, w2)` takes LITERAL scalar weights — fixed at AST construction time, stored in the AST, independent of the vectors. `Orthogonalize`'s coefficient depends on the ENCODED VECTORS — specifically, on their dot product, which is only computable after both operands have been projected to vectors.

This is a genuine difference in operational semantics:
- `Blend`: weights provided by the programmer, independent of the vectors
- `Orthogonalize`: weight DERIVED FROM the vectors at evaluation time

If we widen Blend to accept expression-valued weights (computed from vectors), the two operations collapse — but that's a significant extension to Blend's semantics. At present, Blend takes f64 literals; Orthogonalize takes two holons and computes the internal coefficient.

**2. The operation is well-known and widely useful.**

Geometric projection-removal has deep roots:
- Gram-Schmidt orthogonalization (linear algebra foundation)
- Component removal in VSA for "X but not Y" semantics
- Direction-based attention (project out one axis)
- Anomaly decomposition (residual after projecting onto known patterns)

The holon library exposes `orthogonalize` as one of three `negate` methods. FOUNDATION treats it as a genuinely distinct operation.

**3. Distinct source category from subtract or blend.**

- `Blend(x, y, 1, -1)` subtracts y linearly — result depends on elementwise alignment
- `Orthogonalize(x, y)` removes y's direction proportionally — result is geometrically orthogonal to y

Different invariants. `Blend(x, y, 1, -1) · y` is some value depending on `x` and `y`. `Orthogonalize(x, y) · y ≈ 0` by construction.

The invariant produced (orthogonality to `y`) is the signature property. No other core form produces this.

## Arguments Against

**1. Could be expressed with a widened Blend.**

If Blend accepted computed weights (expressions evaluable at encoding time, using primitives like `dot` and `magnitude-squared`), Orthogonalize would become stdlib:

```scheme
(:wat/core/define (:wat/std/Orthogonalize x y)
  (:wat/algebra/Blend x y 1 (:wat/core/- (:wat/core// (dot x y) (dot y y)))))
```

Whether to widen Blend is a design question — it would require wat to support scalar-expression evaluation in AST positions, which changes the AST's character from "static tree of literals" to "tree with arithmetic in scalar positions."

For now, Blend takes f64 literals. Orthogonalize is either core, or Blend gets widened (and everything becomes stdlib).

**2. Arity and cache complexity.**

`Orthogonalize` takes two holons. The encoder must compute both subvectors, then their inner products, then the projection. This is more work per encode than `Blend`'s simpler weighted sum. Cache invalidation is the same as any binary AST form.

Not a blocker, but worth naming.

**3. If we're introducing projections, why not the full Project/Reject pair?**

`Orthogonalize(x, y)` returns the COMPLEMENT of the projection (x minus its y-component). The DUAL operation, `Project(x, y)`, returns the projection itself (just the y-component of x). Holon exposes both as `project` and `reject` (where reject IS orthogonalize).

Should this proposal also introduce `Project`?

- Case for: symmetry in the algebra. If you have the complement, you might as well have the component.
- Case against: `Project(x, y) = Blend(x, y, 1, 0) - Orthogonalize(x, y)` — which means Project is the DIFFERENCE between x and its orthogonalization. Stdlib.

Simpler to keep `Orthogonalize` as the single new core form and let `Project` emerge as a stdlib idiom.

**4. Narrowing Negate to just Orthogonalize loses the "three-mode" story.**

Holon's `negate` has three methods. This proposal splits them: subtract → Blend idiom, flip → Blend idiom, orthogonalize → its own core form. The three-method unity is broken in favor of honest classification.

Mitigation: the three-method unity was always a software interface convenience, not an algebraic truth. At the algebra level, subtract and flip share a structure (Blend with a literal weight) that orthogonalize doesn't (Blend with a computed weight). Separating them reflects the real structure.

## Comparison

| Form | Weight source | Invariant |
|---|---|---|
| `Blend(x, y, 1, -1)` | literal `(1, -1)` | general linear combination |
| `Blend(x, y, 1, -2)` | literal `(1, -2)` | flip mode — inverts y's component |
| `Orthogonalize(x, y)` | computed `((x·y)/(y·y))` | result is orthogonal to y |

The computed weight is the operational difference. It makes orthogonalize categorically distinct from any literal-weighted Blend.

## Algebraic Question

Does `Orthogonalize` compose with the existing algebra?

Yes — inputs are bipolar vectors, output is bipolar vector (after threshold). All downstream operations work unchanged.

Is it a distinct source category?

Arguably yes — it introduces a new kind of operation: one whose parameters depend on the operands. Blend is a linear map with fixed coefficients; Orthogonalize is nonlinear in the sense that the coefficient is a function of the inputs. Different categorically.

## Simplicity Question

Is this simple or easy?

Simple — one operation, one mathematical definition, one semantic (projection removal). The implementation requires a dot-product computation, which is ~O(d) and mechanically straightforward.

Is anything complected?

Not really — the operation has a single semantic role ("make this vector orthogonal to that one"). It doesn't couple separate concerns.

Could existing forms express it?

Not with the current Blend signature. A widened Blend with computed weights could express it, but that is a larger proposal affecting Blend's character.

## Implementation Scope

**holon-rs changes** (~30 lines):

```rust
pub fn orthogonalize(x: &Vector, y: &Vector) -> Vector {
    let x_dot_y: f64 = x.iter().zip(y.iter())
        .map(|(xv, yv)| (*xv as f64) * (*yv as f64))
        .sum();
    let y_dot_y: f64 = y.iter()
        .map(|yv| (*yv as f64).powi(2))
        .sum();
    let coeff = x_dot_y / y_dot_y;
    
    x.iter().zip(y.iter())
        .map(|(xv, yv)| {
            let orthogonal = (*xv as f64) - coeff * (*yv as f64);
            threshold_bipolar(orthogonal)
        })
        .collect()
}
```

Two dot-product scans, then element-wise orthogonal computation. O(d) overall.

**HolonAST changes:**

```rust
pub enum HolonAST {
    // ... existing variants ...
    Orthogonalize(Arc<HolonAST>, Arc<HolonAST>),
}
```

Encoder dispatches to `orthogonalize(encode(x), encode(y))`.

## Questions for Designers

1. **Orthogonalize as core vs. widened Blend with computed weights.** The trade-off: Orthogonalize as its own variant (concrete, focused) vs. Blend with expression-valued weights (unifies but widens scope). Which is the right level of generality?

2. **Should `Project` also be proposed?** Related operation — the projection itself, rather than the complement. Can be stdlib (`Project = x - Orthogonalize(x, y)`), but some applications want the projection directly. Worth a first-class form, or let stdlib handle it?

3. **Naming: `Orthogonalize` or `Reject`?** Holon calls this operation `reject` (rejection of y's component from x). "Orthogonalize" describes what the result IS (orthogonal to y); "Reject" describes what the operation DOES (rejects y's component). Which name serves the wat reader better?

4. **Handling of zero-magnitude y.** If `y` is the zero vector, `Y·Y = 0` and the projection coefficient is undefined. The implementation must handle this edge case — probably by returning `x` unchanged (nothing to project out). Should this be explicit in the semantics?

5. **Classification reconsideration.** This sub-proposal NARROWED the original Negate proposal to just the orthogonalize mode. Subtract mode went to 058-019-subtract, flip mode went to 058-020-flip. Is this the right split, or should Negate have been preserved as a single multi-mode core form?
