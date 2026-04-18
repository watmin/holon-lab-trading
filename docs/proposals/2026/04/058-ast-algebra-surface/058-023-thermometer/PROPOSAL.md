# 058-023: `Thermometer` — Core Primitive Affirmation

**Scope:** algebra
**Class:** CORE (existing primitive — this proposal affirms)
**Parent:** 058-ast-algebra-surface
**Foundation:** ../FOUNDATION.md

## The Candidate

`Thermometer` is the primitive scalar-to-vector encoder. It takes a numeric value and a range, and produces a dense-bipolar vector whose monotonic gradient encodes the value's position in the range.

```scheme
(Thermometer value min max)
```

Three arguments: a numeric `value`, and the range bounds `min` and `max`. All three are scalars (typically `:f64`).

### Operation

The value's normalized position in the range is `t = (value - min) / (max - min) ∈ [0, 1]`. Thermometer produces a bipolar vector of dimension `d` where the first `t · d` dimensions are `+1` and the rest are `-1`:

```
Thermometer(value, min, max)[i] = +1 if i < (d · t)
                                = -1 otherwise
```

Where `t` is clamped to `[0, 1]` if `value` falls outside `[min, max]`.

### Canonical layout (load-bearing for distributed consensus)

The "which dimensions are `+1`" question has ONE canonical answer across all conforming implementations:

**Given dimension `d`, let `N = round(d · clamp((value − min) / (max − min), 0, 1))`. Then:**
- **Dimensions `0..N` (the first `N`) are `+1`.**
- **Dimensions `N..d` (the remaining `d − N`) are `-1`.**
- **Value `≤ min`** → all dimensions `-1` (N = 0).
- **Value `≥ max`** → all dimensions `+1` (N = d).

This rule is bit-identical across nodes. Two independent wat-vm implementations running at the same `d` produce the same `Vec<i8>` for the same `(Thermometer v mn mx)` call. Downstream cosine, hash, signing, engram transmission — all rely on this layout being stable.

This is the layout `holon-rs` implements (see `src/kernel/scalar.rs` `encode_thermometer`); the trading lab has run against it across 652k candles at `d=10,000` and multiple production lab runs. The geometry is proven empirically: discriminants learn across the linear gradient; reckoners distinguish close values via cosine; Blend over Thermometers produces the expected weighted interpolation.

Implementations MUST follow this rule to remain canonical. Alternative layouts (permuted, interleaved, hash-seeded) break the distributed-verifiability contract.

### Cosine property

The layout above gives exact linear cosine geometry:

```
cosine(Thermometer(a, min, max), Thermometer(b, min, max))
  = 1 - 2 · |a - b| / (max - min)
```

- `a = b` → cosine 1.0 (same vector)
- `|a − b| = (max − min) / 2` → cosine 0.0 (orthogonal-in-sign-count)
- `a = min`, `b = max` → cosine −1.0 (opposites)

This linear relationship between value distance and vector similarity is what makes downstream learning tractable. A reckoner learning a discriminant direction over Thermometer-encoded scalars learns a direction that corresponds to a threshold in scalar-space.

### Other key properties

- **Monotonic gradient.** The cumulative sum rises linearly from `0` (at `t = 0`) to `d` (at `t = 1`). This gradient structure is what makes Blend-between-thermometers produce meaningful similarity between nearby values.
- **Deterministic.** Same `(value, min, max, d)` always produces the same vector. No codebook needed.
- **Similarity-smooth.** `Thermometer(50, 0, 100)` and `Thermometer(52, 0, 100)` differ in only a few dimensions — their cosine similarity is close to 1. `Thermometer(10, 0, 100)` and `Thermometer(90, 0, 100)` differ in most dimensions — cosine close to 0. The similarity between vectors DIRECTLY reflects numeric distance of the encoded values.

### Why 3-arity is the right signature

Earlier drafts proposed `(Thermometer atom dim)` — seeded by an atom, anchor-style. That was a mental leftover from a different VSA scalar-encoding tradition (Blend-between-two-atom-anchors). Under the direct Thermometer-coding primitive, no atoms are needed — the gradient is computed from the value and range directly.

The `d` dimension is inherited from the wat-vm's global dimension (per FOUNDATION's Dimensionality section); it doesn't need to be passed explicitly at the Thermometer call site.

### AST shape

