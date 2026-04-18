# 058-008: `Linear` — Reframe as Stdlib over Blend

> **STATUS: REJECTED from project stdlib** (2026-04-18)
>
> This proposal was written when `Thermometer` took `(atom, dim)` — a seeded gradient primitive. Under that old signature, `Linear(value, min, max, scale)` required a wrapper macro that computed weighted positions and blended two Thermometer-seeded endpoints. The wrapper earned its place as the bridge.
>
> After the 2026-04-18 Thermometer signature sweep, `Thermometer` takes `(value, min, max)` directly and produces the linear gradient itself: proportion of `+1` dimensions = `(value - min) / (max - min)`. `Linear(v, min, max)` becomes identical to `(Thermometer v min max)`. Under the stdlib-as-blueprint test, Linear demonstrates no new pattern — it's a rename.
>
> Use `Thermometer` directly for linear scalar encoding. `Log` (058-017) and `Circular` (058-018) stay because they demonstrate **distinct** transformations (log-scale, cyclic) — those aren't rename-only.
>
> Userland may define the alias if readability matters to their vocab:
>
> ```scheme
> (defmacro (:my/vocab/Linear (v :AST) (min :AST) (max :AST) -> :AST)
>   `(Thermometer ,v ,min ,max))
> ```
>
> This proposal is kept in the record as an honest trace of the design process.

**Scope:** algebra
**Class:** REJECTED (was STDLIB under old Thermometer signature; identical to Thermometer under new signature)
**Parent:** 058-ast-algebra-surface
**Foundation:** ../FOUNDATION.md
**Depends on:** 058-002-blend, 058-023-thermometer
**Companion proposals:** 058-017-log, 058-018-circular

## Reclassification Claim

The current `HolonAST` enum has a `Linear(low_atom, high_atom, value, scale)` variant. FOUNDATION's audit lists it as CORE. Under the stdlib criterion (058-002-blend's Blend primitive, plus Thermometer as core), `Linear` is a BLENDING of two endpoint anchor Thermometers with weights derived from the scalar value's linear-normalized position.

It is not a primitive algebraic operation. It is a scalar-to-vector conversion that expresses a position along a one-dimensional range by blending two endpoint anchors. That is exactly the shape of a Blend call with scalar-derived weights.

With Blend as a pivotal core form (058-002), `Linear` becomes a stdlib macro (per 058-031-defmacro). This proposal reclassifies it accordingly.

Parallel proposals 058-017-log and 058-018-circular apply the same reframing to the Log and Circular scalar encoders, which are structurally identical except for the weight-computing function.

## The Reframing

### Current semantics

`Linear(low_atom, high_atom, value, scale)` produces a vector that is `low_anchor` when `value == min` and `high_anchor` when `value == max`, linearly interpolating in between.

### Stdlib definition

```scheme
(defmacro (Linear (low-atom :AST) (high-atom :AST) (value :AST) (scale :AST) -> :AST)
  `(let* ((min (first ,scale))
          (max (second ,scale))
          (t (/ (- ,value min) (- max min)))                    ; normalize to [0,1]
          (w-low (- 1 t))
          (w-high t))
     (Blend (Thermometer ,low-atom dim)
            (Thermometer ,high-atom dim)
            w-low
            w-high)))
```

`t` is the linear-normalized position of `value` in the range `[min, max]`. `w-low` weights the low anchor; `w-high` weights the high anchor. Their sum is always 1 (a partition-of-unity linear interpolation). Expansion happens at parse time (per 058-031-defmacro), so `hash(AST)` sees only the canonical `(let* ... (Blend (Thermometer ...) (Thermometer ...) w-low w-high))` form — no `Linear` call node survives into the hashed AST.

## Why Stdlib Earns the Name

**1. The operation is a Blend with a specific weight-computing function.**

The algebraic skeleton is:

```
Blend(Thermometer(low), Thermometer(high), w_low(value), w_high(value))
```

Linear uses `w_low(value) = 1 - t` and `w_high(value) = t` for `t = (value - min) / (max - min)`. The ALGEBRAIC operation is the weighted sum. The weight functions are scalar computations that belong in stdlib, not the algebra.

**2. The stdlib form makes the weight computation explicit.**

As a CORE variant, the weight computation is hidden inside the Rust encoder dispatch. As a stdlib macro, it is visible in the wat source — users can read, understand, and extend.

**3. New linear-style encoders become trivial stdlib additions.**

Clipped-linear (saturates outside `[min, max]`), piecewise-linear (multiple breakpoints), offset-linear, etc. — all become wat macros rather than HolonAST variants. The algebra stays closed; extension happens in the library.

## Arguments Against

**1. Loss of dispatch efficiency.**

Current implementation pattern-matches on the `Linear` variant and dispatches to a specialized encoder. Stdlib expansion requires Blend evaluation with runtime-computed weights, which adds one indirection.

**Mitigation:** the overhead is a single match arm vs. the expanded `let* + Blend` form. The vector-level work (Thermometer encoding + Blend) dominates. Dispatch cost is noise.

**2. Cache key shape changes — resolved by parse-time expansion.**

Currently `Linear(low, high, value, scale)` is one AST node. Under `defmacro` (058-031), the `Linear` call is rewritten at parse time to the canonical `(let* ... (Blend (Thermometer ...) (Thermometer ...) w-low w-high))` form BEFORE any hashing or caching occurs. One cache entry; one hash; no alias-collision with other Blend-based encoders that share the expanded shape.

**3. Loss of semantic name in AST walks.**

Because expansion is parse-time, the `Linear` label is consumed before the hashed AST exists. Tooling that walks the hashed AST sees the canonical `let* + Blend` form, not the source-level `Linear` name.

**Mitigation:** source-level tools (formatters, IDE displays, error messages) can preserve the pre-expansion form via source maps. This is a standard Lisp-macro tooling concern; the trade-off is accepted for hash canonicalization. Consistent with the treatment of Log/Circular/Concurrent/Sequential macro reframings.

**4. Dependency on Blend passing.**

If 058-002-blend is rejected, this reframing is void and `Linear` stays core. The designers must resolve Blend first.

## Comparison

| Form | Class (current) | Class (proposed) | Expansion |
|---|---|---|---|
| `Linear(low, high, v, scale)` | CORE | STDLIB (this) | `Blend(Therm(low), Therm(high), 1-t, t)` |
| `Log(low, high, v, scale)` | CORE | STDLIB (058-017) | `Blend(Therm(low), Therm(high), 1-log_t, log_t)` |
| `Circular(low, high, v, scale)` | CORE | STDLIB (058-018) | `Blend(Therm(low), Therm(high), cos θ, sin θ)` |
| `Thermometer(atom, dim)` | CORE | CORE (unchanged) | primitive |
| `Blend(a, b, w1, w2)` | CORE (pending 058-002) | CORE (pending 058-002) | primitive |

Three separate reframings, identical structural argument, different weight functions.

## Algebraic Question

Does Linear compose with the existing algebra?

Yes. Output is a vector in the ternary output space `{-1, 0, +1}^d` (Blend's threshold of a scalar-weighted sum of Thermometer outputs; see FOUNDATION's "Output Space" section). Same dimensional space. All downstream operations work.

Is it a distinct source category?

No. Once Blend is core, Linear is a Blend specialization with a particular weight-computing function. Stdlib.

## Simplicity Question

Is this simple or easy?

Simpler than the current state. One less CORE variant. The operation's structure (Blend of two anchor Thermometers with linear weights) is made explicit.

Is anything complected?

Removes a small complection. The current variant mixes "I am a scalar-to-vector operation" with "I use linear interpolation specifically." Reframing separates the two — the scalar-to-vector machinery is Blend; the linear weights are a scalar function in stdlib.

Could existing forms express it?

Yes, once Blend is core. That is the whole claim.

## Implementation Scope

**holon-rs changes** — remove the variant:

```rust
pub enum HolonAST {
    // remove: Linear(Atom, Atom, f64, Scale),
    // keep:   Thermometer(Atom, usize),
    // add (per 058-002): Blend(Arc<HolonAST>, Arc<HolonAST>, f64, f64),
}
```

Delete the Linear encoder match arm (~15-20 lines including tests). Macro expansion is handled by 058-031-defmacro's parse-time pass; no per-macro Rust is needed here.

**wat stdlib addition** — `wat/std/scalars.wat`:

```scheme
(defmacro (Linear (low :AST) (high :AST) (value :AST) (scale :AST) -> :AST)
  `(let* ((min (first ,scale))
          (max (second ,scale))
          (t (/ (- ,value min) (- max min))))
     (Blend (Thermometer ,low dim) (Thermometer ,high dim) (- 1 t) t)))
```

Registered at parse time (per 058-031-defmacro): every `(Linear ...)` invocation is rewritten to the canonical `let* + Blend-over-Thermometers` form before hashing.

## Questions for Designers

1. **Is Thermometer itself core?** This reframing assumes Thermometer stays core. 058-023-thermometer treats Thermometer as the primitive. Confirm.

2. **Should stdlib forms be preserved in AST or eagerly expanded?** Preserving keeps the semantic name in AST walks. Eager expansion collapses cache keys to canonical Blend. Either works; consistency across Linear/Log/Circular is the key.

3. **Are there hidden differences between the current variant implementation and the reframing?** Float-to-integer rounding, clipping, specialized arithmetic — audit before committing to confirm the reframing is byte-for-byte equivalent to the current Linear encoder.

4. **Dependency on 058-002-blend.** If Blend is rejected, Linear stays core. Should resolution be explicitly deferred until Blend resolves?

5. **Scale argument shape.** `scale` here is a list `(min max)`. Is this the conventional shape across Linear/Log/Circular? Log also uses min/max; Circular uses a single period. Inconsistent shapes may complicate stdlib code. Confirm per-encoder conventions.
