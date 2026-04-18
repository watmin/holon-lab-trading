# 058-024: `Unbind` — Decode Alias for Bind

**Scope:** algebra
**Class:** STDLIB (named macro alias for Bind)
**Parent:** 058-ast-algebra-surface
**Foundation:** ../FOUNDATION.md
**Depends on:** 058-021-bind (pivotal — Unbind is an alias for Bind)

## The Candidate

A wat stdlib macro (per 058-031-defmacro) that represents the INVERSE of a Bind operation — the decode direction of role-filler binding:

```scheme
(defmacro (Unbind (c :AST) (k :AST) -> :AST)
  `(Bind ,c ,k))
```

Identical math to Bind. The ONLY distinction is reader intent at source: Unbind communicates "I am decoding, extracting, recovering" rather than "I am binding, composing, encoding." Expansion happens at parse time, so `hash((Unbind c k)) = hash((Bind c k))` — the alias-collision concern from Beckman's finding #4 does not apply.

### Semantics

Per FOUNDATION's "Output Space" section, Bind is self-inverse on non-zero positions:

```
Bind(Bind(role, filler), role)[i] = filler[i]   wherever role[i] ≠ 0
Bind(Bind(role, filler), role)[i] = 0           wherever role[i] = 0
```

So the "unbind" operation is literally another Bind call. The stdlib form `Unbind` names this decode usage explicitly. Zero positions in the role mean "the role carried no signal at dimension `i`," and decode correctly returns `0` there.

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

The fact that `Bind` is its own inverse (on non-zero positions, per FOUNDATION's "Output Space" section) is a mathematical property. It does NOT mean that encoding and decoding should share a name in vocab code. The two contexts are different:

- Encoding: taking two DISTINCT pieces of information (role, filler) and producing their BOUND composite.
- Decoding: taking a composite and a KEY and producing the noisy-but-recoverable BOUND filler.

Readers navigating between these contexts benefit from a name per context. Encoding uses Bind; decoding uses Unbind.

**2. It makes accessor stdlib forms readable.**

From 058-016-map:

```scheme
(define (get map-holon key candidates)
  (cleanup (Unbind map-holon key) candidates))
```

Versus:

```scheme
(define (get map-holon key candidates)
  (cleanup (Bind map-holon key) candidates))  ; semantically confusing
