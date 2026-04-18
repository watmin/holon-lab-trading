# 058-008: `Linear`, `Log`, `Circular` — Reframe as Stdlib over Blend

**Scope:** algebra
**Class:** STDLIB (reclassification from current CORE)
**Parent:** 058-ast-algebra-surface
**Foundation:** ../FOUNDATION.md
**Depends on:** 058-002-blend (pivotal — if Blend rejected, these remain core)

## Reclassification Claim

The current `ThoughtAST` enum has three scalar encoder variants — `Linear`, `Log`, `Circular` — that FOUNDATION's audit lists as CORE. Under the stdlib criterion (058-002-blend's Blend primitive, plus Thermometer as core), each of these is a BLENDING of two anchor Thermometers with weights derived from the scalar value.

They are not primitive algebraic operations. They are SCALAR-TO-VECTOR CONVERSIONS that express a position along a one-dimensional range by blending two endpoint anchors. That is exactly the shape of a Blend call with scalar-derived weights.

With Blend as a pivotal core form (058-002), `Linear`, `Log`, and `Circular` become stdlib functions. This proposal reclassifies them accordingly.

## The Reframings

### `Linear`

Current AST variant: `Linear(low_atom, high_atom, value, scale)`.
Semantics: produce a vector that is `low_anchor` when `value == min` and `high_anchor` when `value == max`, linearly interpolating in between.

```scheme
(define (Linear low-atom high-atom value scale)
  (let* ((min (first scale))
         (max (second scale))
         (t (/ (- value min) (- max min)))                     ; normalize to [0,1]
         (w-low (- 1 t))
         (w-high t))
    (Blend (Thermometer low-atom dim)
           (Thermometer high-atom dim)
           w-low
           w-high)))
```

`t` is the normalized position in the range. `w-low` weights the low anchor; `w-high` weights the high anchor. Their sum is always 1.

**Note on Thermometer:** This proposal assumes Thermometer is a CORE form that produces a gradient vector for an anchor atom. See 058's question list — if Thermometer is itself a stdlib composition (over something more primitive), this reframing applies transitively.

### `Log`

Current AST variant: `Log(low_atom, high_atom, value, scale)`.
Semantics: same endpoints, but the blending is in log-space — a value at the geometric midpoint of `[min, max]` gets equal anchor weights.

```scheme
(define (Log low-atom high-atom value scale)
  (let* ((min (first scale))
         (max (second scale))
         (t (/ (- (log value) (log min))
               (- (log max) (log min))))                       ; log-normalize to [0,1]
         (w-low (- 1 t))
         (w-high t))
    (Blend (Thermometer low-atom dim)
           (Thermometer high-atom dim)
           w-low
           w-high)))
```

Identical structure to `Linear`, only the normalization is log-transformed. The two share a skeleton; the scalar function for `t` is the only difference.

### `Circular`

Current AST variant: `Circular(low_atom, high_atom, value, scale)`.
Semantics: wrap-around encoding (e.g., time-of-day where 23:00 is close to 01:00). Requires a circular interpolation — two weights, derived from sin/cos of the normalized angle.

```scheme
(define (Circular low-atom high-atom value scale)
  (let* ((period (first scale))
         (angle (* 2 pi (/ value period)))
         (w-low (cos angle))                                   ; circular weighting
         (w-high (sin angle)))
    (Blend (Thermometer low-atom dim)
           (Thermometer high-atom dim)
           w-low
           w-high)))
```

Weights can be negative (unlike Linear and Log). Blend's two-independent-weights signature (Option B from 058-002) handles this without modification.

## Why This Reframing Earns Stdlib Status

**1. The shape is identical across all three.**

Every scalar encoder has the structure:

```
Blend(Thermometer(low), Thermometer(high), weight_fn(value), companion_weight_fn(value))
```

Only the weight function varies. Linear uses `(1-t, t)`; Log uses `(1-log(t), log(t))`; Circular uses `(cos(θ), sin(θ))`. The ALGEBRAIC operation is the same — a weighted blend of two endpoint anchors.

