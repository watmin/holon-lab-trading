# 058-002: `Blend` — Scalar-Weighted Binary Combination

**Scope:** algebra
**Class:** CORE — **ACCEPTED**
**Parent:** 058-ast-algebra-surface
**Foundation:** ../FOUNDATION.md

---

## ACCEPTED — 2026-04-18

`Blend` enters the algebra core as a new variant with signature `(:wat::algebra::Blend a b w1 w2)` — two independent real-valued scalar weights. All five designer questions closed on the arguments below. Designer review in Round 3 may still reopen any of them; this section records our best reading.

### Q1 — Distinct source category? **YES.**

Bundle is the MAP monoid "Add" — uniform +1 weights, associative, commutative. Blend is parameterized binary combination; non-commutative in the vector arguments when `w1 ≠ w2`. Different categorical object, different algebraic role. Self-answering under FOUNDATION's core criterion (new operation no existing primitive performs).

### Q2 — Option A (convex, single alpha) vs Option B (two independent weights)? **Option B.**

The counter-intuitive reading. Option A has less syntactic surface but more entangled semantics: `alpha` and `(1 - alpha)` are **braided** — the convexity constraint forces a relationship between them. **Option A is a complection hiding in plain sight.** Option B unbraids: each weight stands alone. By Hickey's "simple = unentangled concepts" definition, Option B is simpler despite having more parameters.

Also load-bearing: Option A physically cannot express Circular, because `cos(θ) + sin(θ) ≠ 1` in general (at θ=π/4 the sum is ≈1.414). Option A keeps Circular in core; Option B lets Circular expand to a wat stdlib macro over `Blend`. Option B strictly dominates: smaller core, fuller coverage.

### Q3 — Allow negative weights? **YES.**

Follows from Option B — once weights are independent reals, negative is arithmetic, not a new concept. The operation is `threshold(w1·a + w2·b)` regardless of sign. `Blend(x, y, 1, -1) = Subtract`. The "blurs superposition intuition" objection lands in the naming tier, not the algebra tier. Semantic intent is carried by stdlib names (`Subtract`, `Amplify`, `Flip`) at the call site; the core primitive does not police interpretation.

### Q4 — Variadic temptation? **Stay binary.**

Generalizing to `Blend(pairs)` variadic would make Bundle a special case (all-1 weights), which dissolves MAP's canonical set. Bundle is the monoid Add; Blend is the parameterized binary combination; different categorical objects; coexist. Binary Blend does what every current proposal needs. If future work genuinely demands variadic weighted sum, it proposes separately with concrete motivation.

### Q5 — holon-rs implementation impact? **Trivial.**

~20 lines: new `blend_weighted(a, b, w1, w2)`; existing `blend(a, b, α)` becomes a thin wrapper `blend_weighted(a, b, 1.0 - α, α)`. Backward compatible. Cache key encoding for f64 weights follows the existing Thermometer pattern (value, min, max as f64 fields), already working in production.

### Q6 — If rejected, path for Linear/Circular? **Moot.**

Q1 and Q2 answers mean Blend is accepted; the conditional branch does not fire.

---

## Downstream cascade (now unblocked)

With Blend ACCEPTED as Option B with negative weights, the following stdlib reclassifications become mechanical:

- **058-008 Linear** — already REJECTED (identical to Thermometer with the 3-arity signature); not affected.
- **058-018 Circular** — becomes `(:wat::algebra::Blend cos-basis sin-basis (cos θ) (sin θ))`; stdlib macro.
- **058-015 Amplify** — becomes `(:wat::algebra::Blend x y 1 s)`; stdlib macro.
- **058-019 Subtract** — becomes `(:wat::algebra::Blend x y 1 -1)`; stdlib macro (the canonical delta — 058-004 Difference REJECTED).
- **058-020 Flip** — becomes `(:wat::algebra::Blend x y 1 -2)`; stdlib macro.
- **058-005 Orthogonalize** — stays core (computed-coefficient projection removal, which Blend cannot express because the coefficient depends on a dot product of the inputs).

The original three-mode Negate decomposes cleanly: one mode (orthogonalize) stays core; two modes (subtract, flip) become stdlib Blend idioms.

---

## Historical content (preserved — supports the above arguments)

## The Candidate

A new core variant that introduces scalar-weighted vector addition — an operation no existing core form can perform.

```scheme
(:wat::algebra::Blend a b w1 w2)
```

Semantically: `threshold(w1 × a + w2 × b)` where `a` and `b` are vectors in the algebra's ternary output space `{-1, 0, +1}^d` and `w1`, `w2` are arbitrary real-valued scalar weights (positive, negative, or fractional). See FOUNDATION's "Output Space" section for the ternary convention (`threshold(0) = 0`).

### Encoding Rule

```
encode(Blend(a, b, w1, w2)) → threshold(w1 * encode(a) + w2 * encode(b))
```

