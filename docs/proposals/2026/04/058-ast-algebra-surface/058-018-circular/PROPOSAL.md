# 058-018: `Circular` — Reframe as Stdlib over Blend

**Scope:** algebra
**Class:** STDLIB (reclassification from current CORE variant)
**Parent:** 058-ast-algebra-surface
**Foundation:** ../FOUNDATION.md
**Depends on:** 058-002-blend (pivotal — if Blend rejected, Circular stays core)
**Companion proposals:** 058-008-linear, 058-017-log

## Reclassification Claim

The current `HolonAST` enum has a `Circular(low_atom, high_atom, value, scale)` variant. FOUNDATION's audit lists it as CORE. Under the stdlib criterion (058-002-blend's Blend primitive, plus Thermometer as core), `Circular` is a BLENDING of two endpoint anchor Thermometers with weights derived from sin/cos of a normalized angle.

Circular is structurally identical to Linear (058-008) and Log (058-017): `Blend(Thermometer(low), Thermometer(high), w_low, w_high)` where the weights are scalar functions of the value. The only difference is the weight function — Circular uses trigonometric functions to capture WRAP-AROUND semantics.

With Blend as a pivotal core form (058-002) — and specifically Option B (two INDEPENDENT weights rather than a constrained weight pair) — `Circular` becomes a stdlib macro (per 058-031-defmacro). This proposal reclassifies it accordingly.

## The Reframing

### Current semantics

`Circular(value, period)` encodes values on a circular scale (time-of-day, angles, phase). A value and its `value + period` produce the same vector. The key property: positions equidistant along the circle blend equally.

### Stdlib definition

