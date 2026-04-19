# 058-006: `Resonance` — Sign-Agreement Mask

**Scope:** algebra
**Class:** ~~CORE~~ **REJECTED**
**Parent:** 058-ast-algebra-surface
**Foundation:** ../FOUNDATION.md

---

## REJECTED from 058

**Reason — speculative, no production use.** Resonance appears in the Holon Python library as API surface but does NOT have a cited application in any challenge batch (001–018), the DDoS lab, or the trading lab. Its entry in `blog/primers/series-001-002-holon-ops.md` has no "Application:" citation — the only operations without citations in that primer are Resonance and ConditionalBind (058-007). The 2026 primer documents what the library contains, not what the algebra has earned.

**Also, Q2 of Round 2 reveals it's at the wrong level.** The more general primitive is `Mask(x, boolean-vector)` — zero dimensions where a mask says so. Resonance is then a stdlib idiom: `Resonance(x, y) = Mask(x, sign-agreement(x, y))`. But `Mask` is not proposed in 058 either, and `sign-agreement` is a threshold composition over `Bind`. Adding Resonance as core would lock in the wrong abstraction before the right one was justified.

**What to do when you need it.** If an application demands "keep dimensions where two vectors agree in sign," it's a three-primitive composition using existing forms: `threshold(Bind(x, y), +1)` gives the agreement mask as a `{0, 1}^d` vector; multiplying against `x` (itself a Bind) applies it. No new core primitive required.

**If real use emerges later**, propose the refined primitive: either `Mask(x, boolean-vector)` as the general abstraction with Resonance as a stdlib macro over it, or Resonance itself with concrete application evidence (which challenge batch, what measurement, what couldn't be expressed via the three-primitive composition).

The algebra core shrinks to 7 forms: Atom, Bind, Bundle, Blend, Permute, Thermometer, Orthogonalize.

See FOUNDATION-CHANGELOG for the 2026-04-18 rejection record.

---

## Historical content (preserved as audit record)

## The Candidate

A new core variant that keeps the dimensions where two vectors agree in sign and zeros the dimensions where they disagree:

```scheme
(:wat::algebra::Resonance v reference)
```

Semantically: `v` filtered through `reference` — the components of `v` that "resonate" with (point the same direction as) `reference` survive; the dissonant components are silenced.

### Operation (per-dimension)

For bipolar vectors `v, reference ∈ {-1, +1}^d`:

```
Resonance(v, ref)[i] = v[i]  if  sign(v[i]) == sign(ref[i])
                     = 0     otherwise
```

Equivalent closed form using existing primitives (see Arguments Against):

```
mask[i] = (Bind(v, ref)[i] + 1) / 2        ∈ {0, 1}
Resonance(v, ref)[i] = v[i] * mask[i]       ∈ {-1, 0, +1}
```

### AST shape

```rust
pub enum HolonAST {
    // ... existing variants ...
    Resonance(Arc<HolonAST>, Arc<HolonAST>),
}
```

Two holon arguments. No scalar parameters.

## Why This Earns Core Status

**1. It produces zeros by selection, not by arithmetic cancellation.**

Under the algebra's ternary output space (FOUNDATION's "Output Space" section, `threshold(0) = 0`), every core form can produce `0` at a dimension. What makes Resonance distinct is HOW it produces zeros: by per-dimension SELECTION based on sign-agreement between `v` and `ref`. Bind, Bundle, Blend, Orthogonalize produce zeros via arithmetic cancellation (contributions sum to 0); Resonance produces zeros via explicit gating ("these dimensions do not resonate").

Both outcomes yield valid ternary vectors. But the operational semantics are categorically distinct — selection-based gating is not expressible as weighted arithmetic.

The zero at a dimension means "this dimension carries no signal because `v` and `ref` disagreed there." Downstream operations (similarity, cleanup, further binding) interpret zeros as "no information" — same contract as zeros produced by any other core form.

**2. Not cleanly expressible with current core forms.**

