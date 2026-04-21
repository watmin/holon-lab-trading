# 058-018: `Circular` — Reframe as Stdlib over Blend

**Scope:** algebra
**Class:** STDLIB — **ACCEPTED + INSCRIPTION 2026-04-21**
**Parent:** 058-ast-algebra-surface
**Foundation:** ../FOUNDATION.md

---

## INSCRIPTION — 2026-04-21 — Shipped

Landed in wat-rs as a defmacro over Blend with two reserved basis atoms (`cos-basis`, `sin-basis`) and `(cos θ, sin θ)` weights.

- **Source:** [`wat-rs/wat/std/Circular.wat`](https://github.com/watmin/wat-rs/blob/main/wat/std/Circular.wat)
- **Tests:** [`wat-rs/wat-tests/std/Circular.wat`](https://github.com/watmin/wat-rs/blob/main/wat-tests/std/Circular.wat) — two deftests proving adjacent hours are near (Circular 0 24 vs Circular 23 24) and antipodal hours are far (Circular 0 24 vs Circular 12 24), both measured against the noise-floor discriminator.
- **Shape:** `(:wat::std::Circular (value :AST<f64>) (period :AST<f64>) -> :AST<holon::HolonAST>)` → a let* that computes θ then blends `(Atom :cos-basis)` and `(Atom :sin-basis)` with `(cos θ, sin θ)` weights.

### Divergences from the original spec

Three small surface adjustments from the proposal's body sketch, all driven by the 2026-04-19 typed-arith split:

1. **Binary typed arithmetic.** The proposal wrote `(* 2 pi (/ v p))` (three-arg multiply). wat-rs arith is binary and typed post-2026-04-19: users commit to int or float at the call site. The expansion uses `(:wat::core::f64::*)` and `(:wat::core::f64::/)` pairwise.
2. **`pi` as nullary call.** The proposal referenced `pi` bare. It's a nullary primitive — called as `(:wat::std::math::pi)`.
3. **Explicit `:f64` in let\* bindings.** Binding types aren't inferred for stdlib forms; each let\* binding carries its declared type.

Same math, enforcement-correct wat. Documented inline in the stdlib file as "Deviations from the proposal's body shape" for future readers.

---

## ACCEPTED — 2026-04-18

`Circular` is stdlib. Closed on concrete production use and the Blend acceptance (Option B, independent weights — which is what enables Circular's `(cos θ, sin θ)` weighting).

**Production use:** Circular encodes every cyclic time component in the trading lab's `vocab/shared/time.rs`. Five leaf binds plus three pairwise compositions per candle:

| Component | Period | Usage |
|---|---|---|
| `minute` | 60 | leaf bind |
| `hour` | 24 | leaf bind, composition `minute × hour` |
| `day-of-week` | 7 | leaf bind, composition `hour × day-of-week` |
| `day-of-month` | 31 | leaf bind |
| `month-of-year` | 12 | leaf bind, composition `day-of-week × month` |

`time_facts(candle)` produces 8 time-related facts per candle; every broker thought carries them. Without Circular, hour 23 and hour 0 would look maximally distant; with Circular, they are adjacent points on the unit circle. Load-bearing for temporal pattern recognition.

**Macro expansion** (after Blend acceptance with Option B independent weights):

```scheme
(:wat::core::defmacro (:wat::std::Circular (value :AST) (period :AST) -> :AST)
  `(:wat::core::let ((theta (:wat::core::* 2 :wat::std::math::pi
                                       (:wat::core::/ ,value ,period))))
     (:wat::algebra::Blend (:wat::algebra::Atom :wat::std::circular-cos-basis)
                          (:wat::algebra::Atom :wat::std::circular-sin-basis)
                          (:wat::std::math::cos theta)
                          (:wat::std::math::sin theta))))
```

Two reserved basis atoms (`:wat::std::circular-cos-basis`, `:wat::std::circular-sin-basis`) plus `cos(θ)` and `sin(θ)` weights produce the 2D cyclic encoding. This is the proof that Blend needs Option B — `cos(π/4) + sin(π/4) ≈ 1.414 ≠ 1`, so Option A's convex constraint cannot express it.

**Questions for Designers — all resolved:**
- Q1 (`sin`/`cos`/`pi` in stdlib): RESOLVED — `:wat::std::math::sin`, `:wat::std::math::cos`, `:wat::std::math::pi` are stdlib (single Rust methods / constant).
- Q2 (scale argument shape: period vs `(min, max)`): keep `period` single argument — cyclic semantics wrap naturally over `[0, period)`; the `(min, max)` shape only makes sense for monotone-value encoders like Linear/Log. Per-encoder shape is honest.
- Q3 (Blend Option B verification): RESOLVED — 058-002 ACCEPTED as Option B with negative weights, which is exactly what Circular needs.
- Q4 (angle conventions): standard radians, counterclockwise from 0, `θ = 2π · value / period`.
- Q5 (starting angle offset): userland — users who want `θ = 2π · (value - offset) / period` wrap the macro themselves.
- Q6 (consistency with Linear/Log): RESOLVED via 058-031 defmacro.
- Q7 (new circular encoders — half-circle, cyclic-Gaussian, wavelet): deferred until real application demand.

**Companion proposals:** 058-008 Linear REJECTED (identical to Thermometer). 058-017 Log ACCEPTED as stdlib (see its PROPOSAL.md).

---

## Historical content (preserved as audit record)

## Reclassification Claim

The current `HolonAST` enum has a `Circular(low_atom, high_atom, value, scale)` variant. FOUNDATION's audit lists it as CORE. Under the stdlib criterion (058-002-blend's Blend primitive, plus Thermometer as core), `Circular` is a BLENDING of two endpoint anchor Thermometers with weights derived from sin/cos of a normalized angle.

Circular is structurally identical to Linear (058-008) and Log (058-017): `Blend(Thermometer(low), Thermometer(high), w_low, w_high)` where the weights are scalar functions of the value. The only difference is the weight function — Circular uses trigonometric functions to capture WRAP-AROUND semantics.

With Blend as a pivotal core form (058-002) — and specifically Option B (two INDEPENDENT weights rather than a constrained weight pair) — `Circular` becomes a stdlib macro (per 058-031-defmacro). This proposal reclassifies it accordingly.

## The Reframing

### Current semantics

`Circular(value, period)` encodes values on a circular scale (time-of-day, angles, phase). A value and its `value + period` produce the same vector. The key property: positions equidistant along the circle blend equally.

### Stdlib definition

```scheme
(:wat::core::defmacro (:wat::std::Circular (value :AST) (period :AST) -> :AST)
  `(:wat::core::let* ((angle   (:wat::core::* 2 pi (:wat::core::/ ,value ,period)))
          (w-cos   (cos angle))                  ;; can be negative
          (w-sin   (sin angle)))                 ;; can be negative
     (:wat::algebra::Blend (:wat::algebra::Atom :wat::std::circular-cos-basis)
            (:wat::algebra::Atom :wat::std::circular-sin-basis)
            w-cos
            w-sin)))
```

`angle` maps `value` to a position on the unit circle. `cos angle` and `sin angle` are the weights — they span a full period as `value` cycles. The two Atoms `:wat::std::circular-cos-basis` and `:wat::std::circular-sin-basis` are fixed reference vectors (seeded by the VectorManager at startup) that span the 2D basis of the circle; Blend's two independent weights let Circular project onto any point on that basis.

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
(:wat::core::defmacro (:wat::std::Circular (low :AST) (high :AST) (value :AST) (scale :AST) -> :AST)
  `(:wat::core::let* ((period (:wat::core::first ,scale))
          (angle (:wat::core::* 2 pi (:wat::core::/ ,value period))))
     (:wat::algebra::Blend (:wat::algebra::Thermometer ,low dim) (:wat::algebra::Thermometer ,high dim) (cos angle) (sin angle))))
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
