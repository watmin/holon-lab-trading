# 058-017: `Log` — Reframe as Stdlib over Blend

**Scope:** algebra
**Class:** STDLIB — **ACCEPTED**
**Parent:** 058-ast-algebra-surface
**Foundation:** ../FOUNDATION.md

---

## ACCEPTED — 2026-04-18

`Log` is stdlib. Closed on overwhelming production evidence and the Blend acceptance.

**Production use:** Log is load-bearing across the trading lab's vocab. At least 15 concrete indicator encodings:

- `vocab/market/oscillators.rs` — `roc-1`, `roc-3`, `roc-6`, `roc-12` (rate-of-change indicators across four windows)
- `vocab/market/momentum.rs` — `atr-ratio`
- `vocab/market/keltner.rs` — `bb-width` (Bollinger Band width)
- `vocab/market/price_action.rs` — `range-ratio`, `consecutive-up`, `consecutive-down`
- `vocab/exit/regime.rs` — `variance-ratio`
- `vocab/exit/trade_atoms.rs` — `exit-excursion`, `exit-age`, `exit-peak-age`, `exit-trail-distance`, `exit-stop-distance`, `exit-r-multiple`, `phases-since-entry`, `phases-survived`

Every ratio, rate, and multiplicative quantity in the vocab passes through Log. It is how the trading lab gets scale-invariant encoding for "how much X per Y."

**Macro expansion** (after Blend acceptance — 058-002):

```scheme
(:wat::core::defmacro (:wat::std::Log (value :AST) (min :AST) (max :AST) -> :AST)
  `(:wat::algebra::Thermometer (:wat::std::math::ln ,value)
                              (:wat::std::math::ln ,min)
                              (:wat::std::math::ln ,max)))
```

Log-transform the inputs, then the standard Thermometer gradient. Natural log (`:wat::std::math::ln`) is the conventional base; any base produces the same result (base cancels in the ratio).

**Questions for Designers — all resolved:**
- Q1 (`log` in wat stdlib): RESOLVED — `:wat::std::math::ln` (single Rust method `f64::ln`); see FOUNDATION-CHANGELOG 2026-04-18 core/stdlib division entry.
- Q2 (numerical preconditions): document as user responsibility — `value, min, max` must all be positive for `ln` to be defined. Trading-lab callers pass `.max(0.0001)` guards where inputs can touch zero (see `trade_atoms.rs`).
- Q3 (log base): natural log is conventional; any base cancels in the ratio.
- Q4 (consistency concerns with Linear/Circular): RESOLVED via 058-031 defmacro — macros expand at parse time; hash is on the expanded AST.
- Q5 (LogLinear / Exponential family): deferred; propose with concrete application evidence when a real need emerges.

**Companion proposals:** 058-008 Linear REJECTED (identical to Thermometer under the 3-arity signature). 058-018 Circular — also ACCEPTED as stdlib (see its PROPOSAL.md).

---

## Historical content (preserved as audit record)

## Reclassification Claim

The current `HolonAST` enum has a `Log(low_atom, high_atom, value, scale)` variant. FOUNDATION's audit lists it as CORE. Under the stdlib criterion (058-002-blend's Blend primitive, plus Thermometer as core), `Log` is a BLENDING of two endpoint anchor Thermometers with weights derived from the value's LOG-normalized position.

Log is structurally identical to Linear (058-008). The only difference is the normalization function — Log uses log-space interpolation, Linear uses linear-space. The algebraic operation is the same: weighted blend of two anchors.

With Blend as a pivotal core form (058-002), `Log` becomes a stdlib macro (per 058-031-defmacro). This proposal reclassifies it accordingly.

## The Reframing

### Current semantics

`Log(value, min, max)` produces a vector that places `value` along a range `[min, max]` using LOG-SPACE interpolation. A value at the geometric midpoint of `[min, max]` appears at the linear midpoint of the encoding — useful for encoding ratios, rates, byte counts, request frequencies.

### Stdlib definition

```scheme
(:wat::core::defmacro (:wat::std::Log (value :AST) (min :AST) (max :AST) -> :AST)
  `(:wat::algebra::Thermometer (log ,value) (log ,min) (log ,max)))
```

Log-transform the value and the bounds, then encode linearly with Thermometer. Because Thermometer's encoding is intrinsically linear in its inputs, log-transforming the inputs gives log-scale output — the geometric midpoint of `[min, max]` lands at the linear midpoint of the Thermometer gradient.

Expansion happens at parse time (per 058-031-defmacro), so `hash(AST)` sees only the canonical `(Thermometer (log value) (log min) (log max))` form — no `Log` call node survives into the hashed AST.

### Why Log earns its stdlib place (under the blueprint test)

Log demonstrates a **distinct pattern** — log-transforming inputs before Thermometer to get log-scale encoding. A user who wants to encode a ratio, rate, or count spanning orders of magnitude can't derive this from Thermometer alone without thinking about the transformation. The macro is one line, but the pattern teaches: "want log-scale? log-transform first." That's a demonstration worth shipping.

Contrast with Linear (058-008 REJECTED) — which under the new Thermometer signature is identical to Thermometer itself. Linear had nothing distinct to teach; Log does.

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
pub enum HolonAST {
    // remove: Log(Atom, Atom, f64, Scale),
}
```

Delete the Log encoder match arm (~15-20 lines). Macro expansion is handled by 058-031-defmacro's parse-time pass; no per-macro Rust is needed here.

**wat stdlib addition** — `wat/std/scalars.wat`:

```scheme
(:wat::core::defmacro (:wat::std::Log (low :AST) (high :AST) (value :AST) (scale :AST) -> :AST)
  `(:wat::core::let* ((min (:wat::core::first ,scale))
          (max (:wat::core::second ,scale))
          (t (:wat::core::/ (:wat::core::- (log ,value) (log min))
                (:wat::core::- (log max) (log min)))))
     (:wat::algebra::Blend (:wat::algebra::Thermometer ,low dim) (:wat::algebra::Thermometer ,high dim) (:wat::core::- 1 t) t)))
```

Registered at parse time (per 058-031-defmacro): every `(Log ...)` invocation is rewritten to the canonical `let* + Blend-over-Thermometers` form before hashing.

## Questions for Designers

1. **Is `log` in the wat stdlib?** The expansion depends on natural log (or log with a base, though the base cancels out of the ratio). If not available, this proposal depends on adding log primitives to wat.

2. **Numerical preconditions.** `min, max, value` must all be positive (log requires positive arguments). Should the stdlib Log enforce this, or treat violations as undefined?

3. **Log base choice.** Natural log is conventional; base-10 or base-2 produce the same result (the base cancels in the ratio). Does holon-rs have a preference?

4. **Same consistency concerns as 058-008.** AST preservation, cache keys, encoder audit — resolve uniformly across all three scalar-encoder reframings.

5. **Alternatives: `LogLinear`, `Exponential`?** Log is one log-scale encoder. Others (log-sigmoid, stretched-log, signed-log for values crossing zero) are plausible stdlib additions. Linear's reframing opens the door; does Log have a family of companions?