```scheme
(:wat/core/defmacro (:wat/std/Circular (value :AST) (period :AST) -> :AST)
  `(:wat/core/let* ((angle   (:wat/core/* 2 pi (:wat/core// ,value ,period)))
          (w-cos   (cos angle))                  ;; can be negative
          (w-sin   (sin angle)))                 ;; can be negative
     (:wat/algebra/Blend (:wat/algebra/Atom :wat/std/circular-cos-basis)
            (:wat/algebra/Atom :wat/std/circular-sin-basis)
            w-cos
            w-sin)))
```

`angle` maps `value` to a position on the unit circle. `cos angle` and `sin angle` are the weights — they span a full period as `value` cycles. The two Atoms `:wat/std/circular-cos-basis` and `:wat/std/circular-sin-basis` are fixed reference vectors (seeded by the VectorManager at startup) that span the 2D basis of the circle; Blend's two independent weights let Circular project onto any point on that basis.

Expansion happens at parse time (per 058-031-defmacro), so `hash(AST)` sees only the canonical `(let* ... (Blend (Atom :...) (Atom :...) w-cos w-sin))` form — no `Circular` call node survives into the hashed AST.

### Why Circular earns its stdlib place (under the blueprint test)

Circular demonstrates a **distinct pattern** — Blending two fixed basis Atoms with `(cos, sin)` weights to encode cyclical values. This is categorically different from Thermometer's linear gradient: Circular's weights can be negative, the encoding wraps (`value + period` produces the same vector as `value`), and the two basis Atoms establish a 2D embedding rather than a 1D range. A user who wants cyclic encoding (time-of-day, angle, phase) can't derive this pattern from Thermometer alone. Worth shipping as a blueprint.

## Why Stdlib Earns the Name

**1. Circular is a Blend with trigonometric weights.**

The algebra is Blend. The trigonometry is scalar arithmetic. Separation of concerns places the trig in stdlib and leaves the algebra clean.

**2. Circular justifies Blend Option B (two independent weights).**

This is important. 058-002-blend chose Option B specifically because Circular requires it:
- Linear: `1-t + t = 1` (weights sum to 1)
- Log: `1-log_t + log_t = 1` (weights sum to 1)
- Circular: `cos θ + sin θ ≠ 1` in general (weights can be negative, can sum to anything in `[-√2, √2]`)

Blend with two INDEPENDENT literal weights is exactly what Circular needs. A constrained-sum Blend would not accommodate Circular — which is why Option B was the right choice for Blend.

Reframing Circular as a Blend call demonstrates why Blend's Option B signature earned its place.

**3. Wrap-around encoding is a domain choice, not an algebra.**

The `2π · value / period` mapping is a domain convention — time-of-day wraps at 24 hours, angle wraps at 360°. These are domain decisions that belong in stdlib where users can inspect and modify them.

## Arguments Against

**1. `sin`, `cos`, and `pi` are stdlib dependencies.**

The expansion depends on trigonometric functions and the constant π. If wat's stdlib does not provide these, this reframing depends on their addition.

**Mitigation:** sin, cos, and π are standard math primitives. Adding them to wat is minor if not already present.

**2. Negative weights test Blend's implementation.**

`cos θ` can be negative. Blend must correctly handle negative weights (Option B's whole point). If any implementation optimization assumes non-negative weights, Circular's reframing exposes the bug.

**Mitigation:** this is a feature of the reframing — it pressure-tests Blend's implementation to conform to its Option B specification. Any optimization that breaks negative-weight handling is incorrect per 058-002 and must be fixed.

**3. Period argument shape differs from Linear/Log.**

Linear and Log take `scale = (min, max)` — two bounds. Circular takes `scale = (period,)` — one number. This asymmetry means the three stdlib forms cannot share a uniform `scale` type.

**Mitigation:** either document the per-encoder scale shapes explicitly, or unify (e.g., Circular could take `(0, period)` as its scale to match Linear/Log's two-bound form — the low bound would just always be 0). Convention to be settled; outside the core claim.

**4. Wrap-around semantics more complex than linear.**

Reader must understand that `Circular(low, high, 23.5, (24,))` wraps — values near the period boundary produce vectors similar to values near 0. This is the whole point, but readers new to circular encoding may be surprised. Not a reframing problem, a documentation concern.

## Comparison

| Form | Class (current) | Class (proposed) | Weight function |
|---|---|---|---|
| `Linear(...)` | CORE | STDLIB (058-008) | `(1 - t, t)`, `t ∈ [0,1]` |
| `Log(...)` | CORE | STDLIB (058-017) | `(1 - log_t, log_t)`, `log_t ∈ [0,1]` |
| `Circular(...)` | CORE | STDLIB (this) | `(cos θ, sin θ)`, `θ = 2π·value/period` |

Circular is the only one with potentially negative weights — the signature test for Blend Option B.

## Algebraic Question

Does Circular compose with the existing algebra?

Yes. Output is a vector in the ternary output space `{-1, 0, +1}^d` (Blend with negative weights still produces a ternary vector via threshold; see FOUNDATION's "Output Space" section). All downstream operations work.

Is it a distinct source category?

No. Once Blend Option B is core, Circular is a Blend specialization. Stdlib.

## Simplicity Question

Is this simple or easy?

Simple. The trigonometric weighting is two function calls in the stdlib definition. The algebraic machinery stays in Blend.

Is anything complected?

Removes complection. The current variant mixes "scalar-to-vector" with "circular normalization." Reframing separates them.

Could existing forms express it?

Yes, once Blend Option B is core.

## Implementation Scope

**holon-rs changes** — remove the variant:

```rust
pub enum HolonAST {
    // remove: Circular(Atom, Atom, f64, Scale),
}
```

Delete the Circular encoder match arm (~15-20 lines). Macro expansion is handled by 058-031-defmacro's parse-time pass; no per-macro Rust is needed here.

**wat stdlib addition** — `wat/std/scalars.wat`:

```scheme
(:wat/core/defmacro (:wat/std/Circular (low :AST) (high :AST) (value :AST) (scale :AST) -> :AST)
  `(:wat/core/let* ((period (:wat/core/first ,scale))
          (angle (:wat/core/* 2 pi (:wat/core// ,value period))))
     (:wat/algebra/Blend (:wat/algebra/Thermometer ,low dim) (:wat/algebra/Thermometer ,high dim) (cos angle) (sin angle))))
```

Registered at parse time (per 058-031-defmacro): every `(Circular ...)` invocation is rewritten to the canonical `let* + Blend-over-Thermometers` form before hashing.

## Questions for Designers

1. **Are `sin`, `cos`, `pi` available in the wat stdlib?** Required for the expansion. If not, add as prerequisites.

2. **Scale argument shape.** Circular's `scale = (period,)` differs from Linear/Log's `scale = (min, max)`. Unify (e.g., `(0, period)` for Circular) or document per-encoder? Consistency may help readability.

3. **Blend Option B verification.** Circular is the test case for Option B's independent weights. Any Blend implementation must correctly handle negative weights. Confirm this is in the Blend acceptance criteria.

4. **Angle conventions.** This proposal uses `angle = 2π · value / period` — standard radians, counterclockwise from 0. Alternative conventions (degrees, clockwise, phase offset) are possible. Document the choice.

5. **Starting angle offset.** Some applications want `value = 0` to correspond to a specific position (e.g., "noon" maps to angle 0, "midnight" maps to π). This is an offset parameter. Should Circular's stdlib form support it, or should users write a variant?

6. **Same consistency concerns as 058-008 and 058-017.** AST preservation, cache keys, encoder audit — resolve uniformly across all three scalar-encoder reframings.

7. **New circular encoders.** "Half-circle" (values in `[0, π]`), "cyclic-Gaussian" (peaked at some phase), "wavelet" — all potential stdlib extensions once Circular is reframed. Not in this proposal's scope but opens the door.