```rust
pub enum HolonAST {
    // ... other variants ...
    Thermometer { value: f64, min: f64, max: f64 },
}
```

Three scalar fields on the AST node. Present in current `HolonAST`.

### Usage in composition

Thermometer is directly a Holon. Combine freely:

```scheme
;; Bind a name to a scalar-encoded value
(Bind (Atom "some-measure") (Thermometer 25.0 0.0 100.0))

;; Build a scalar-field record
(Map (list
  (list (Atom :open)   (Thermometer 100.0 0.0 200.0))
  (list (Atom :high)   (Thermometer 105.0 0.0 200.0))
  (list (Atom :low)    (Thermometer 98.0  0.0 200.0))
  (list (Atom :close)  (Thermometer 102.0 0.0 200.0))))

;; Use as a query key
(cleanup (Bind (Thermometer 50.0 0.0 100.0) record) vocabulary)
```

Linear, Log, Circular (058-008/017/018) become compositions that wrap Thermometer with different value transformations (linear direct, log-transform-before-thermometer, trigonometric-transform-for-wraparound).

## Why This IS Core

**1. Thermometer cannot be expressed in Bind + Bundle + Permute + Atom alone.**

Atom produces a pseudo-random dense-bipolar vector (hash-seeded). Bind, Bundle, Permute are combination primitives that don't introduce gradient structure. None of them produce a vector with MONOTONIC structure — a cumulative direction from "low" to "high."

Thermometer's gradient IS the new algebraic content. It is the primitive that introduces continuous-value encoding into an otherwise discrete algebra.

**2. Thermometer is the essential anchor for Blend-based scalar encoding.**

Every scalar encoder (Linear, Log, Circular — now stdlib per 058-008, 058-017, 058-018) uses two Thermometers as anchors and Blends between them. Remove Thermometer and all scalar encoding collapses.

The decomposition in FOUNDATION:
- Blend is the GENERIC weighted combiner (core, 058-002)
- Thermometer is the GRADIENT PRIMITIVE that Blend interpolates over (core, this)
- Linear/Log/Circular are STDLIB compositions of Blend over Thermometers (058-008/017/018)

Thermometer is the only one of these that cannot be decomposed further. It is algebraically primitive.

**3. Thermometer introduces magnitude semantics to a ternary algebra.**

In the algebra's ternary output space `{-1, 0, +1}^d`, dense-bipolar vectors have L2 magnitude √d. Thermometer encodes "position along a direction" as a fraction of dimensions in one state vs. the other — effectively projecting a continuous value onto the dense-bipolar sub-lattice of the ternary substrate.

This projection is the bridge between continuous-value scalar encoding and the discrete algebra. Without Thermometer, there is no bridge.

**4. Thermometer's output survives thresholding.**

A key property: a Thermometer vector is dense-bipolar `{-1, +1}` (no zeros by construction), so threshold operations downstream preserve it. This makes Thermometer THE natural anchor for Blend's output (which is thresholded into `{-1, 0, +1}^d` per FOUNDATION's "Output Space" section).

Compare: if we tried to use an "analog gradient" vector as the Blend anchor (all values in `[-1, +1]` not just `{-1, +1}`), Blend's ternary threshold would destroy the gradient's subtlety. Thermometer's discrete-gradient form is specifically designed to survive thresholding — that is its algebraic virtue.

## Arguments For Core Status

**1. Used by every scalar encoder.**

Linear (058-008), Log (058-017), Circular (058-018) all depend on Thermometer. Without Thermometer as core, these stdlib forms have no anchor to blend between.

**2. Holon library precedent.**

Holon-rs exposes `thermometer(atom, dim)` as a first-class operation. It is one of the canonical scalar encoders in VSA literature (Plate et al. discuss thermometer coding as a basic technique).

**3. Deterministic from atom seed.**

Because Thermometer is seeded by an atom, the same atom always produces the same gradient. This supports distributed consensus (coordination-free atom encoding per FOUNDATION): any node computing `Thermometer(:price-low, 4096)` gets the same vector.

## Arguments Against Removing or Reframing

This is affirmation. Could Thermometer be reframed?

Candidates:
- **Stdlib over Atom + positional bit generator?** Would need a "bit-at-position" primitive that doesn't currently exist.
- **Stdlib over Bundle of Atoms?** Doesn't produce the gradient — Atoms are pseudo-random, not monotonic.
- **Stdlib over primitive Gradient that returns raw fractional vectors + threshold?** Shifts the primitive's location but doesn't reduce the algebra.