Element-wise scalar multiplication, element-wise addition, threshold into the ternary output space `{-1, 0, +1}^d`. Zeros arise where the weighted sum exactly cancels (`threshold(0) = 0`) — this is the algebra's "no information at this dimension" signal, not a degenerate case.

### AST Shape

```rust
pub enum HolonAST {
    // ... existing variants ...
    Blend(Arc<HolonAST>, Arc<HolonAST>, f64, f64),
}
```

## Why This Matters

Two existing core variants — `Linear` and `Circular` — perform scalar-weighted binary vector addition with specific weighting schemes:

```
Linear(v, scale) ≈ blend(anchor_low, anchor_high, (1-t), t)   where t = v/scale
Circular(v, period) ≈ blend(cos_basis, sin_basis, cos(θ), sin(θ))   where θ = 2π·v/period
```

Both compute the same operation — scalar-weighted binary sum — but hide it inside their encoding machinery, with different weight formulas. Currently the encoder has separate code paths for `Linear` and `Circular`, each performing the same algebraic operation with different scalar derivations.

Promoting `Blend` makes the shared operation a first-class core primitive. The encoder gets ONE scalar-weighted-add path. `Linear` and `Circular` become stdlib compositions that compute their weights and call `Blend`.

This is the audit refinement FOUNDATION.md flagged as "the highest-impact refinement expected from 058."

## Why Two Weights (Option B)

The existing holon `blend(a, b, α)` is CONVEX — one alpha in `[0, 1]`, computing `threshold((1-α)·a + α·b)`. This is Option A in the FOUNDATION's framing.

Option A (convex) captures Linear cleanly:
- `Linear(v, scale)` → `(Blend anchor_low anchor_high (v/scale))`
- Weights `(1-t)` and `t` sum to 1 — convex

But Option A does NOT capture Circular:
- Circular's weights are `(cos θ, sin θ)`
- `cos(θ) + sin(θ)` ≠ 1 in general
- At `θ = π/4`: both weights ≈ 0.707, sum ≈ 1.414 — not convex

For `Blend` to subsume both, the weights must be INDEPENDENT REAL SCALARS (Option B):

```
Blend(a, b, w1, w2) = threshold(w1·a + w2·b)
```

This also captures:
- `Amplify(x, y, s)` → `(Blend x y 1 s)` — boost component
- `Subtract(x, y)` → `(Blend x y 1 -1)` — stdlib Blend idiom (see 058-019-subtract; historically one of three modes of a unified `Negate` form)

One primitive. Five use cases covered. FOUNDATION's stdlib section uses this form throughout.

## Arguments For

**1. It introduces a new algebraic operation.**

Scalar-weighted vector addition is not in any existing core form:
- `Bind` is element-wise MULTIPLICATION of two vectors
- `Bundle` is element-wise SUM of N vectors, unweighted, threshold at end
- `Permute` is a dimensional shift of a single vector
- `Atom`, `Thermometer` construct vectors from literals

None of them scales a vector by a scalar BEFORE combining with another vector. `Blend` introduces this operation. It passes the CORE criterion from FOUNDATION unambiguously.

**2. It retroactively consolidates the scalar encoders.**

Currently `Linear` and `Circular` each encode their own scalar-weighted-add logic in the encoder. With `Blend` as core, the encoder has ONE scalar-weighted-add path; `Linear` and `Circular` become wat stdlib functions that compute weights and call `Blend`. Less Rust, same algebra.

**3. It composes naturally with existing stdlib idioms.**

`Amplify`, `Subtract`, and what was historically the subtract-mode of `Negate` all reduce to `(Blend a b 1 s)` with specific weights. These become one-line stdlib definitions over `Blend` (see 058-015-amplify, 058-019-subtract, 058-020-flip).

**4. The algebra closes.**

Taking Blend + Thermometer as the only scalar primitives (plus the MAP canonical set Atom/Bind/Bundle/Permute) appears to be a complete algebra for scalar encoding — Linear interpolation, logarithmic interpolation, cyclical rotation, thermometer gradient, amplification, subtraction. No new primitive has appeared in subsequent sub-proposals that the current set cannot express. This suggests Blend completes the scalar-primitive set alongside Thermometer.

**5. Ternary output is preserved.**

The threshold step maps `(w1·a + w2·b)` into `{-1, 0, +1}^d` — the algebra's ternary output space. The output has the same type as inputs. Downstream operations (`Bind`, `Bundle`, `cosine`) work without change. Blend is a value-preserving operation within the MAP type system.

## Arguments Against

**1. Existing holon `blend` is convex — this proposal changes the semantics.**

The existing holon `blend(a, b, α)` is convex with a single alpha. Option B (two independent weights) requires extending holon-rs with a new function `blend_weighted(a, b, w1, w2)`. The existing convex form becomes a special case: `blend(a, b, α) = blend_weighted(a, b, 1-α, α)`.

