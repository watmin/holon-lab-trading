# 058-021: `Bind` — Core Primitive Affirmation

**Scope:** algebra
**Class:** CORE (existing primitive — this proposal affirms)
**Parent:** 058-ast-algebra-surface
**Foundation:** ../FOUNDATION.md

## The Candidate

`Bind` is the elementwise reversible combination operation — the primitive that turns two vectors into a THIRD vector which, given either original, can be used to recover the other.

```scheme
(Bind a b)
```

Two thought arguments. No scalar parameters.

### Operation

For vectors `a, b` in the algebra's ternary output space `{-1, 0, +1}^d` (see FOUNDATION's "Output Space" section):

```
Bind(a, b)[i] = a[i] * b[i]
```

Elementwise multiplication. In MAP VSA (Multiply-Add-Permute, Gayler 2003), this is the canonical binding operation. For dense-bipolar `{-1, +1}` inputs, it is equivalent to XNOR — the result is `+1` where `a` and `b` agree in sign, `-1` where they differ. When either input carries a zero at dimension `i`, Bind inherits that zero (`0 * x = 0`) — the "no information here" signal propagates through.

### Key property: self-inverse under similarity measurement

The elementwise identity:

```
Bind(Bind(a, b), b)[i] = a[i] · b[i]²
                       = a[i]    wherever b[i] ∈ {-1, +1}
                       = 0       wherever b[i] = 0
```

**For dense-bipolar keys** (vectors produced by `Atom` or `Thermometer`, all `±1`): exact recovery elementwise. `cos(Bind(Bind(a,b), b), a) = 1`.

**For sparse keys**: the recovered vector has `a[i]` at non-zero positions and `0` at zero positions. Under cosine similarity, this recovers proportionally to the non-zero fraction. At `d = 10,000`, reasonable sparsity still places the recovered vector well above the 5σ noise threshold — decode succeeds under the algebra's similarity-measured recovery framework.