The mask-and-multiply approach above requires:
- elementwise multiplication (Bind gives us this)
- elementwise `(x + 1) / 2` scaling (outside Blend's uniform-weight model — Blend applies weights to whole vectors, not per-dimension affine)
- elementwise multiplication of `v` by a `{0, 1}` mask (again, per-dimension gating, not vector-uniform)

Blend's operation is `threshold(w1·a + w2·b)` — the weights are scalars applied uniformly to each vector. There is no core form that produces a `{0, 1}` per-dimension selector from two vectors and then applies it.

Could we add per-dimension gating as a separate primitive and build Resonance from it? Possibly. That would be a different proposal and arguably more primitive (a "Mask" or "Gate" operation). Until that exists, Resonance is its own form.

**3. It is the natural "alignment filter."**

Resonance answers: "Given what I observe (v), which parts of it are consistent with my reference model?" The non-resonant dimensions are where my observation disagrees with the model — literally orthogonal information, which can be isolated separately.

This is complementary to Orthogonalize (058-005): Orthogonalize removes the reference's direction proportionally; Resonance retains only the dimensions that SHARE the reference's sign. Different invariants, different use cases.

## Operation Semantics in Detail

Example with `d=5`:

```
v         = [+1, -1, +1, -1, +1]
ref       = [+1, +1, +1, -1, -1]
bind(v,r) = [+1, -1, +1, +1, -1]        ; elementwise product
agree     = [ 1,  0,  1,  1,  0]        ; (bind + 1) / 2
result    = [+1,  0, +1, -1,  0]        ; v * agree
```

Dimensions 0, 2, 3 survived (signs matched). Dimensions 1, 4 were silenced (signs differed).

## Arguments For

**1. Common semantic pattern.**

"Keep only what aligns with my reference" appears repeatedly in attention, filtering, and cleanup contexts:
- Attending to the aligned part of an input
- Filtering a signal against a prototype
- Preserving consistent components of an aggregate

The holon library exposes `attend` as a resonance-like operation. FOUNDATION treats it as a first-class algebraic operation.

**2. Cheap to implement.**

```rust
pub fn resonance(v: &Vector, reference: &Vector) -> Vector {
    v.iter().zip(reference.iter())
        .map(|(&vi, &ri)| if vi.signum() == ri.signum() { vi } else { 0 })
        .collect()
}
```

O(d), one pass, no dot products or divisions. Simpler than Orthogonalize.

**3. Output is a meaningful vector.**

The result is still a vector in the same `d`-dimensional space (just with some zeros). Downstream operations — similarity, bind, bundle — work without modification. The zeros behave as neutral elements (a zero dimension contributes nothing to similarity, does not propagate through bind). Graceful degradation.

## Arguments Against

**1. Could be a stdlib composition if we add Mask/Gate.**

If the algebra had a general `Mask(x, selector)` primitive (keep x where selector is +1, zero where selector is -1 or 0), then Resonance would be stdlib:

```scheme
(:wat::core::define (:wat::std::Resonance v ref)
  (Mask v (sign-agreement v ref)))
```

But `Mask` and `sign-agreement` aren't currently in the algebra. Introducing them is a larger proposal than Resonance itself. For the current core, Resonance is the pragmatic choice.

**2. Ternary semantics complicate downstream reasoning.**

Every other core form (Bind, Bundle, Blend, Permute, Orthogonalize) produces strictly bipolar output. Resonance breaks that invariant. Any consumer of Resonance output must handle `{-1, 0, +1}` — similarity calculations, cleanup, further composition.

Most similarity measures (cosine, dot product) handle zeros naturally. But it is worth naming that Resonance is the ONLY form (so far) that produces ternary vectors.

**Mitigation:** this ternary property is the POINT. The zeros are information: "we have no signal here." Collapsing them back to bipolar (via `threshold` rounding 0 randomly to ±1) would destroy the semantic value.

**3. Is this just `Bind` in disguise?**

`Bind(v, ref)` for bipolar vectors is elementwise multiplication, producing `{-1, +1}^d`:
- +1 where signs agree
- -1 where signs disagree

`Resonance(v, ref)` produces `{-1, 0, +1}^d`:
- v[i] where signs agree (so +1 or -1)
- 0 where signs disagree

These ARE related, but they're not the same. Bind encodes disagreement as -1; Resonance encodes disagreement as 0. Bind preserves sign information even when disagreeing; Resonance discards it.

Different operational semantics. Different use cases.

**4. Why not `ResonanceDifference(v, ref) = v - Resonance(v, ref)`?**

The orthogonal companion — keep only the DISSONANT dimensions. Could be a separate form for completeness.

**Mitigation:** `v - Resonance(v, ref)` is Blend(v, Resonance(v, ref), 1, -1) — stdlib once both exist. Separating "the aligned part" (Resonance) from "the misaligned part" (its complement) is a decomposition, and the stdlib handles the complement.

## Comparison

| Form | Input sign agreement | Input sign disagreement | Output |
|---|---|---|---|
| `Bind(v, ref)` | `+1` | `-1` | bipolar |
| `Resonance(v, ref)` | `v[i]` (keeps +1 or -1) | `0` | ternary |
| `Orthogonalize(v, ref)` | (scalar projection) | (scalar projection) | bipolar via threshold |

Bind produces a single sign-agreement pattern; Resonance selectively preserves `v` where agreement exists; Orthogonalize removes a projected direction entirely. Three distinct operations on the same inputs.

## Algebraic Question

Does Resonance compose with the existing algebra?

Mostly. Output is a vector in the same dimensional space. Similarity, bind, bundle all accept ternary vectors. The only wrinkle: if we ever define operations that STRICTLY require bipolar input, Resonance's output may need explicit re-thresholding.

`threshold({-1, 0, +1})` is undefined for `0` — does it map to +1 or -1? Implementations must decide. Current Bundle's threshold maps `x < 0 → -1`, `x >= 0 → +1`, which would round `0` to `+1`. That's a surface choice, not a categorical problem.

Is it a distinct source category?

Yes. Under FOUNDATION's ternary output space, every core form CAN produce ternary output, but Resonance is the only form whose zeros come from explicit per-dimension SELECTION rather than arithmetic cancellation. Categorically distinct from all other core forms by mechanism, not by output kind.

## Simplicity Question

Is this simple or easy?

Simple. One elementwise comparison, one elementwise selection. No arithmetic beyond sign checking.

Is anything complected?

The ternary output is a genuine extension to the output space. It is not a separate concern entangled into one form — the operation IS "preserve-or-zero." That is coherent.

Could existing forms express it?

Not cleanly. Bind gets the sign-agreement information but encodes it as `±1`, not as `v or 0`. No current core form produces a zero-preserving selection mask.

## Implementation Scope

**holon-rs changes** (~15 lines):

```rust
pub fn resonance(v: &Vector, reference: &Vector) -> Vector {
    v.iter().zip(reference.iter())
        .map(|(&vi, &ri)| {
            if (vi > 0) == (ri > 0) { vi } else { 0 }
        })
        .collect()
}
```

O(d), branch-heavy but straightforward.

**HolonAST changes:**

```rust
pub enum HolonAST {
    // ... existing variants ...
    Resonance(Arc<HolonAST>, Arc<HolonAST>),
}
```

**Downstream adjustments:**

- `threshold` function, if applied to Resonance output, must specify 0's rounding behavior
- Similarity functions already handle zeros correctly (0 contributes 0 to dot product)
- Cache key includes Resonance variant discriminator

## Questions for Designers

1. **Ternary output as a supported kind.** ~~Resonance is the first core form producing `{-1, 0, +1}` output.~~ RESOLVED by FOUNDATION's "Output Space — Ternary by Default" section: the algebra's output space is ternary across all core forms. Resonance produces zeros deliberately via selection; other forms (Bundle, Blend, Orthogonalize) produce zeros via arithmetic cancellation. All zero-producing mechanisms are first-class.

2. **Should `Mask`/`Gate` be the primitive instead?** A more general `Mask(x, boolean-vector)` primitive would make Resonance stdlib. Is the right level of generality "sign-agreement masking" (Resonance, concrete) or "arbitrary masking" (Mask, more general)?

3. **Complement form `AntiResonance` or `Dissonance`?** "Keep only the dimensions that DISAGREE" — `Dissonance(v, ref) = v - Resonance(v, ref)`. Can be stdlib once Resonance and Blend exist. Worth a first-class form for symmetry, or let stdlib handle it?

4. **Relationship to `threshold`.** If we pass Resonance output through threshold (rounding 0 → +1), we lose the "no information" semantics. Should threshold be aware of ternary input and leave zeros alone, or is it purely a `x<0 → -1, x≥0 → +1` mapping with no nuance?

5. **Holon's `attend` vs this `Resonance`.** Holon's `attend` is related but not identical (attend uses magnitude-weighted filtering, not just sign-agreement). Is this proposal naming the operation correctly, or should it reference `attend`'s exact definition? Clarify the lineage.
