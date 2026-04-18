# 058-017: `Log` — Reframe as Stdlib over Blend

**Scope:** algebra
**Class:** STDLIB (reclassification from current CORE variant)
**Parent:** 058-ast-algebra-surface
**Foundation:** ../FOUNDATION.md
**Depends on:** 058-002-blend (pivotal — if Blend rejected, Log stays core)
**Companion proposals:** 058-008-linear, 058-018-circular

## Reclassification Claim

The current `ThoughtAST` enum has a `Log(low_atom, high_atom, value, scale)` variant. FOUNDATION's audit lists it as CORE. Under the stdlib criterion (058-002-blend's Blend primitive, plus Thermometer as core), `Log` is a BLENDING of two endpoint anchor Thermometers with weights derived from the value's LOG-normalized position.

Log is structurally identical to Linear (058-008). The only difference is the normalization function — Log uses log-space interpolation, Linear uses linear-space. The algebraic operation is the same: weighted blend of two anchors.

With Blend as a pivotal core form (058-002), `Log` becomes a stdlib macro (per 058-031-defmacro). This proposal reclassifies it accordingly.

## The Reframing

### Current semantics

`Log(low_atom, high_atom, value, scale)` produces a vector that places `value` along a range `[min, max]` using LOG-SPACE interpolation. A value at the geometric midpoint of `[min, max]` gets equal anchor weights — useful for encoding ratios, rates, byte counts, request frequencies.

### Stdlib definition

```scheme
(defmacro Log (low-atom high-atom value scale)
  `(let* ((min (first ,scale))
          (max (second ,scale))
          (t (/ (- (log ,value) (log min))
                (- (log max) (log min))))                      ; log-normalize to [0,1]
          (w-low (- 1 t))
          (w-high t))
     (Blend (Thermometer ,low-atom dim)
            (Thermometer ,high-atom dim)
            w-low
            w-high)))
```

Identical skeleton to Linear. The only difference is `t`'s computation: Linear uses `(value - min) / (max - min)`, Log uses `(log value - log min) / (log max - log min)`. Everything downstream is the same. Expansion happens at parse time (per 058-031-defmacro), so `hash(AST)` sees only the canonical `(let* ... (Blend (Thermometer ...) (Thermometer ...) w-low w-high))` form — no `Log` call node survives into the hashed AST.

## Why Stdlib Earns the Name

**1. The operation is a Blend with a log-space weight function.**

```
Blend(Thermometer(low), Thermometer(high), 1-log_t, log_t)
```

`log_t` is the normalized log-position. The ALGEBRAIC operation is Blend. The weight-computing function is scalar arithmetic in stdlib.

**2. Log-scale encoding is common in domains but not primitive.**

Request rates, byte counts, amplitudes, prices — all benefit from log-scale encoding. But the need for log-scale is a DOMAIN DECISION about the normalization; the algebraic operation remains the weighted blend. Stdlib is the right layer for the domain choice.

**3. Removes a CORE variant without losing expressivity.**

Every current use of `Log(...)` continues to work via the stdlib expansion. The algebra shrinks; the expressive power is preserved.

## Arguments Against

**1. `log` is a stdlib math primitive dependency.**

The stdlib definition uses `(log value)`. The wat stdlib must provide natural logarithm (or the expansion must compute it via whatever math primitives wat exposes).

**Mitigation:** `log` is a standard math function. If wat's stdlib does not provide it yet, add it as a prerequisite. Not a blocker.

**2. Numerical edge cases.**

`log(0)` is `-∞`. `log(negative)` is undefined. If `min = 0` or `value ≤ 0`, the expansion produces infinity/NaN.

The current CORE variant likely handles these cases with explicit checks. The stdlib version must too — either the Log stdlib guards the inputs, or callers are responsible.

**Mitigation:** document preconditions (`min > 0`, `max > 0`, `value > 0`). Either add guards in the stdlib definition or treat violations as undefined behavior (matching the current variant's behavior, which should be audited).

**3. Same generic arguments as 058-008-linear (dispatch efficiency, cache, AST visibility).**

See 058-008 for the detailed discussion. Same resolutions apply: dispatch cost is noise, cache can preserve the stdlib form, AST walks see the named form if preserved.

**4. Dependency on Blend passing.**

If 058-002-blend is rejected, Log stays core.

## Comparison

| Form | Class (current) | Class (proposed) | `t` formula |
|---|---|---|---|
| `Linear(...)` | CORE | STDLIB (058-008) | `(value - min) / (max - min)` |
| `Log(...)` | CORE | STDLIB (this) | `(log value - log min) / (log max - log min)` |
| `Circular(...)` | CORE | STDLIB (058-018) | `2π · value / period` (angle, then cos/sin) |

All three share the Blend-of-two-Thermometers skeleton. Only the weight computation differs.

## Algebraic Question

Does Log compose with the existing algebra?

Yes. Output is a vector in the ternary output space `{-1, 0, +1}^d` (see FOUNDATION's "Output Space" section). All downstream operations work. Same as Linear.

Is it a distinct source category?

No. Log is a Blend specialization with a log-space weight function. Stdlib.

## Simplicity Question

Is this simple or easy?

Simple. One CORE variant becomes one stdlib macro. The log-scale normalization is pure arithmetic, clearly separated from the vector operation.

Is anything complected?

Removes complection. The current variant mixes "scalar-to-vector operation" with "log-scale normalization." Reframing separates them.

Could existing forms express it?

Yes, once Blend is core.

## Implementation Scope

**holon-rs changes** — remove the variant:

```rust
pub enum ThoughtAST {
    // remove: Log(Atom, Atom, f64, Scale),
}
```

Delete the Log encoder match arm (~15-20 lines). Macro expansion is handled by 058-031-defmacro's parse-time pass; no per-macro Rust is needed here.

**wat stdlib addition** — `wat/std/scalars.wat`:

```scheme
(defmacro Log (low high value scale)
  `(let* ((min (first ,scale))
          (max (second ,scale))
          (t (/ (- (log ,value) (log min))
                (- (log max) (log min)))))
     (Blend (Thermometer ,low dim) (Thermometer ,high dim) (- 1 t) t)))
```

Registered at parse time (per 058-031-defmacro): every `(Log ...)` invocation is rewritten to the canonical `let* + Blend-over-Thermometers` form before hashing.

## Questions for Designers

1. **Is `log` in the wat stdlib?** The expansion depends on natural log (or log with a base, though the base cancels out of the ratio). If not available, this proposal depends on adding log primitives to wat.

2. **Numerical preconditions.** `min, max, value` must all be positive (log requires positive arguments). Should the stdlib Log enforce this, or treat violations as undefined?

3. **Log base choice.** Natural log is conventional; base-10 or base-2 produce the same result (the base cancels in the ratio). Does holon-rs have a preference?

4. **Same consistency concerns as 058-008.** AST preservation, cache keys, encoder audit — resolve uniformly across all three scalar-encoder reframings.

5. **Alternatives: `LogLinear`, `Exponential`?** Log is one log-scale encoder. Others (log-sigmoid, stretched-log, signed-log for values crossing zero) are plausible stdlib additions. Linear's reframing opens the door; does Log have a family of companions?
