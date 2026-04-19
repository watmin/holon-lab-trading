# 058-001: `Atom<T>` — Parametric Atom as Substrate for Programs-as-Values

**Scope:** algebra
**Class:** CORE — **ACCEPTED (parametric)** 2026-04-18
**Parent:** 058-ast-algebra-surface
**Foundation:** ../FOUNDATION.md

---

## ACCEPTED as parametric — 2026-04-18

Atom accepts into core as `:Atom<T>` — **parametric over any serializable T**. Not just primitives (str, int, float, bool, keyword) — also `:Holon` (any AST node, including composite programs), user-defined struct/enum/newtype, any type the language admits.

### Why parametric and not primitive-only

FOUNDATION's "Programs ARE Holons" principle says every wat program is a holon AST. Without parametric Atom, you cannot **atomize** a program — cannot give it an opaque-identity vector, cannot store it in a library keyed by its own hash, cannot compare it cosine-wise against other programs, cannot Bind it to metadata.

Datamancer 2026-04-18: *"This is part of our substrate... if we can't host programs as atoms we're not doing it honest."*

Correct. Parametric Atom is substrate-level, not feature-level.

### The operation

```scheme
;; primitives — unchanged
(:wat/algebra/Atom 42)                      ;; :Atom<i64>
(:wat/algebra/Atom "foo")                   ;; :Atom<String>
(:wat/algebra/Atom :some/keyword)           ;; :Atom<Keyword>

;; composite holons — programs, bundles, binds, any AST
(:wat/algebra/Atom some-bundle)             ;; :Atom<Holon>
(:wat/algebra/Atom trained-model-program)   ;; :Atom<Holon>

;; user-defined types — any struct, enum, newtype
(:wat/algebra/Atom (my-candle ...))         ;; :Atom<my/types/Candle>
(:wat/algebra/Atom (my-wrapper 42))         ;; :Atom<my/app/Wrapper<i64>>
```

The hash for every variant is `hash(type-tag, canonical-EDN(value))` producing a deterministic seeded-random vector in `{-1, 0, +1}^d`. The type-tag makes `Atom<i64>` and `Atom<String>` holding the same bytes hash differently. EDN serialization is the universal canonical form (FOUNDATION's cryptographic provenance chain).

### Extraction — polymorphic

```scheme
(:wat/core/define (:wat/std/atom-value (a :Atom<T>) -> :T)
  ;; Returns the inner T directly. Single polymorphic function;
  ;; type-checker infers T at each call site.
  ...)

(:wat/std/atom-value (:wat/algebra/Atom 42))           ;; → 42 as :i64
(:wat/std/atom-value (:wat/algebra/Atom some-bundle))  ;; → some-bundle as :Holon
(:wat/std/atom-value (:wat/algebra/Atom my-candle))    ;; → the Candle struct
```

No tagged-union unwrapping, no match. The atom's parametric T carries the type through.

### Two encodings of any composite — both legitimate

For a composite `b = (Bundle [x y z])`:

| Form | Hash input | Vector | Structure recovery |
|---|---|---|---|
| `b` directly | structural (walk children) | composed from sub-vectors | `unbind` recovers parts |
| `(:wat/algebra/Atom b)` | opaque (EDN serialization) | seeded-random, one leaf | not recoverable from vector |

Different use cases:
- Direct encoding when structure matters (analogy, presence of constituents).
- Atomized wrapping when identity matters (library keying, opaque naming, program-as-pointer).

### The three Questions from 058's original draft, closed

**Q1 — typed hash categorically sound?** YES.

`hash(type-tag, bytes)` is the canonical tagged-union encoding. Coproduct payload + tag is how every typed-serialization library encodes ADTs (bincode, CBOR, Protobuf oneof). Beckman-compatible: `Atom : (T is Serializable) → :Holon` with hash respecting the coproduct structure. Hickey-compatible: type and value are orthogonal, not braided.

**Q2 — one variant vs separate variants?** ONE (parametric).

Not `AtomStr`/`AtomInt`/`AtomFloat`/... as separate HolonAST variants. One `Atom<T>` variant at the type level; at the Rust level, a type-tagged payload (or trait-object) that carries the canonical EDN form. Keeps the HolonAST enum at 7 variants — the small-enum virtue preserved. Pattern-matching through the `Atom<T>` parametric is handled by type-inference, not by variant-count.

**Q3-Q6** — resolved earlier: no `:Null`, keyword-naming-by-convention, additive backward compat, vector-side type erasure inherent.

### What this unlocks across 058

**For 058 itself:**

- **Engram libraries of programs.** `(:wat/std/HashMap :pattern-1 (:wat/algebra/Atom prog-1) :pattern-2 (:wat/algebra/Atom prog-2))` — a learned population of programs, keyed by name, each with its own identity vector.
- **Program similarity search.** `(:wat/algebra/cosine (:wat/algebra/Atom query-prog) (:wat/algebra/Atom candidate-prog))` — compare programs on the unit sphere. Identical programs have cosine = 1; different programs cosine ≈ 0.
- **Program bundling.** `(:wat/algebra/Bundle list-of-atomized-programs)` — superposition of programs. Learn against the bundle.
- **Program binding.** `(:wat/algebra/Bind (:wat/algebra/Atom prog) (:wat/algebra/Atom outcome))` — associate program with result. Compose to build learning loops.
- **Program analogy.** Reserved for the future when 058-014 graduates from DEFERRED: `(Analogy (Atom prog-a) (Atom prog-b) (Atom prog-c))` — A:B::C:? across programs.

**For 058-030 and 058-032:**

Parametric Atom requires parametric polymorphism. Accepting 058-001 as parametric commits 058-030 and 058-032 to the larger parametric story (see their updated ACCEPTED banners). The algebra cannot support parametric Atom without the type system that expresses it. Accept the substrate; accept the type system that carries it.

**For applications:**

- **Trading lab:** trained observer state can be atomized, libraries of observer patterns keyed by hash, cross-observer similarity measurement.
- **DDoS lab:** atomized attack signatures, program-per-attack stored in rule libraries, similarity across attack variants.
- **MTG lab:** atomized card-decisions, deck-as-atom identity, archetype libraries.
- **Any future app:** if it generates programs, it atomizes them and stores them. Universal pattern.

---

## Historical content (preserved as audit record)

## The Candidate

Generalize `Atom` to accept typed literals — not only strings, but integers, floats, booleans, keywords, and null.

### Current

```scheme
(:wat/algebra/Atom "foo")           ; string only — current signature
```

The current `Atom` signature in holon-rs accepts a string. The VectorManager hashes that string to produce a deterministic vector in the algebra's ternary output space `{-1, 0, +1}^d` (see FOUNDATION's "Output Space" section). In practice, Atom's seeded projection is dense bipolar — zeros arise from downstream arithmetic, not from Atom itself.

