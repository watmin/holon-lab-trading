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

### Bind has two roles: encoding and querying

**Encoding (symmetric):** `(Bind role filler)` composes a role-filler pair. Both arguments are treated equivalently; the product is a new vector carrying the pairing.

**Querying (asymmetric):** `(Bind key bundle)` asks "what is bound to `key` inside `bundle`?" The product is a noisy vector that — when compared against candidate values via cosine similarity — answers the query.

### The query's outcome is runtime-measurable

After computing `(Bind key bundle)`, the caller checks cosine similarity of the result against candidate values:

- **Above 5σ** — query RESOLVED. The key was bound in the bundle with high confidence; the recovered value is the candidate with the highest similarity.
- **Below 5σ** — query FAILED. Either the key wasn't present, the bundle exceeded capacity, or crosstalk from other bindings masked the signal.

This is observable. The machine runs the Bind, measures cosine, and knows whether the query worked. No hidden failures — they surface as similarity below threshold, at runtime, at the call site.

Elementwise, `Bind(Bind(a, b), b)[i] = a[i] · b[i]²`. For dense-bipolar keys, `b[i]² = 1` at every position, so recovery is elementwise exact. For sparse or mixed keys, `b[i]² ∈ {0, 1}`, so recovery loses signal at zero positions — and the similarity test reports the degradation proportionally. Crowded bundles cost additional budget through crosstalk; the similarity test reports that too.

This is the substrate at work. Bind is the query primitive; cosine similarity is the success signal; Kanerva capacity is the budget. Every query yields not just a value but a CONFIDENCE, and downstream code can act on confidence directly.

### Self-inverse as a claim in the similarity frame

The classical MAP VSA identity `Bind(Bind(a, b), b) = a` holds elementwise only for the special case of dense-bipolar inputs (which is the usual VSA regime). In the general algebra, the identity is similarity-measured:

```
cosine(Bind(Bind(a, b), b), a) ≥ 5σ    within the capacity budget
```

Dense keys give cosine ≈ 1. Sparse keys give cosine proportional to the non-zero fraction. Bundled contexts give cosine that decays with crosstalk. Whatever the regime, the measurement tells you whether the identity holds CLOSELY ENOUGH for the downstream similarity test to succeed.

This is not a weakening of Bind. It is honest about what the substrate actually provides: a runtime-measured query primitive whose success signal is intrinsic to every call. Role-filler encoding and decoding work exactly this way — the encoding composes, the decoding queries, and the similarity test tells you if it worked.

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
