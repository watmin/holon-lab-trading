# 058-016: `HashMap` — Stdlib Dictionary Constructor

**Class:** STDLIB — **ACCEPTED + INSCRIPTION 2026-04-21**

---

## INSCRIPTION — 2026-04-21 — Cross-reference

Landed in wat-rs. The 2026-04-19 shipped-shape amendment below documents the flat-args form (`(HashMap k1 v1 k2 v2 ...)`) that actually ships; this cross-reference points at the Rust implementation.

- **Primitive dispatch:** [`wat-rs/src/runtime.rs`](https://github.com/watmin/wat-rs) — `:wat::std::HashMap` constructor arm + `infer_hashmap_constructor` in check.rs
- **Type:** `:HashMap<K,V>` registered via `TypeEnv::with_builtins()`; runtime backing `Value::wat__std__HashMap(Arc<HashMap<…>>)`
- **Companion accessors:** `:wat::std::get` (returns `:Option<V>`), `:wat::std::contains?` (returns `:bool`) both dispatch in runtime.rs
- **Tests:** indirect — trading-lab vocabulary modules exercise HashMap throughout. No dedicated `wat-tests/` file yet.

### What this inscription does NOT add

- **Composite-holon keys.** Keys stay primitive-scoped (`:i64`, `:f64`, `:bool`, `:String`, keyword) in the currently-shipped runtime; heterogeneous types are stored with type-tagged canonical strings so they never collide. Composite-key support graduates when a caller demands it.
- **`remove` / `insert` / `iter`.** Immutable construction + lookup only. No mutation primitives — wat has no mutation. Functional update (build-new-HashMap-with-change) can be added as stdlib over the constructor if a caller surfaces one.

---

> **STATUS: SUPERSEDES the original `Map` proposal** (2026-04-18 Rust-surface naming sweep).
>
> The form previously called `Map` is now named `HashMap` — matching Rust's `std::collections::HashMap` directly. The wat UpperCase constructor, the type annotation `:HashMap<K,V>`, and the runtime backing all share one name. This is consistent with the Rust-primitive type decision (`:f64` not `:Scalar`, `:bool` not `:Bool`) — one name per concept across algebra, type annotation, and runtime.
>
> **Also changed in the same sweep:** `get` is now direct structural lookup (no `cleanup`, no `Unbind` to a noisy vector, no codebook). The runtime materializes a Rust `HashMap` from the Holon AST for O(1) lookups. `get` returns `:Option<holon::HolonAST>` — `(Some v)` on hit, `:None` on miss.
>
> The concept is unchanged. Only the name and the accessor mechanics.
>
> **2026-04-19 shipped shape.** `:wat::std::HashMap` is variadic with
> alternating key/value args: `(HashMap k1 v1 k2 v2 ...)`. Odd arity
> halts. The "Vec of Pair" signature in the historical sections is
> superseded — the flat-args form is Lisp-idiomatic and easier to
> write. Keys are primitive-scoped in the currently-shipped wat-rs
> (`:i64`, `:f64`, `:bool`, `:String`, keyword); the Rust backing
> stores them as type-tagged canonical strings so heterogeneous key
> types never collide. Composite-holon keys (the algebra's unified-
> data-model vision) graduate when a caller demands them.
> `:wat::std::contains?` ships alongside `:wat::std::get` — boolean
> membership test, same argument shape.

**Scope:** algebra
**Class:** STDLIB
**Parent:** 058-ast-algebra-surface
**Foundation:** ../FOUNDATION.md
**Depends on:** 058-021-bind, 058-001-atom-typed-literals (keys as typed atoms)
**Companion proposals:** 058-026-array (now `Vec`), 058-027-set (now `HashSet`)

---

## HISTORICAL CONTENT — SUPERSEDED BY BANNER ABOVE

The sections below were written before the 2026-04-18 container-constructor rename + `get`-unification sweep. They describe an earlier design where `get` was `(cleanup (Unbind map-vec key))` — a vector-side retrieval over a codebook, with designer questions about cleanup behavior and encoder dispatch. **That design is REPLACED.** `get` is now direct structural lookup through the runtime's Rust `HashMap` backing — O(1), exact, returning `:Option<holon::HolonAST>`. Cleanup doesn't participate; Unbind doesn't participate; there is no codebook. The banner at the top of this file is authoritative; the content below is preserved as audit record only.

---

## The Candidate

A wat stdlib function that constructs an encoded dictionary from a list of key-value pairs:

```scheme
(:wat::core::define (:wat::std::HashMap (pairs :Vec<Pair<holon::HolonAST,holon::HolonAST>>) -> :holon::HolonAST)
  (:wat::algebra::Bundle
    (:wat::core::map (:wat::core::lambda ((pair :(Holon,Holon)) -> :holon::HolonAST)
           (:wat::algebra::Bind (:wat::core::first pair) (:wat::core::second pair)))
         pairs)))
```

Expands to a Bundle of `Bind(key, value)` for each pair — classical VSA role-filler structure.

### Semantics

`HashMap` encodes a dictionary as a Holon. Each key-value pair is represented by `Bind(key, value)`, and all pairs are superposed via Bundle. The runtime backs the Holon with Rust's `std::HashMap` for efficient O(1) lookups:

```scheme
(:wat::core::define :my::app::record
  (:wat::std::HashMap (:wat::core::vec (:wat::core::vec (:wat::algebra::Atom :color) red-value)
                 (:wat::core::vec (:wat::algebra::Atom :shape) circle-value)
                 (:wat::core::vec (:wat::algebra::Atom :size)  large-value))))

;; Retrieval: get the value for :color
(:wat::core::define :my::app::recovered-color
  (:wat::std::get :my::app::record (:wat::algebra::Atom :color)))
;; → (Some red-value)  [the value AST, not a noisy decode]
```

### The `get` accessor — unified across HashMap, Vec, HashSet

```scheme
(:wat::core::define (:wat::std::get (container :holon::HolonAST) (locator :holon::HolonAST) -> :Option<holon::HolonAST>)
  ;; Structural lookup through the container's efficient Rust backing.
  ;; For HashMap: hash-based lookup against the key, O(1) average.
  ;; Returns (Some value) on hit, :None on miss.
  ...)
```

No `cleanup`. No noisy `Unbind` decode. No codebook. The runtime uses Rust's HashMap under the hood; the Holon describes what the container IS; `get` goes through the efficient backing. This is the same `get` that works on `Vec` (indexed) and `HashSet` (membership) — one signature, uniform contract, returns `:Option<holon::HolonAST>` everywhere.

See FOUNDATION's "Presence is Measurement, Not Verdict" for why Cleanup is not part of the wat algebra. Structural retrieval (`get`) uses AST equality and the runtime's Rust backing; similarity retrieval (`presence`) uses cosine against the noise floor. Two regimes, cleanly separated.

## Why Stdlib Earns the Name

Under FOUNDATION's stdlib criterion:

1. **Its expansion uses only existing core forms.** Bundle, Bind — both core. Unbind and Cleanup are used by the `get` accessor, both have dedicated sub-proposals (058-024, 058-025).

2. **It reduces ambiguity for readers.** `(Map kv-pairs)` communicates "build a dictionary." The raw `(Bundle (map (lambda (kv) (Bind (first kv) (second kv))) kv-pairs))` is mechanically identical but forces the reader to decode the role-filler pattern.

Both criteria met.

## Arguments For

**1. Role-filler binding is canonical VSA — naming it helps.**

The structure `Bundle(Bind(k1, v1), Bind(k2, v2), ...)` IS the classical VSA dictionary, named in Plate, Kanerva, Eliasmith literature. Providing `Map` as a stdlib form acknowledges the canonicity and makes the construction direct.

**2. Makes data-oriented vocab code direct.**

A vocab module producing structured observations:

```scheme
(:wat::std::HashMap (:wat::core::vec
  (:wat::core::vec :price price-value)
  (:wat::core::vec :volume volume-value)
  (:wat::core::vec :timestamp time-value)))
```

Reads as "build a record with these fields." Without `Map`, the reader must recognize the Bundle-of-Binds pattern and infer the dictionary intent.

**3. Pairs naturally with `get` for read/write symmetry.**

Map constructs; `get` retrieves. Both in the same stdlib vocabulary. Users write dictionary-style code without dropping into primitive Bind/Bundle/Unbind expressions.

**4. Composes with other stdlib forms.**

- Bundle of Maps: unions of dictionaries
- Bind(role, Map): parameterized records
- Array of Maps: tables
- Map containing Maps: nested structures

All naturally expressible because Map is a wat function, not an opaque variant.

## Arguments Against

**1. Accessor requires a codebook (for cleanup).**

`get` retrieves a value via Unbind-then-Cleanup. Cleanup requires a codebook (candidate vocabulary). Not all applications have one ready at call time.

**Mitigation:** provide both variants — `get` with cleanup, `get-raw` without. Applications without a codebook use `get-raw` and handle the noise themselves.

**2. Map with duplicate keys bundles both values.**

`(Map (list (list :a 1) (list :a 2)))` produces `Bundle(Bind(:a, 1), Bind(:a, 2))`. A `get` for `:a` returns a superposition of 1 and 2 — noisy, not crisp.

**Mitigation:** document that Map does NOT deduplicate. Users wanting single-value semantics deduplicate before calling. If frequent, a `UniqueMap` wrapper could exist in stdlib.

**3. Two-element list argument shape.**

Each kv-pair is a 2-element list `(list key value)`. Alternative: a flat interleaved list `(Map (list k1 v1 k2 v2 ...))`, or an explicit association-list shape. Which is canonical?

**Mitigation:** two-element lists match Lisp's standard alist convention, work naturally with Lisp's `map`/`reduce`, and pair with the `first`/`second` accessors. Accept it; document clearly.

**4. Accessors are lowercase.**

`get` and `get-raw` are lowercase — not UpperCase forms. By the strict "UpperCase = own doc" rule they don't need their own proposals. Here they are documented in the Map proposal since they are Map's canonical accessors. Alternative: separate accessor-doc. This proposal keeps them with Map for cohesion.

## Comparison

| Form | Class | Expansion | Role |
|---|---|---|---|
| `Map(kv-pairs)` | STDLIB (this) | Bundle of Bind(k, v) per pair | Dictionary constructor |
| `Array(ts)` | STDLIB (058-026) | Sequential(ts) | Ordered indexed list |
| `Set(ts)` | STDLIB (058-027) | Bundle(ts) | Unordered collection |
| `get(m, k, cb)` | STDLIB helper (this) | cleanup(Unbind(m, k), cb) | Map accessor |
| `get-raw(m, k)` | STDLIB helper (this) | Unbind(m, k) | Raw Map accessor |
| `Bundle(xs)` | CORE | threshold(Σ xs[i]) | Primitive |
| `Bind(a, b)` | CORE | a[i] * b[i] | Primitive |

Map is the data-structure-constructor tier; get is its accessor helper.

## Algebraic Question

Does Map compose with the existing algebra?

Yes. Output is a vector in the ternary output space `{-1, 0, +1}^d` (Bundle of Binds of ternary inputs; see FOUNDATION's "Output Space" section). All downstream operations work.

Is it a distinct source category?

No — Map is a specific composition of Bind and Bundle. Stdlib.

## Simplicity Question

Is this simple or easy?

Simple. One-line expansion for Map. Two-line definition for `get` (with cleanup) and `get-raw` (without).

Is anything complected?

No. Map's role is "build a dictionary"; `get`'s role is "retrieve a value." Clear separation.

Could existing forms express it?

Yes — via explicit Bundle/Bind composition. Named form earns its place via reader clarity and canonical role-filler recognition.

## Implementation Scope

**Zero Rust changes.** Pure wat.

**wat stdlib addition** — `wat/std/structures.wat` (or similar):

```scheme
(:wat::core::define (:wat::std::HashMap kv-pairs)
  (:wat::algebra::Bundle
    (:wat::core::map (:wat::core::lambda (kv) (:wat::algebra::Bind (:wat::core::first kv) (:wat::core::second kv))) kv-pairs)))

(:wat::core::define (:wat::std::get map-holon key candidates)
  (cleanup (Unbind map-holon key) candidates))

(:wat::core::define (:wat::std::get-raw map-holon key)
  (Unbind map-holon key))
```

## Questions for Designers

1. **Duplicate keys.** `(Map (list (list :a 1) (list :a 2)))` produces noisy cleanup for key `:a`. Document the behavior as "Map does not deduplicate; pre-filter if needed," or add an automatic deduplication pass? Recommendation: document, don't automate.

2. **Accessor variants.** `get` (with cleanup) vs `get-raw` (without). Both useful. Keep both with these names? Or use `get` for raw and `get-cleanup` for the cleanup variant? Recommendation: `get` is the common case (with cleanup); `get-raw` for the raw case.

3. **Key type constraints.** Map keys are often keyword atoms (`:color`, `:price`). Can keys also be integers, strings, composite ASTs? Per 058-001, Atom accepts typed literals; any atom can be a key. Per 058-007-conditional-bind, full ASTs can be used as binding operands. Confirm: Map keys can be any holon.

4. **Performance for large Maps.** Bundle's capacity is bounded (~d / ln(K) items for reliable cleanup). Maps with many keys exceed capacity and produce noisy retrieval. Document the capacity bound; stdlib could provide a `LargeMap` variant using partitioning if demand arises.

5. **Nested Maps.** `(Map (list (list :user (Map (list (list :name "alice") (list :age 30))))))` nests dictionaries. `get`s compose: `(get (get root :user cb) :name cb)`. Or a `deep-get` stdlib variant for path-based access. Out of scope for this proposal but worth noting as a likely next stdlib addition.

6. **Empty Map.** `(Map (list))` produces an empty Bundle — an all-zeros or undefined vector. Document the degenerate case or forbid it.

7. **Dependency ordering.** Map depends on Bundle and Bind (both core). `get` depends on Unbind (058-024) and Cleanup (058-025). If any prerequisite is rejected, Map and its accessors change. Explicit dependency statement: this proposal assumes all four primitives are available.