Having three ENUM VARIANTS for what is algebraically one operation (with three different scalar functions) is complection. The variants smuggle the scalar function into the algebra when it belongs in the stdlib.

**2. It clarifies what Thermometer is.**

Thermometer remains CORE because the gradient vector it produces cannot be expressed as a composition of Bind/Bundle/Blend — it is the primitive that encodes "magnitude along a direction." With Thermometer as core and Blend as core, all scalar encoders become stdlib.

**3. New scalar encoders become stdlib additions, not language extensions.**

Sigmoid encoding, tanh encoding, piecewise-linear encoding, softmax-style weighting — all of these become wat functions in stdlib, not new ThoughtAST variants. The algebra is closed; extension happens in the library.

**4. Parameter explosion is avoided.**

Each current scalar-encoder variant takes four arguments (low, high, value, scale). If we added 5 more scalar encoders as CORE variants, the AST enum would grow by 20 fields. With stdlib reframing, each new encoder is a wat function over Blend + Thermometer. The AST enum stays minimal.

## Arguments Against

**1. Loss of dispatch efficiency.**

Current implementation: the Rust encoder pattern-matches on the AST variant and dispatches to specialized scalar-encoder functions. Stdlib forms require evaluating the Blend expression with runtime-computed weights, which is ONE evaluation step slower.

**Mitigation:** the overhead is a single match arm vs a stdlib function call. In practice, the encoder is O(d) dominated by the Blend evaluation anyway. The dispatch cost is noise.

**2. Cache key shape changes.**

Currently `Linear(low, high, value, scale)` is one AST node with a fixed shape — cache key is straightforward. The reframing makes `Linear(...)` a stdlib call expanded to `Blend(...)` with computed weights. The cache key on the expanded form may differ depending on whether computed weights are folded in.

**Mitigation:** the cache key should be on the stdlib form (before expansion), OR the stdlib form should fold to a canonical Blend at parse time. Either works; tooling decision outside FOUNDATION.

**3. Loss of semantic names in AST walks.**

When walking an AST to render it, log it, or explain it, `Linear(...)` communicates "this is a linear scalar encoding." After reframing, the AST walk sees `Blend(Thermometer(...), Thermometer(...), ...)` and must recognize the pattern.

**Mitigation:** if stdlib calls are PRESERVED in the AST (not eagerly expanded), the semantic name remains visible. Cache is on the stdlib form. Expansion happens only during vector computation. Best of both.

**4. This depends on Blend passing.**

If 058-002-blend is rejected, this reframing is void and all three variants remain core. The designers must resolve Blend first.

**Mitigation:** this is a dependency, not a blocker. Clearly noted. Resolution order: Blend → this.

## Comparison

| Form | Class (current) | Class (proposed) | Expansion |
|---|---|---|---|
| `Linear(low, high, v, scale)` | CORE | STDLIB | `Blend(Therm(low), Therm(high), 1-t, t)` |
| `Log(low, high, v, scale)` | CORE | STDLIB | `Blend(Therm(low), Therm(high), 1-log(t), log(t))` |
| `Circular(low, high, v, scale)` | CORE | STDLIB | `Blend(Therm(low), Therm(high), cos(θ), sin(θ))` |
| `Thermometer(atom, dim)` | CORE | CORE (unchanged) | primitive |
| `Blend(a, b, w1, w2)` | CORE (pending 058-002) | CORE (pending 058-002) | primitive |

Three variants collapse into stdlib; the two primitives remain.

## Algebraic Question

Does this reframing break anything in the algebra?

No. It makes the algebra SMALLER — fewer ThoughtAST variants — while preserving all expressivity. Every current scalar-encoded thought is still expressible, just via stdlib.

Is it a distinct source category?

Reversed: it COLLAPSES three source categories into one. Linear, Log, Circular are no longer primitive operations; they are specializations of Blend with particular weight-computing functions.

## Simplicity Question

Is this simple or easy?

