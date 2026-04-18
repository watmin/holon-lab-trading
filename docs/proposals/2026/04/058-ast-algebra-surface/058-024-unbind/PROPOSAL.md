# 058-024: `Unbind` — Decode Alias for Bind

**Scope:** algebra
**Class:** STDLIB (named alias for Bind)
**Parent:** 058-ast-algebra-surface
**Foundation:** ../FOUNDATION.md
**Depends on:** 058-021-bind (pivotal — Unbind is an alias for Bind)

## The Candidate

A wat stdlib function that represents the INVERSE of a Bind operation — the decode direction of role-filler binding:

```scheme
(define (Unbind composite role-or-filler)
  (Bind composite role-or-filler))
```

Identical math to Bind. The ONLY distinction is reader intent: Unbind communicates "I am decoding, extracting, recovering" rather than "I am binding, composing, encoding."

### Semantics

For bipolar vectors, Bind is self-inverse:

```
Bind(Bind(role, filler), role) = filler       ; decode the filler from the composite
```

So the "unbind" operation is literally another Bind call. The stdlib form `Unbind` names this decode usage explicitly.

Typical usage:

```scheme
;; Encoding: bind each key to its value, bundle them
(define record
  (Bundle (list
    (Bind :color red)
    (Bind :shape circle)
    (Bind :size large))))

;; Decoding: unbind by a known key, cleanup against candidate values
(define recovered-color
  (cleanup (Unbind record :color) color-vocabulary))
```

Here `Unbind record :color` says "apply the `:color` key against the encoded record to decode a noisy version of `red`." Mechanically, this is `Bind(record, :color)` — but the intent is DECODE, not ENCODE.

## Why Stdlib Earns the Name

Under FOUNDATION's stdlib criterion:

1. **Its expansion uses only existing core forms.** Bind is core (058-021).
2. **It reduces ambiguity for readers.** `(Unbind composite key)` reads as "recover the value bound to this key." `(Bind composite key)` reads as "bind composite to key" — which is structurally correct but semantically misleading in the decode context.

Both criteria met.

## Arguments For

**1. The self-inverse identity is implementation detail, not reader intent.**

The fact that `Bind` is its own inverse for bipolar vectors is a mathematical property. It does NOT mean that encoding and decoding should share a name in vocab code. The two contexts are different:

- Encoding: taking two DISTINCT pieces of information (role, filler) and producing their BOUND composite.
- Decoding: taking a composite and a KEY and producing the noisy-but-recoverable BOUND filler.

Readers navigating between these contexts benefit from a name per context. Encoding uses Bind; decoding uses Unbind.

**2. It makes accessor stdlib forms readable.**

From 058-016-data-structures:

```scheme
(define (get map-thought key candidates)
  (cleanup (Unbind map-thought key) candidates))
```

Versus:

```scheme
(define (get map-thought key candidates)
  (cleanup (Bind map-thought key) candidates))  ; semantically confusing
```

The first reads as "to get from a map, unbind the key and clean up." The second reads as "to get, bind the key to the map?" — which is backwards from the intent.

**3. Non-bipolar future-proofing.**

If the algebra ever admits non-bipolar or ternary vectors where Bind is NOT self-inverse, Unbind becomes a distinct operation that requires an actual inverse algorithm. Having the name in stdlib from the start reserves the semantic space.

For Resonance's ternary outputs (058-006): `Bind(Resonance(v, ref), ref)` may not recover `v` cleanly because Resonance's zeros don't survive the second Bind as originally. If there are use cases for "decode after Resonance" that need a true inverse, Unbind becomes the place to implement it.

**4. Distinct VSA literature convention.**

Plate's HRR literature distinguishes "bind" (associative) from "unbind" (probe). Kanerva's BSC uses XOR for both but names the operations distinctly in practice. MAP VSA's binding (multiplication) is its own inverse for binary values, but the LITERATURE names the decode operation separately.

Following convention reduces translation friction for readers coming from VSA background.

## Arguments Against

**1. Two names for one operation (at bipolar input).**