This is a small addition (~20 lines in holon-rs). But it is a change to holon-rs alongside the HolonAST change. Worth naming as a cross-cutting impact.

**2. The form takes 4 arguments — heavier than existing core forms.**

Most existing core forms are binary (`Bind`) or take-a-list (`Bundle`). `Blend` takes 2 vectors plus 2 scalars — a 4-argument variant. This is not unprecedented (`Thermometer` takes a value plus min/max), but it is the heaviest variant proposed so far.

An alternative encoding: `Blend(a, b, weight-list)` where the weight-list is a list of two floats. More uniform argument shape, but less readable.

**3. Variadic generalization temptation.**

Once you have weighted binary combination, it's tempting to generalize to variadic: `Blend(pairs)` where each pair is `(vector, weight)`. This would make `Blend` the natural generalization of `Bundle` (Bundle = Blend with all weights = 1) and subsume unweighted bundling.

But that generalization dissolves the MAP canonical form. `Bundle` is Add in MAP. Variadic weighted Blend would replace it, and the canonical set would shift. This is a large architectural change that deserves its own proposal, not a casual generalization inside this one.

Recommendation: Blend stays BINARY (2 vectors + 2 scalars). If variadic weighted-sum is later judged valuable, it proposes separately.

**4. Negative weights blur the "superposition" intuition.**

Bundle's weights are implicitly all +1 — a superposition of contributions. Blend with negative weights is more like "component removal" (as in `Negate`'s subtract mode). Is this really a blend, or is it a different operation wearing blend's name?

Mitigation: the operation is consistent — `threshold(w1·a + w2·b)` regardless of weight signs. Negative weights are mathematically valid and produce useful compositions (subtract mode, amplification with inverted boost). The naming "Blend" is conventional from holon's existing library; it doesn't have to imply convex semantics.

**5. Hickey's bar: could existing generators express it?**

Partially. `Amplify(x, y, s) = Bundle((list x (scale y s)))` if we had a `scale(v, s)` primitive. But we don't. And `scale(v, s)` is ALSO scalar-weighted-vector operation — it's just the single-vector form of Blend. If the algebra gains scalar-weighted operations at all, Blend is the clean binary form.

Without Blend (or scale), Linear and Circular cannot be expressed as stdlib compositions. They must remain core. FOUNDATION's criterion for `Blend` is essentially: is the unification worth adding a new core form?

## Comparison to Nearest Existing Generator

| Aspect | `Bundle(list)` | `Blend(a, b, w1, w2)` |
|---|---|---|
| Arity | Variadic (list) | Binary (2 vectors + 2 scalars) |
| Weighting | Implicit, all +1 | Explicit, arbitrary reals |
| Output | Ternary `{-1, 0, +1}^d` (thresholded sum) | Ternary `{-1, 0, +1}^d` (thresholded weighted sum) |
| Captures Linear? | No | Yes |
| Captures Circular? | No | Yes |
| Captures Amplify? | No | Yes |
| Captures Subtract? | No | Yes (with weight `-1`) |
| Role in MAP | The "Add" operation | Not in canonical MAP |

Blend is genuinely new — it adds a dimension of expressiveness (scalar weights) that Bundle does not have.

## Algebraic Question

Does `Blend` compose with the existing algebra?

Yes. Inputs and output live in the ternary output space `{-1, 0, +1}^d`. Downstream operations (`Bind`, `Bundle`, `Permute`, `cosine`) work without modification. The ternary type closes.

Does it introduce a distinct source category?

Arguably yes. Bundle is a monoid operation (associative, commutative, identity) on the multiset of vectors. Blend is not a monoid in the same way — the weights parameterize the operation. Categorically, Blend is closer to a linear map than a monoid operation.

Both monoid (Bundle) and linear-map-like (Blend) operations have their place in the algebra. They are NOT substitutes for each other.

## Simplicity Question

Is this simple or easy?

Simple. The operation is primitive (scalar·vector, vector+vector, threshold). The implementation is ~20 lines of Rust. The encoding rule is one-line. No complection.

Is anything complected?

No. Blend does one thing — scalar-weighted combination of two vectors. It does not couple weight semantics with structure (which would be a structural form). It does not couple scalar encoding with composition (which is why Linear and Circular become stdlib — they combine scalar transformation with Blend, which is a COMPOSITION, honestly named as such).

Could existing forms express it?

No. As detailed above, no existing form performs scalar-weighted vector combination. This is the core criterion that unambiguously passes.

## Implementation Scope

**holon-rs changes** (~20 lines):