### Proposed

```scheme
(:wat/algebra/Atom "foo")           ; string literal
(:wat/algebra/Atom 42)              ; integer literal
(:wat/algebra/Atom 1.6)             ; float literal
(:wat/algebra/Atom true)            ; boolean literal
(:wat/algebra/Atom :wat/std/cos)    ; keyword literal (with optional namespace)
(:wat/algebra/Atom null)           ; null/none literal
```

All produce deterministic dense-bipolar vectors in the ternary output space `{-1, 0, +1}^d` via a **type-aware hash** — the literal's type tag is included in the hash input, so different types with similar-looking values yield different vectors:

```
(Atom 1)    ≠  (Atom "1")   ≠  (Atom 1.0)   ≠  (Atom :pos/1)
```

Each AST node stores its literal directly. `(atom-value (Atom 42))` returns `42` — the integer — via AST field access. No cleanup, no codebook search.

## Why This Matters

Under FOUNDATION's foundational principle, **the AST has the literal**. Atoms are AST nodes; they carry their literal on the node itself. When we need atoms for non-string values (integers in Array positions, floats as literal values, booleans as flags, keywords as reserved references), the current string-only signature forces awkward workarounds:

- Array positions as `"pos/0"` strings rather than integer `0`
- Boolean values as `"true"`/`"false"` strings rather than `true`/`false`
- Reserved stdlib atoms as hardcoded string conventions

Each workaround encodes type information in the string representation, which is categorically dishonest — the literal is just a string, but we want readers (and the type system) to treat it as the intended type.

The generalization removes the workarounds. `(Atom 0)` is the integer zero. `(Atom true)` is the boolean true. `(Atom :wat/std/cos-basis)` is a symbolic reserved keyword. Each carries its own literal directly.

## The Encoding Rule

The VectorManager's hash function accepts a tagged literal:

```
hash(type_tag, bytes(literal)) → seed → dense-bipolar vector in {-1, 0, +1}^d
```

Where `type_tag` is one of:
- `str` — string
- `int` — 64-bit signed integer
- `float` — 64-bit float
- `bool` — boolean
- `keyword` — keyword (optionally namespaced)
- `null` — null/none

Inclusion of the type tag in the hash input ensures different types with similar byte representations produce different vectors.

## Algebraic Question

Does this generalization compose with the existing algebra?