`(Unbind c k) = (Bind c k)` for bipolar vectors. Mathematically identical. Having two names for one operation is classic complection by redundancy.

**Counter:** the identity holds for bipolar SPECIFICALLY. If bipolar is the only input regime, having two names IS complection. But:
- Reader intent carries real information (encode vs. decode).
- Non-bipolar inputs may need different behavior.
- VSA literature maintains the distinction.

The redundancy is accepted; the clarity gain exceeds the redundancy cost.

**2. If we accept Unbind, do we accept `Anti-Bundle`, `De-Permute`, etc.?**

Proliferation risk. Every primitive with a "decode" interpretation gets a decode alias?

**Counter:** Unbind is the specific case where the inverse is non-obvious in reader context. `Permute(v, -k)` is self-documenting — the negative step IS the decode. `Anti-Bundle` doesn't exist because Bundle is not reversible. Unbind is the unique case where the operation and its inverse share a name but not a reader context.

**3. Cache key concerns.**

`(Bind a b)` and `(Unbind a b)` produce the same vector but have different AST shapes. Two cache entries for one vector. Minor memory inefficiency.

**Mitigation:** canonicalize at parse time (Unbind expands to Bind, shares cache), OR preserve the name for AST clarity (accept the duplicate cache). Tooling decision.

## Comparison

| Form | Class | Operation | Reader intent |
|---|---|---|---|
| `Bind(a, b)` | CORE (058-021) | `a[i] * b[i]` | Encode: compose role and filler |
| `Unbind(c, k)` | STDLIB (this) | `c[i] * k[i]` (same math) | Decode: recover filler from composite by key |
| `Permute(v, k)` | CORE (058-022) | cyclic shift by `k` | Encode or decode (k sign indicates direction) |

Unbind is the only stdlib alias for a core operation where the reader intent is context-dependent.

## Algebraic Question

Does Unbind compose with the existing algebra?

Trivially — it IS Bind. All downstream operations unchanged.

Is it a distinct source category?

No. Bind alias.

## Simplicity Question

Is this simple or easy?

Simple. One-line stdlib alias.

Is anything complected?

The two-names-one-operation issue. Mitigated by reader-context argument.

Could existing forms express it?

Yes — `(Bind c k)`. Named form for reader clarity.

## Implementation Scope

**Zero Rust changes.** Pure wat.

**wat stdlib addition** — `wat/std/decode.wat` or `wat/std/bind.wat`:

```scheme
(define (Unbind composite role-or-filler)
  (Bind composite role-or-filler))
```

## Questions for Designers

1. **Accept the alias or reject it?** The operation is mathematically Bind. This proposal argues the reader-intent distinction earns the alias. Alternative: document that "unbind is Bind" and have vocab code always call Bind. Recommendation: accept Unbind; the clarity gain is load-bearing for accessor stdlib forms like `get`.

2. **Cache canonicalization.** Same issue as Linear/Log/Circular from 058-008+. Preserve stdlib form in AST (separate cache, semantic name visible) or eagerly expand (canonical cache, lose name). Consistency across all stdlib aliases is key.

3. **Non-bipolar future.** If Resonance (058-006) or other forms produce ternary/non-bipolar outputs, Unbind may need a NEW implementation separate from Bind. Is this proposal reserving the name for that future, or strictly a bipolar alias?

4. **Naming within accessor stdlib forms.** `get`, `nth`, and any `lookup`-style accessors use Unbind internally. Is the word "Unbind" consistently usable in all their definitions, or does the argument-order convention (composite first vs. key first) vary?

5. **Dependency on 058-021-bind.** If Bind is in some unexpected way modified (e.g., non-bipolar input support), Unbind's alias relationship may change. Confirm Bind's signature and semantics in 058-021 before finalizing Unbind.

6. **Is "Unbind" the right name?** Alternatives: `Probe`, `Decode`, `Extract`, `Recover`. "Unbind" is convention in VSA literature. Recommendation: keep "Unbind" for convention match; document clearly.