This is not a weakening; it is **capacity consumption** in the same budget as Bundle crosstalk (see FOUNDATION's "Capacity is the universal measurement budget" section). Sparse keys spend more of the frame's ~100-item budget per decode; dense keys spend less. The substrate is similarity-measured throughout; exact elementwise equality was never the recovery criterion — similarity-above-noise was.

This reversibility is the foundational mechanism for STRUCTURE-PRESERVING encoding. A role `r` bound to a filler `f` produces `Bind(r, f)`. Given the composite and the role, the filler is recovered via `Bind(composite, r) = f` — exactly at dimensions where `r` carries signal, contributing zero where it doesn't, and the similarity test reads the result uniformly.

### AST shape (already exists)

```rust
pub enum ThoughtAST {
    // ... other variants ...
    Bind(Arc<ThoughtAST>, Arc<ThoughtAST>),
}
```

Binary AST node. Present in current `ThoughtAST`.

## Why This IS Core

**1. Bind cannot be expressed in Bundle + Permute + Atom alone.**

Bundle is elementwise sum (with threshold). Permute is dimension shuffle. Atom is a seeded vector from a hash. None of these produce elementwise multiplication between two dynamic vectors. Bind is algebraically PRIMITIVE — not derivable from other primitives.

**2. Bind's reversibility is unique in the algebra.**

Only Bind has the property that `Bind(Bind(a, b), b) = a` (on non-zero positions of `b`). Bundle is LOSSY (the threshold collapses information). Permute is reversible but doesn't COMBINE two vectors into one. Orthogonalize (058-005) removes direction, not reversibly. Bind is the unique combine-and-invert primitive.

**3. Role-filler binding is the structural mechanism.**

The entire "encoded JSON" / "structured thought" / "role-filler knowledge graph" story of VSA relies on Bind. Without Bind, there is no way to associate a role with a filler such that the association can be later queried. Remove Bind, and the algebra loses structure.

**4. MAP VSA's "M" is Bind.**

MAP VSA = Multiply, Add, Permute. The Multiply is Bind. The Add is Bundle. The Permute is Permute. These three are the algebra's IRREDUCIBLE core — the algebraic skeleton of hyperdimensional computing per Gayler's 2003 formulation.

FOUNDATION affirms this. Bind's core status is not up for debate; this proposal documents the affirmation.

## Arguments For Core Status

**1. Decades of VSA literature.**

Bind appears in every VSA formulation:
- Plate's Holographic Reduced Representations (circular convolution)
- Kanerva's Binary Spatter Codes (XOR)
- Gayler's MAP (multiplication)
- Eliasmith's Semantic Pointer Architecture (circular convolution)

Different implementations, same algebraic role. Bind is CANONICAL in VSA.

**2. Used by every stdlib form that encodes structure.**

`Map(kv-pairs)` = `Bundle(Bind(k, v) for each pair)` (058-016).
`Array(thoughts)` = `Sequential(thoughts)` uses Permute but often also Bind for indexing.
Role-filler encoding (canonical JSON→vector in holon) relies on Bind per-key.

Without Bind as core, the stdlib collapses.

**3. Efficient implementation.**

Elementwise multiplication is O(d), cache-friendly, SIMD-friendly. For dense-bipolar `{-1, +1}` vectors represented as bits, Bind is XNOR — even faster. (Zero-aware ternary storage uses a small additional mask; see the implementation notes.)

## Arguments Against Removing or Reframing

This proposal is affirmation — not a reclassification. But for completeness: could Bind be reframed as stdlib over some lower-level primitive?

Candidates:
- Elementwise operation primitive? Would be even more primitive but doesn't exist in current algebra.
- XOR primitive? Specific to bitwise representation; loses generality.

None of these are currently in the algebra. Bind IS the primitive. No reframing is available.

## Comparison

| Primitive | Operation | Reversibility | Role |
|---|---|---|---|
| `Bind(a, b)` | `a[i] * b[i]` | `Bind(Bind(a, b), b) = a` on non-zero positions | Structure binding |
| `Bundle(xs)` | `threshold(Σ xs[i])` | NOT reversible | Superposition |
| `Permute(v, k)` | dimension shuffle | inverse exists | Positional distinction |
| `Atom(literal)` | hash-to-vector | N/A (primitive) | Literal encoding |
| `Thermometer(atom, dim)` | gradient vector | N/A (primitive) | Scalar gradient |

Bind is the only CORE primitive with reversible combination semantics.

## Algebraic Question

Does Bind compose with the existing algebra?

Yes — it is foundational to it. Every other core and stdlib form assumes Bind exists.

Is it a distinct source category?

Yes. "Reversible elementwise combination" is categorically unique. No other form has this property.

## Simplicity Question

Is this simple or easy?

Simple. One operation. One semantic. One line of implementation.

Is anything complected?

No. Bind has one role (reversible combination) and does not mix in other concerns.

Could existing forms express it?

No. Bind cannot be derived from Bundle, Permute, Atom, or Thermometer. It is algebraically primitive.

## Implementation Scope

**Zero changes.** Bind exists in current holon-rs. This proposal affirms the existing implementation.

**For documentation completeness:**

```rust
pub fn bind(a: &Vector, b: &Vector) -> Vector {
    a.iter().zip(b.iter())
        .map(|(&ai, &bi)| ai * bi)
        .collect()
}
```

For bit-packed dense-bipolar inputs: XNOR of the bitmasks. SIMD-optimized in current holon-rs. Zero-aware ternary storage uses an additional "has-value" mask; Bind of ternary is multiplication of value masks ANDed with intersection of has-value masks.

## Questions for Designers

1. **Is this proposal needed?** Bind's core status is universally accepted. This document exists for leaves-to-root completeness (every UpperCase form gets a doc) rather than because the question is open. Is that the right use of a proposal, or is an "already core" audit entry sufficient?

2. **Reversibility formalism.** Per FOUNDATION's "Output Space" section, Bind is **self-inverse on non-zero positions** of the key. `Bind(Bind(a, b), b)[i] = a[i]` wherever `b[i] ≠ 0`, and `= 0` wherever `b[i] = 0`. This is the load-bearing law. Resolved.

3. **Relationship to Unbind (058-024).** Bind's inverse is conventionally named `Unbind`. `Unbind(c, b) = Bind(c, b)` since Bind is self-inverse on non-zero positions (per FOUNDATION's "Output Space"); the decode uses the same operation. Is Unbind a distinct primitive or an alias? Recommendation: keep Unbind as a named stdlib alias even though it equals Bind — documents the "decode" intent.

4. **Normalization of output.** Bind for dense-bipolar inputs produces dense-bipolar output (product of ±1s). For ternary inputs with zeros, Bind inherits the zeros — no threshold needed because elementwise multiplication stays inside `{-1, 0, +1}^d`. Document per FOUNDATION's "Output Space" section.

5. **Naming convention.** Some VSA literature uses `⊛` (circle-asterisk), `*`, or `mult`. Holon uses `bind`. Confirm the wat name is `Bind` (PascalCase per convention).