```rust
pub fn blend_weighted(a: &Vector, b: &Vector, w1: f64, w2: f64) -> Vector {
    a.iter().zip(b.iter())
        .map(|(av, bv)| {
            let sum = w1 * (*av as f64) + w2 * (*bv as f64);
            threshold_ternary(sum)
        })
        .collect()
}
```

Parameters: two ternary vectors in `{-1, 0, +1}^d` (reference, no copy), two `f64` weights. Output: new ternary vector in `{-1, 0, +1}^d`.

**Existing `blend(a, b, α)` becomes a thin wrapper:**

```rust
pub fn blend(a: &Vector, b: &Vector, alpha: f64) -> Vector {
    blend_weighted(a, b, 1.0 - alpha, alpha)
}
```

Backward compatible. All current callers continue to work.

**HolonAST changes:**

```rust
pub enum HolonAST {
    // ... existing variants ...
    Blend(Arc<HolonAST>, Arc<HolonAST>, f64, f64),
}
```

One new variant. The encoder dispatches to `blend_weighted` when evaluating a `Blend` node.

**Cache considerations:**

Two `f64` values in the AST shape. Hash keys must include these. Same approach as `Thermometer`'s `value`, `min`, `max` fields — already cached successfully in the current system.

## Downstream Effects (triggered by promotion)

If `Blend` is promoted, the following FOUNDATION refinements follow:

1. **`Linear` reclassified as stdlib:**
   ```scheme
   (:wat::core::define (:wat::std::Linear v scale)
     (:wat::algebra::Blend (:wat::algebra::Atom :wat::std::linear-low)
                         (:wat::algebra::Atom :wat::std::linear-high)
            (:wat::core::- 1 (:wat::core::/ v scale))
            (:wat::core::/ v scale)))
   ```

2. **`Circular` reclassified as stdlib:**
   ```scheme
   (:wat::core::define (:wat::std::Circular v period)
     (:wat::core::let ((theta (:wat::core::* 2 pi (:wat::core::/ v period))))
       (:wat::algebra::Blend (:wat::algebra::Atom :wat::std::circular-cos-basis)
              (:wat::algebra::Atom :wat::std::circular-sin-basis)
              (cos theta)
              (sin theta))))
   ```

3. **`Log` remains grandfathered stdlib** (already classified — expands via Linear/Thermometer).

4. **`Amplify` becomes stdlib** (see 058-015-amplify):
   ```scheme
   (:wat::core::define (:wat::std::Amplify x y s)
     (:wat::algebra::Blend x y 1 s))
   ```

5. **`Subtract` enters as stdlib** (see 058-019-subtract — historically Negate's subtract mode):
   ```scheme
   (:wat::core::define (:wat::std::Subtract x y)
     (:wat::algebra::Blend x y 1 -1))
   ```

6. **`Negate` is split** — the orthogonalize mode becomes its own CORE form (see 058-005-orthogonalize), while subtract/flip modes become stdlib Blend idioms (see 058-019-subtract, 058-020-flip).

If `Blend` is REJECTED, the downstream effects do not apply: Linear/Circular remain core; Amplify remains core or gets its own proposal; Subtract does not exist; the historical three-mode Negate would have had to remain unified as one form.

## Questions for Designers

1. **Is scalar-weighted vector addition a distinct source category from unweighted bundling?** The argument: Bundle's weights are implicitly uniform (+1); Blend's weights are parametric. Bundle is a monoid operation; Blend is parameterized by scalar weights and is not commutative in the vector arguments (`Blend(a, b, w1, w2)` ≠ `Blend(b, a, w1, w2)` unless `w1 = w2`). Different categorical nature. Is this enough to earn core status?

2. **Option A (convex, single alpha) vs Option B (two independent weights)?** Option A is simpler and matches existing holon `blend`. Option A captures Linear but NOT Circular (trig weights aren't convex). Option B captures both plus more. Which is the right level of generality for a core form? Option A with Circular staying core? Option B with full unification?

3. **Should negative weights be allowed?** With Option B allowing negative weights, `Blend(x, y, 1, -1)` = Negate-subtract-mode. Does this blur the semantic distinction between "blend" and "subtract"? Or is it fine — the mathematics is consistent, and the stdlib names the specific use cases (Amplify, Subtract) for readability.

4. **Variadic temptation — where do we stop?** Once you have Blend(a, b, w1, w2), do you generalize to Blend(pairs) variadic? This would subsume Bundle (all weights +1) as a special case. Is that the right direction, or does it dissolve the MAP canonical set? I argue stay binary; variadic proposes separately if ever.

5. **Implementation impact on holon-rs.** Is ~20 lines of Rust (new `blend_weighted`, existing `blend` becomes a wrapper) an acceptable change? Any concern about cache key encoding for f64 weights?

6. **If rejected, what is the recommended path for Linear and Circular?** They remain core and duplicate the scalar-weighted-add logic. Is that acceptable? Is there a different way to consolidate them without introducing Blend?
