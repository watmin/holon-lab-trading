# 058-023: `Thermometer` — Core Primitive Affirmation

**Scope:** algebra
**Class:** CORE (existing primitive — this proposal affirms)
**Parent:** 058-ast-algebra-surface
**Foundation:** ../FOUNDATION.md

## The Candidate

`Thermometer` is the scalar-gradient primitive — it produces a bipolar vector whose dimensions encode a monotonic gradient along a direction seeded by an atom.

```scheme
(Thermometer atom dim)
```

One atom argument (the anchor identity) and one dimension count (the vector width).

### Operation

Given an atom `a` and a dimension count `d`, Thermometer produces a bipolar vector `v ∈ {-1, +1}^d` where some fixed-from-the-atom's-seed pattern specifies the "gradient" — the direction of increasing magnitude.

Concretely, Thermometer typically produces:

```
Thermometer(atom, d)[i] = +1 if i < (d * t(atom))
                        = -1 otherwise
```

Where `t(atom)` is some atom-dependent position in `[0, 1]`. The specific position is part of the atom's deterministic seeding — different atoms produce thermometer vectors with different "transition points."

The key property: the CUMULATIVE SUM of a Thermometer vector monotonically advances from one end (all +1s below the transition) to the other (all -1s above). This produces a GRADIENT that Blend can interpolate over.

### AST shape (already exists)

```rust
pub enum ThoughtAST {
    // ... other variants ...
    Thermometer(Atom, usize),
}
```

One atom + one dim. Present in current `ThoughtAST`.

## Why This IS Core

**1. Thermometer cannot be expressed in Bind + Bundle + Permute + Atom alone.**

Atom produces a pseudo-random bipolar vector (hash-seeded). Bind, Bundle, Permute are combination primitives that don't introduce gradient structure. None of them produce a vector with MONOTONIC structure — a cumulative direction from "low" to "high."

Thermometer's gradient IS the new algebraic content. It is the primitive that introduces continuous-value encoding into an otherwise discrete algebra.

**2. Thermometer is the essential anchor for Blend-based scalar encoding.**

Every scalar encoder (Linear, Log, Circular — now stdlib per 058-008, 058-017, 058-018) uses two Thermometers as anchors and Blends between them. Remove Thermometer and all scalar encoding collapses.

The decomposition in FOUNDATION:
- Blend is the GENERIC weighted combiner (core, 058-002)
- Thermometer is the GRADIENT PRIMITIVE that Blend interpolates over (core, this)
- Linear/Log/Circular are STDLIB compositions of Blend over Thermometers (058-008/017/018)

Thermometer is the only one of these that cannot be decomposed further. It is algebraically primitive.

**3. Thermometer introduces magnitude semantics to a bipolar algebra.**

In pure bipolar `{-1, +1}^d` vector spaces, every vector has the same L2 magnitude (√d). Thermometer encodes "position along a direction" as a fraction of dimensions in one state vs. the other — effectively projecting a continuous value onto a discrete bipolar substrate.

This projection is the bridge between continuous-value scalar encoding and the bipolar discrete algebra. Without Thermometer, there is no bridge.

**4. Thermometer's output survives thresholding.**

A key property: a Thermometer vector is already bipolar `{-1, +1}`, so threshold operations downstream preserve it. This makes Thermometer THE natural anchor for Blend's output (which is thresholded).

Compare: if we tried to use an "analog gradient" vector as the Blend anchor (all values in `[-1, +1]` not just `{-1, +1}`), Blend's threshold would destroy the gradient's subtlety. Thermometer's discrete-gradient form is specifically designed to survive thresholding — that is its algebraic virtue.

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
| `Atom(literal)` | hash-seeded bipolar | NO (pseudo-random) | Literal encoding |
| `Thermometer(atom, dim)` | seeded bipolar GRADIENT | YES (monotonic) | Scalar gradient anchor |
| `Bind(a, b)` | product of operands | N/A (combinator) | Reversible combination |
| `Bundle(xs)` | threshold(sum) | N/A (combinator) | Superposition |
| `Permute(v, k)` | dimension shuffle | N/A (combinator) | Positional distinction |

Thermometer is the only CORE primitive with gradient structure. Atom is the only other primitive that creates vectors from literal input, but Atom's output is pseudo-random without gradient.

## Algebraic Question

Does Thermometer compose with the existing algebra?

Yes. Output is bipolar; Blend, Bind, Bundle, Permute all accept it without modification.

Is it a distinct source category?

Yes. "Gradient-encoded bipolar vector" is categorically unique.

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

6. **Bipolar-only vs. ternary.** Thermometer produces bipolar `{-1, +1}` output. A ternary version (+1 / 0 / -1, where 0 is "middle/uncertain") is plausible but not currently in the algebra. Keep Thermometer strictly bipolar per its current definition; ternary extensions would be separate proposals.

7. **dim argument.** The `dim` argument makes the output width explicit. Should Thermometer be made dim-implicit (derive dim from context/configuration)? Recommendation: keep explicit — matches other primitives that take explicit widths.