None of these provide simpler expression. Thermometer IS the primitive.

## Comparison

| Primitive | Output shape | Gradient? | Role |
|---|---|---|---|
| `Atom(literal)` | hash-seeded dense-bipolar | NO (pseudo-random) | Literal encoding |
| `Thermometer(atom, dim)` | seeded dense-bipolar GRADIENT | YES (monotonic) | Scalar gradient anchor |
| `Bind(a, b)` | product of operands | N/A (combinator) | Reversible combination |
| `Bundle(xs)` | threshold(sum) | N/A (combinator) | Superposition |
| `Permute(v, k)` | dimension shuffle | N/A (combinator) | Positional distinction |

Thermometer is the only CORE primitive with gradient structure. Atom is the only other primitive that creates vectors from literal input, but Atom's output is pseudo-random without gradient.

## Algebraic Question

Does Thermometer compose with the existing algebra?

Yes. Output is dense-bipolar within the ternary output space `{-1, 0, +1}^d`; Blend, Bind, Bundle, Permute all accept it without modification.

Is it a distinct source category?

Yes. "Gradient-encoded dense-bipolar vector" is categorically unique.

## Simplicity Question

Is this simple or easy?

Simple. One operation. Two arguments. One semantic (gradient seeded by atom).

Is anything complected?

Possibly the atom-to-position mapping — how exactly does an atom determine its gradient's transition point? This is an implementation detail that should be CONSISTENT across the algebra but may vary in design. Document the convention: e.g., `position = hash(atom) / 2^64 ∈ [0, 1]`, or `position = fixed_per_atom_mapping(atom)`.

Could existing forms express it?

No. Thermometer is algebraically primitive.

## Implementation Scope

**Zero changes.** Thermometer exists in current holon-rs. This proposal affirms the existing implementation.

**For documentation completeness, a typical implementation:**

```rust
pub fn thermometer(atom: &Atom, dim: usize) -> Vector {
    let position = atom_to_fractional_position(atom);      // implementation detail
    let threshold_idx = (position * dim as f64) as usize;
    (0..dim).map(|i| if i < threshold_idx { 1i8 } else { -1i8 }).collect()
}
```

The `atom_to_fractional_position` function is the convention that maps atoms to gradient positions. Could be a deterministic hash, a fixed per-atom lookup, or derived from the atom's encoded vector's sign-pattern entropy. Implementation choice; algebraic role is the gradient.

## Questions for Designers

1. **Is this proposal needed?** Thermometer's core status is universally accepted. This document exists for leaves-to-root completeness. Audit-level entry vs. full proposal — which is the right framing?

2. **Atom-to-position mapping convention.** How exactly does an atom determine its Thermometer's transition point? The specific mapping affects interop — all consumers must use the same convention for the same atom to produce the same gradient. Document the canonical mapping.

3. **Gradient direction.** This proposal assumes "+1s below threshold, -1s above" (positive gradient). Could also be the reverse. The specific choice is a convention; document it.

4. **Single threshold vs. continuous gradient.** The implementation above produces a SINGLE transition (below: +1, above: -1). An alternative is a SMOOTHER gradient (e.g., +1 for some dimensions, -1 for others, distributed according to a function of position). Smoother gradients might produce richer Blend outputs. Design choice; single-threshold is simpler and conventional.

5. **Relationship to Atom.** Can `Atom(:something)` and `Thermometer(:something, 4096)` produce DIFFERENT vectors? Yes — Atom is pseudo-random, Thermometer is monotonic gradient. But they share the same SEED. Document that an atom deterministically produces both its own "pure" vector (via Atom) and a range of derived vectors (via Thermometer, Permute, etc.) — all from the same seed.

6. **Dense-bipolar vs. general ternary output.** Per FOUNDATION's "Output Space" section, the algebra's output space is ternary `{-1, 0, +1}^d`. Thermometer by construction produces a **dense-bipolar** vector (no zeros), which is a subset of the ternary space. A variant that actively uses `0` for "middle/uncertain" is plausible but would be a different primitive; keep Thermometer's current definition and propose any zero-bearing gradient separately.

7. **dim argument.** The `dim` argument makes the output width explicit. Should Thermometer be made dim-implicit (derive dim from context/configuration)? Recommendation: keep explicit — matches other primitives that take explicit widths.