```

The first reads as "to get from a map, unbind the key and clean up." The second reads as "to get, bind the key to the map?" — which is backwards from the intent.

**3. Zero-aware decode future-proofing.**

Per FOUNDATION's "Output Space" section, the algebra's output space is ternary; Bind is self-inverse **on non-zero positions**. For Resonance's outputs (058-006), `Bind(Resonance(v, ref), ref)` recovers `v` only where `ref` is non-zero; zero positions stay zero. If there are use cases for "decode after Resonance" that want richer handling of the zero positions (e.g., mass-preserving completion, cleanup over the non-zero support), Unbind is the natural name to carry that behavior when it's introduced. Having the name in stdlib from the start reserves the semantic space.

**4. Distinct VSA literature convention.**

Plate's HRR literature distinguishes "bind" (associative) from "unbind" (probe). Kanerva's BSC uses XOR for both but names the operations distinctly in practice. MAP VSA's binding (multiplication) is its own inverse for binary values, but the LITERATURE names the decode operation separately.

Following convention reduces translation friction for readers coming from VSA background.

## Arguments Against

**1. Two names for one operation (within today's semantics).**

`(Unbind c k) = (Bind c k)` per FOUNDATION's "Output Space" section — Bind is self-inverse on non-zero positions, so the encode and decode directions share a formula. Having two names for one operation is classic complection by redundancy.

**Counter:** the identity is a property of today's definition. Even now:
- Reader intent carries real information (encode vs. decode).
- Future zero-aware decode variants may need different behavior at zero positions of the key.
- VSA literature maintains the distinction.

The redundancy is accepted; the clarity gain exceeds the redundancy cost.

**2. If we accept Unbind, do we accept `Anti-Bundle`, `De-Permute`, etc.?**

Proliferation risk. Every primitive with a "decode" interpretation gets a decode alias?

**Counter:** Unbind is the specific case where the inverse is non-obvious in reader context. `Permute(v, -k)` is self-documenting — the negative step IS the decode. `Anti-Bundle` doesn't exist because Bundle is not reversible. Unbind is the unique case where the operation and its inverse share a name but not a reader context.

**3. Cache key concerns — RESOLVED by parse-time expansion.**

Under the original `(define ...)` framing, `(Bind a b)` and `(Unbind a b)` would have different AST shapes and thus different cache keys. With `defmacro` (058-031), expansion runs at parse time: the `Unbind` invocation is rewritten to `(Bind c k)` BEFORE any hashing or caching occurs. One cache entry; one hash. Finding #4 (alias hash collision) from the designer review is resolved.

## Comparison

| Form | Class | Operation | Reader intent |
|---|---|---|---|
| `Bind(a, b)` | CORE (058-021) | `a[i] * b[i]` | Encode: compose role and filler |
| `Unbind(c, k)` | STDLIB macro (this) | `c[i] * k[i]` (same math, expanded at parse time) | Decode: recover filler from composite by key |
| `Permute(v, k)` | CORE (058-022) | cyclic shift by `k` | Encode or decode (k sign indicates direction) |

Unbind is the only stdlib macro alias for a core operation where the reader intent is context-dependent.

## Algebraic Question

Does Unbind compose with the existing algebra?

Trivially — it IS Bind. All downstream operations unchanged.

Is it a distinct source category?

No. Bind alias.

## Simplicity Question

Is this simple or easy?

Simple. One-line stdlib alias.

Is anything complected?

The two-names-one-operation issue. Mitigated by reader-context argument AND parse-time expansion (the two names collapse to one canonical AST before hashing).

Could existing forms express it?

Yes — `(Bind c k)`. Named macro earns its place via reader clarity; the source form `Unbind` disappears after parse-time expansion.

## Implementation Scope

**Zero Rust changes beyond 058-031-defmacro's macro-expansion pass.** Pure wat.

**wat stdlib addition** — `wat/std/decode.wat` or `wat/std/bind.wat`:

```scheme
(defmacro (Unbind (c :AST) (k :AST) -> :AST)
  `(Bind ,c ,k))
```

Registered at parse time (per 058-031-defmacro): every `(Unbind c k)` invocation is rewritten to `(Bind c k)` before hashing.

## Questions for Designers

1. **Accept the alias or reject it?** The operation is mathematically Bind. This proposal argues the reader-intent distinction earns the alias. Alternative: document that "unbind is Bind" and have vocab code always call Bind. Recommendation: accept Unbind; the clarity gain is load-bearing for accessor stdlib forms like `get`.

2. **Cache canonicalization — resolved.** Parse-time expansion (058-031-defmacro) means `Unbind` and `Bind` invocations collapse to the same canonical AST before hashing; they share one cache entry automatically. Same resolution applies uniformly to all stdlib macro aliases (Linear/Log/Circular/Concurrent/Set/etc.).

3. **Zero-aware decode future.** Per FOUNDATION's "Output Space" section, the algebra's default output is ternary; Bind is self-inverse on non-zero positions. If future work introduces a decode variant that handles zero positions of the key differently (e.g., treating zero as "don't project" vs. "project and zero out"), Unbind may diverge from Bind. Is this proposal reserving the name for that future, or strictly an alias today?

4. **Naming within accessor stdlib forms.** `get`, `nth`, and any `lookup`-style accessors use Unbind internally. Is the word "Unbind" consistently usable in all their definitions, or does the argument-order convention (composite first vs. key first) vary?

5. **Dependency on 058-021-bind.** If Bind's semantics are modified (e.g., a zero-aware decode variant is added), Unbind's alias relationship may change. Confirm Bind's signature and semantics in 058-021 before finalizing Unbind.

6. **Is "Unbind" the right name?** Alternatives: `Probe`, `Decode`, `Extract`, `Recover`. "Unbind" is convention in VSA literature. Recommendation: keep "Unbind" for convention match; document clearly.