Simpler than the current state. Three variants → one (Blend) + three stdlib functions. Algebra narrows; library grows. The stdlib extension is trivial — each encoder is <10 lines of wat.

Is anything complected?

Removes complection. Currently each scalar encoder mixes "I am a scalar-to-vector operation" with "I use THIS particular weighting scheme." Reframing separates the two — the scalar-to-vector machinery is Blend; the weighting is a scalar function in stdlib.

Could existing forms express it?

Yes — that is the whole claim. Once Blend is core, the three scalar encoders decompose into Blend-plus-scalar-function, and belong in stdlib.

## Implementation Scope

**holon-rs changes** — remove three variants from ThoughtAST:

```rust
pub enum ThoughtAST {
    // remove: Linear(Atom, Atom, f64, Scale),
    // remove: Log(Atom, Atom, f64, Scale),
    // remove: Circular(Atom, Atom, f64, Scale),
    // keep:   Thermometer(Atom, usize),
    // add (per 058-002): Blend(Arc<ThoughtAST>, Arc<ThoughtAST>, f64, f64),
    // ...
}
```

Delete their encoder match arms (~40 lines combined, likely more with tests).

**wat stdlib additions** — three functions (Linear, Log, Circular), each ~10-15 lines:

```scheme
;; wat/std/scalars.wat (or equivalent)

(define (Linear low high value scale)
  (let* ((min (first scale)) (max (second scale))
         (t (/ (- value min) (- max min))))
    (Blend (Thermometer low dim) (Thermometer high dim) (- 1 t) t)))

(define (Log low high value scale)
  (let* ((min (first scale)) (max (second scale))
         (t (/ (- (log value) (log min)) (- (log max) (log min)))))
    (Blend (Thermometer low dim) (Thermometer high dim) (- 1 t) t)))

(define (Circular low high value scale)
  (let* ((period (first scale)) (angle (* 2 pi (/ value period))))
    (Blend (Thermometer low dim) (Thermometer high dim) (cos angle) (sin angle))))
```

**Cache/encoder adjustments:**

- If stdlib forms are preserved in AST (not expanded at parse time), cache keys remain on the stdlib form — no disruption.
- If stdlib forms are expanded at parse time, cache keys normalize to the expanded Blend form. Either works.

## Questions for Designers

1. **Is Thermometer itself core?** This reframing assumes Thermometer stays core. FOUNDATION treats Thermometer as the primitive scalar-to-direction vector producer. If Thermometer ever becomes a stdlib composition (over something more primitive), this proposal applies transitively. For now, Thermometer stays core, and the three scalar encoders become stdlib.

2. **Should stdlib forms be preserved in AST or eagerly expanded?** Preserving keeps semantic names visible during AST walks (good for logging/debugging). Eagerly expanding collapses cache keys to canonical Blend forms (good for cache efficiency). Either works; this proposal is neutral on the choice.

3. **New scalar encoders — where do they live?** Once Linear/Log/Circular are stdlib, new scalar encoders (sigmoid, tanh, piecewise) land in `wat/std/scalars.wat` as further stdlib additions. No ThoughtAST changes for any of them. Confirmation that this is the intended extension path.

4. **Dependency on 058-002-blend.** If Blend is rejected, this reframing cannot proceed. Should resolution be explicitly deferred until Blend resolves? Or should a rejection of Blend automatically revert this to status quo (all three stay core)?

5. **Are there hidden differences between the CURRENT variant implementations and the reframing?** E.g., does the current `Linear` encoder use sophisticated float-to-integer rounding, clipping, or specialized arithmetic that the naive `Blend(Thermometer, Thermometer, 1-t, t)` doesn't reproduce? An implementation audit should confirm the reframing is byte-for-byte equivalent before committing.

6. **Impact on `Thermometer`'s usage patterns.** Thermometer is currently often called with fixed dim parameter. After reframing, Thermometer calls multiply in stdlib (every scalar encoder uses two Thermometer calls). Cache behavior should not degrade (both Thermometer calls for a range `[low, high]` get cached and reused across all scalar encodings of values in that range), but worth verifying.