Yes — trivially. `Atom` produces a vector in the ternary output space `{-1, 0, +1}^d` (dense-bipolar in practice) regardless of the literal's type. All downstream operations (`Bind`, `Bundle`, `Permute`, `cosine`, `encode`) operate on the produced vector identically. The generalization widens the hash domain; nothing else changes.

Does it introduce a new algebraic operation?

No. It is a signature extension, not a new operation. The operation (hash-to-vector) remains. The set of valid inputs expands.

## Simplicity Question

Is this simple or easy?

Simple. The type-aware hash is mechanically straightforward. The alternative (encoding type information in string representations) is easy-looking but categorically braided — the reader has to know that `"pos/0"` "really means" the integer zero in some position role. The typed signature separates the type from the role cleanly.

Is anything complected by this change?

No. The type is a first-class property of the literal. The role binding (via `Bind` with a separate atom) remains separate. Role-filler stays role-filler; literal-type stays literal-type.

Could existing forms express it?

Partially — string literals can approximate other types by convention (`"42"` for the integer 42). But this loses:
- Type preservation on read-back (`atom-value` returns the string `"42"`, not the integer `42`)
- Cache-key disambiguation (`(Atom 42)` and `(Atom "42")` currently produce the same vector, which collapses distinct semantics)
- Algebraic honesty (the user's `42` is never really a string — naming it one is a workaround)

## Implementation Scope

**holon-rs changes** — widen the VectorManager's hash input:

```rust
pub enum AtomLiteral {
    Str(String),
    Int(i64),
    Float(f64),
    Bool(bool),
    Keyword(String),        // full keyword name, slashes are just characters
    Null,
}

impl VectorManager {
    pub fn get_vector(&self, literal: AtomLiteral) -> Vector {
        let seed = hash(literal.type_tag(), literal.bytes());
        deterministic_vector_from_seed(seed)
    }
}
```

~30 lines of Rust. No algebraic changes. The cache keys on the typed literal (tuple of tag + bytes). Deterministic. Cacheable.

**HolonAST changes** — `Atom` variant carries the typed literal:

```rust
pub enum HolonAST {
    Atom(AtomLiteral),
    // ... other variants unchanged
}
```

**`atom-value` stdlib** — direct field access:

```scheme
(:wat/core/define (:wat/std/atom-value atom-ast)
  (literal-field atom-ast))
```

Returns the literal from the AST node. Type-preserving.

## Questions for Designers

1. **Is the typed hash categorically sound?** The hash input is `(type_tag, literal_bytes)`. Different types with identical bytes produce different vectors. Is this the right axis of distinction — type first, then value — or should it be inverted (value first, then type), or collapsed (bytes only, letting the user provide a type-prefixed string if they want distinction)?

2. **Should `Atom` remain one variant, or should typed atoms be distinct variants?** Option A: `Atom(AtomLiteral)` — one variant, internally tagged. Option B: `AtomStr(String)`, `AtomInt(i64)`, `AtomFloat(f64)`, etc. — separate variants. Option A is simpler and keeps the HolonAST enum small. Option B allows pattern-matching on literal type without destructuring the inner `AtomLiteral`. Which fits the algebra better?

3. **What about `Null` as an atom?** FOUNDATION's foundational principle says literals live on AST nodes. A null/none literal raises a question: is "no value" a first-class atom, or should it be represented structurally (absence of a Bind, or a specific absence marker)? Holon traditionally has no `nil` — absence is structural. Does allowing `(Atom null)` break this convention?

4. **Keyword naming conventions — no namespace mechanism.** The language does NOT have namespaces as a structural feature. Slashes in keyword names are just characters — `:wat/std/cos-basis` is a single keyword whose name is `wat/std/cos-basis`. FOUNDATION uses the `:wat/std/...` prefix as a stdlib naming discipline to avoid collision with user atoms. Is naming convention alone sufficient, or does the language need a more robust collision-avoidance mechanism? (The type-aware hash ensures `(Atom :foo)` and `(Atom "foo")` differ; same-type collision is the user's responsibility.)

5. **Backward compatibility.** Existing code uses `(Atom "string")` exclusively. The generalization is additive — all existing atoms remain valid. Is there any need to migrate existing string atoms to other types (e.g., atoms that represent integers-as-strings), or is the expectation that existing code continues to work unchanged while new code uses the right type?

6. **Type erasure on the vector side.** The vector lives in the ternary output space `{-1, 0, +1}^d` regardless of the literal's type. If someone has ONLY a vector (no AST), they cannot recover the literal's type from the vector — cleanup against a codebook returns a candidate AST node, from which the literal (with type) can be read. Is this the right model, or should the type be recoverable from the vector somehow (seems impossible with deterministic hashing)?
