# 058-022: `Permute` — Core Primitive Affirmation

**Scope:** algebra
**Class:** CORE (existing primitive — this proposal affirms)
**Parent:** 058-ast-algebra-surface
**Foundation:** ../FOUNDATION.md

## The Candidate

`Permute` is the dimension-shuffle primitive — it produces a vector whose dimensions are reordered according to a FIXED permutation, indexed by a step count.

```scheme
(Permute v k)
```

One thought argument and one integer step.

### Operation

For vector `v ∈ {-1, +1}^d` and step `k ∈ ℤ`:

```
Permute(v, k)[i] = v[P^k(i)]
```

Where `P` is a fixed permutation of `[0, d)` and `P^k` is `P` composed with itself `k` times. `Permute(v, 0)` is the identity (no shuffle). `Permute(v, -k)` undoes `Permute(v, k)`.

The exact permutation `P` is an implementation choice. The canonical choice in MAP VSA is a cyclic shift by one position: `P(i) = (i + 1) mod d`. Holon's implementation typically uses this.

### Key properties

1. **Invertible**: `Permute(Permute(v, k), -k) = v` — the inverse shuffle recovers the original.
2. **Commutative with binding-by-scalar**: `Permute(v * s, k) = Permute(v, k) * s` for scalar `s`.
3. **Linearity over Bundle**: `Permute(Bundle(xs), k) = Bundle([Permute(x, k) for x in xs])`.
4. **Distinguishes positions**: for a typical `P` (e.g., cyclic shift), `Permute(v, k)` is dissimilar to `v` for `k ≠ 0`, allowing positional encoding.

### AST shape (already exists)

```rust
pub enum ThoughtAST {
    // ... other variants ...
    Permute(Arc<ThoughtAST>, i32),
}
```

One thought + one integer step count. Present in current `ThoughtAST`.

## Why This IS Core

**1. Permute cannot be expressed in Bind + Bundle + Atom + Thermometer.**

Bind is elementwise multiplication. Bundle is elementwise sum. Neither reorders dimensions. Atom and Thermometer are primitive encoders. None of them produce a permuted view of a vector.

Permute is algebraically PRIMITIVE — not derivable from other primitives.

**2. Position is a first-class algebraic concept.**

VSA's ability to encode ORDERED structures (sequences, trees, positional records) depends on a way to distinguish "v at position 0" from "v at position 1." Permute provides this: each position gets a distinct number of permutation steps.

Without Permute, the algebra is position-agnostic. Bundle is commutative; Bind is not associative in a position-preserving way. Permute is what breaks the symmetry enough to encode ordering.

**3. MAP VSA's "P" is Permute.**

MAP VSA = Multiply (Bind), Add (Bundle), Permute. Permute is one of the three irreducible core operations. Removing it would degenerate the algebra to an unordered bag-of-thoughts.

**4. Used by every positional stdlib form.**

- `Sequential(xs)` (058-009) uses Permute with incremental steps for positional encoding.
- `Then(a, b)` (058-011) uses `Permute b 1` to mark "b comes after a."
- `Chain(xs)` (058-012) composes over Thens, so indirectly over Permutes.
- `Ngram(n, xs)` (058-013) slides Sequential-encoded windows.
- `Array(xs)` (058-026) is Sequential, transitively Permute.
- `nth(array, i)` accessor inverts positional Permute.

Without Permute, the entire temporal/positional stdlib collapses.

## Arguments For Core Status

**1. Decades of VSA literature.**

Permute (or its analog — cyclic shift, rotation, positional encoding) appears in every VSA formulation. It is the CANONICAL way to encode position.

**2. Efficient implementation.**

Dimension reordering is O(d), cache-friendly. For a cyclic-shift `P`, it is a linear scan with modular indexing. SIMD-friendly.

**3. Inverse exists trivially.**

Unlike Bundle (irreversible due to threshold), Permute has an exact inverse (`k → -k`). This makes positional decoding tractable: `Permute(Permute(v, k), -k) = v`.

## Arguments Against Removing or Reframing

This is affirmation. But: could Permute be reframed?

Candidates:
- Dimension-level operation primitive? Would be more primitive but doesn't exist.
- Permutation group primitive? Cleaner mathematically but same expressive power.
- Implicit via indexing? Without Permute, `Permute(v, k)[i] = v[(i+k) mod d]` would need to be expressed as Bind with some positional mask, which is more complex and requires a different primitive.

None of these provide simpler expression. Permute IS the primitive.

## Comparison

| Primitive | Operation | Inverse | Role |
|---|---|---|---|
| `Bind(a, b)` | `a[i] * b[i]` | self-inverse (bipolar) | Structure binding |
| `Bundle(xs)` | `threshold(Σ xs[i])` | NOT invertible | Superposition |
| `Permute(v, k)` | dimension shuffle by `k` steps | `Permute(_, -k)` | Positional distinction |
| `Atom(literal)` | hash-to-vector | N/A | Literal encoding |
| `Thermometer(atom, dim)` | gradient vector | N/A | Scalar gradient |

Permute is the unique invertible position-distinguishing primitive.

## Algebraic Question

Does Permute compose with the existing algebra?

Yes. Permute commutes with Bundle (linearity) and Bind (elementwise distributes). Its place in the algebra is well-understood.

Is it a distinct source category?

Yes. "Positional dimension shuffle" is categorically unique.

## Simplicity Question

Is this simple or easy?

Simple. One operation. Integer parameter. Explicit inverse.

Is anything complected?

No. Permute has one role.

Could existing forms express it?

No. Permute is algebraically primitive.

## Implementation Scope

**Zero changes.** Permute exists in current holon-rs. This proposal affirms the existing implementation.

**For documentation completeness:**

```rust
pub fn permute(v: &Vector, k: i32) -> Vector {
    let d = v.len();
    let shift = ((k % d as i32) + d as i32) as usize % d;  // normalize to [0, d)
    (0..d).map(|i| v[(i + shift) % d]).collect()
}
```

For cyclic-shift permutation. Other permutation choices (e.g., bit-reversal, random fixed permutation) change the implementation but not the algebraic role.

## Questions for Designers

1. **Is this proposal needed?** Permute's core status is universally accepted. This document exists for leaves-to-root completeness. Is the "already core, affirmation" proposal category the right framing, or is an audit-level entry sufficient?

2. **Permutation choice.** Cyclic shift is conventional. Other permutations (bit-reversal, random-fixed) have different decorrelation properties. Should wat specify the convention, or leave it to the holon-rs implementation? Recommendation: cyclic-shift is the canonical default; document and standardize.

3. **Negative and large step values.** `Permute(v, 1000000)` should normalize modulo `d`. Document the modular-reduction behavior. Negative steps give the inverse; very-positive steps wrap.

4. **Permutation orders other than cyclic.** Some VSA work uses "permutation by a random permutation" (a fixed shuffle chosen from a seed). This is strictly more entropy-per-step but computationally identical once the permutation is cached. Is this worth exposing as a variant, or is cyclic-shift sufficient?

5. **Relationship to `Sequential`, `Array`, `nth`.** Permute's invertibility underpins all three. If Permute were changed (e.g., to a non-invertible hash-shuffle), those stdlib forms would break. Confirm invertibility is a hard requirement, not a convention.

6. **Step-count naming.** The parameter is `k` (step count) — not an angle, not a permutation, not a seed. Should wat use a more descriptive name (`step`, `shift`, `rotation`)? Matching holon-rs's `permute(v, k)` signature is the straightforward choice.
