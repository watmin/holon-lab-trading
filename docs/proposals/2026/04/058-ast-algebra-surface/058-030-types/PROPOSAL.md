# 058-030: Types — The Language Core Type System

**Scope:** language
**Class:** LANGUAGE CORE — **INSCRIPTION amendments 2026-04-19, 2026-04-20**
**Parent:** 058-ast-algebra-surface
**Foundation:** ../FOUNDATION.md
**Depends on:** 058-001-atom-typed-literals (for atom literal types)
**Companion proposals:** 058-028-define, 058-029-lambda, 058-033-try

---

## INSCRIPTION — 2026-04-20 — Typealias expansion at unification + the `reduce` pass

Code and prose are reflections. When they disagree, the code wins —
and the prose catches up. This amendment backfills the spec to
match what wat-rs shipped on 2026-04-20.

### What was missing

The original 058-030 specified four type-declaration forms —
`newtype`, `struct`, `enum`, `typealias` — and stated that
typealiases are structurally identical to their expansion
(`:A` and its expansion are the SAME type). But the
implementation in wat-rs parsed and registered typealiases while
`unify` consumed types structurally without peeling aliases.
Result: `:wat::std::stream::Stream<T>` would register as an
alias but never be recognized as equivalent to its tuple
expansion at any use site.

The gap wasn't in the spec — the spec was right. The gap was in
the implementation. **Alias expansion at unification shipped
2026-04-20** (wat-rs commit `7f90760`).

### The mature answer — `reduce`

The initial slice added a single `expand_alias` call inside
`unify`'s prologue. That worked for all structural unification
sites. But `infer_positional_accessor` (`first`/`second`/`third`
on Vec + tuple) inspects the type SHAPE directly after
`apply_subst` — it never went through `unify`. Using
`:wat::std::stream::Stream<T>` (a typealias over a tuple) with
`first` / `second` tripped over the gap.

The cheap move was a second one-off `expand_alias` call at
that site. The honest move (wat-rs commit `b10f002`) was to
recognize this as the shape of a deeper flaw: wat-rs had two
half-passes (`apply_subst` for substitution + `expand_alias` for
aliases) that every shape-inspection site had to chain manually.

Mature type systems have **one normalization pass**. That pass
is now named and shipped as `reduce(ty, subst, types)` —
recursively follows every Var substitution AND expands every
typealias, at every level of the tree. The relationship between
the three functions is explicit:

- `apply_subst(ty, subst)` — walks Vars, preserves alias names.
  Used for error-message display so the reader sees the surface
  name they wrote.
- `expand_alias(ty, env)` — peels aliases at one level, leaves
  Vars. An implementation detail of `reduce`.
- `reduce(ty, subst, types)` — both, recursively. Used at every
  shape-inspection site (matching on `TypeExpr::Tuple`,
  `TypeExpr::Parametric { head, ... }`, `TypeExpr::Fn`, etc.)
  and at unification's prologue.

Sites using `reduce` after the sweep: unify prologue,
`infer_positional_accessor`, `infer_drop` (Sender/Receiver
shape), `infer_get` (HashMap / HashSet branches), `infer_try`
(Result<T,E> extraction), `infer_spawn` (Fn-value extraction
from the first arg). Every future shape-inspection site uses
the same idiom.

### Cycle detection at registration

`TypeEnv::register` now rejects cyclic aliases before insertion,
guaranteeing that every alias in the registry is non-cyclic and
`reduce` terminates. `(typealias :A :B)` followed by
`(typealias :B :A)` halts the second registration with
`TypeError::CyclicAlias`. Direct self-reference
`(typealias :A :A)` is caught by the same reachability walk.

### Stdlib precedent

The privileged path `register_stdlib_types` (mirroring the
existing `register_stdlib_defmacros`) lets stdlib wat files
declare typealiases under `:wat::*` without fighting the
reserved-prefix gate that protects user source. First real use:
`:wat::std::LocalCache<K,V>` was declared in `wat/std/LocalCache.wat`
as an alias for `:rust::lru::LruCache<K,V>` — the wat-native name
lived alongside the defines, expressed in wat source, the same
way users would declare their own typealiases under their own
prefixes. (Arc 013 externalized that crate 2026-04-21:
LocalCache now lives at `:user::wat::std::lru::LocalCache<K,V>`
in `crates/wat-lru/wat/lru.wat` as an external wat crate. The
typealias pattern is preserved — community crates inherit the
same substrate.) Same pattern later used by
`crates/wat-lru/wat/service.wat` (`CacheService::Request<K,V>`,
`CacheService::ReplyTx<V>`, etc.),
`wat/std/service/Console.wat` (`Console::Message`), and
`wat/std/stream.wat` (`Stream<T>`, `Producer<T>`).

### Lesson captured

When a feature expected in a mature language isn't there, ask
*why is this missing?* before patching. Two half-passes that
should have been one whole pass is a substrate signal, not a
papering-over-the-gap opportunity. See wat-rs
`docs/arc/2026/04/004-lazy-sequences-and-pipelines/BACKLOG.md`
for the full narrative and the cross-session memory entry
`feedback_absence_is_signal.md`.

### Implementation Reference

- wat-rs commit `7f90760` (2026-04-20) — typealias expansion at
  unification; cycle detection at register.
- wat-rs commit `b10f002` (2026-04-20) — `reduce` as the single
  normalization pass, subsumes the prior one-off `expand_alias`
  call.
- `wat-rs/tests/wat_typealias.rs` — 8 cases covering simple
  alias, parametric alias, alias-of-alias chain, cyclic
  rejection, shape-site flow (`:wat::std::get` through a
  HashMap alias, spawn through a :fn alias), alias preserves
  type mismatches, alias return types.

---

## INSCRIPTION — 2026-04-19 — Struct construction + field access syntax pinned

This proposal locked struct DECLARATIONS in 2026-04-18:

```scheme
(:wat::core::struct :project::market::Candle
  (open   :f64)
  (high   :f64)
  (low    :f64)
  (close  :f64)
  (volume :f64))
```

…and gestured at "field access is a function on the struct type" without pinning the construction or accessor syntax. The implementation slice on 2026-04-19 (wat-rs commit `0e7309a`) pinned both. Recording them here.

### Construction — `<struct-path>/new`, positional

A struct type `:my::ns::T` with fields `(f1 :T1) (f2 :T2) ... (fn :Tn)` in declaration order gains an **auto-generated constructor** at keyword path `:my::ns::T/new` with type `:fn(T1, T2, ..., Tn) -> :my::ns::T`. Invocation is positional — arguments in declaration order:

```scheme
(:project::market::Candle/new 100.0 101.0 99.0 100.5 1000.0)
```

Users do NOT write the constructor themselves; it appears when the struct's declaration lands. The canonical usage style names positional values via `let` at the call site, making construction self-documenting even though the constructor itself is positional:

```scheme
(let ((open 1.0)
      (high 2.0)
      (low 3.0)
      (close 4.0)
      (volume 5.0))
  (:project::market::Candle/new open high low close volume))
```

Field names in declaration order; let bindings with those same names at construction. Position is load-bearing; naming discipline at the call site carries the meaning.

The type name itself (`:project::market::Candle`) is NOT a callable — it appears only in type annotations. Only `/new` invokes the constructor. This separates TYPE from CONSTRUCTOR cleanly.

### Field access — `<struct-path>/<field-name>`, auto-generated

For each field in the declaration, an **auto-generated accessor** appears at keyword path `:my::ns::T/<field-name>` with type `:fn(:my::ns::T) -> <field-type>`:

```scheme
(:project::market::Candle/open candle)    ;; → :f64
(:project::market::Candle/close candle)   ;; → :f64
```

Canonical usage mirrors construction — let-bind each extracted field to a local name:

```scheme
(:wat::core::let*
  (((c :project::market::Candle) (:project::market::Candle/new 100.0 101.0 99.0 100.5 1000.0))
   ((o :f64)  (:project::market::Candle/open  c))
   ((cl :f64) (:project::market::Candle/close c)))
  (:wat::core::f64::- cl o))
```

Construction and extraction are symmetric: **let to name values on both sides of the struct**.

### The `::` vs `/` convention

- `::` navigates into a namespace-like path — `:wat::algebra`, `:rust::lru::LruCache`, `:wat::std::program::Console`, `:my::ns::T`.
- `/` attaches a function to the thing at the end of a path — `Console/out`, `Cache/loop`, `HandlePool::new` (the Rust-deps exception because it mirrors Rust's own `::`), and now `T/new` / `T/<field>`.

Reads cleanly: "call this func ON that thing."

### User-defined methods on a struct type

The FOUNDATION framing — "functions on the struct type" — still applies. Users write their own functions that take a struct-typed parameter and use the auto-generated accessors in the body:

```scheme
(:wat::core::define (:my::market::open-close (c :project::market::Candle) -> :f64)
  (:wat::core::f64::- (:project::market::Candle/open c)
                      (:project::market::Candle/close c)))
```

These are ordinary `define`s. No new machinery. The compile path (when it lands) collects all functions whose first parameter is `:project::market::Candle` — auto-accessors AND user methods — into one `impl Candle { ... }` Rust block. No distinction at the wat level.

### Runtime representation

At the Rust layer, struct instances live as `Value::Struct(Arc<StructValue>)` with:

```rust
struct StructValue {
    type_name: String,       // ":my::ns::T"
    fields: Vec<Value>,      // positional, in declaration order
}
```

Two internal primitives back the auto-generated functions:

- `:wat::core::struct-new <type-name> <v1> <v2> ...` → `Value::Struct`
- `:wat::core::struct-field <struct-value> <index>` → the field value at position `index`

Users do not call these directly. Every `<struct>/new` body expands to a `struct-new` call with the type name baked in; every `<struct>/<field>` body expands to `struct-field` with the field's position baked in.

### Self-trust bootstrap

wat-rs's own `:wat::*` type declarations — currently `:wat::holon::CapacityExceeded` (per 058-003 inscription), future additions as the algebra grows — land via `TypeEnv::with_builtins()`, an implementation-level bypass of the reserved-prefix check. wat-rs is the layer that DEFINES `:wat::*`, so it needs a privileged path to declare its own types without pretending to be user code. User source continues to flow through `register_types` where the reserved-prefix gate applies. Two paths: one for us, one for user code. Same pattern `CheckEnv::with_builtins` already uses for built-in function schemes.

### What this inscription does NOT add

- **Struct pattern-matching in `match`.** Not in this slice. Users destructure via let+accessors for now.
- **Named-argument construction `(:my::ns::T (open 1.0) (high 2.0) ...)`.** Not in this slice. Positional constructor only; let-bindings at the call site carry the naming discipline.
- **Field-by-name bare-keyword dispatch `(:cost e)`.** The prior-art pseudo-lang in `holon-lab-trading/wat/` used this shape; wat-rs does not. The scoped `(:wat::holon::CapacityExceeded/cost e)` form was chosen instead — FQDN-all-things matches wat-rs's namespace discipline and avoids needing struct-polymorphic dispatch (a rank-1 HM doesn't express it without typeclasses).
- **Full named-struct syntax with field-access-as-method-calls.** The compile path (wat-to-Rust emitting `impl` blocks) is still specced-but-not-built. This inscription implements the INTERPRET path's equivalents; the compile path lands when a real use case demands it.

### Implementation Reference

- wat-rs commit `0e7309a` (2026-04-19) — `Value::Struct`, `StructValue`, the two primitives, `register_struct_methods` auto-synthesis, `TypeEnv::with_builtins`
- `tests/wat_structs.rs` — 9 end-to-end cases covering round-trip, user methods using auto-accessors, heterogeneous fields, survival through function calls, and four check-time refusals

---

## INSCRIPTION — 2026-04-24 — Enum value construction + match pattern syntax pinned

This proposal locked enum DECLARATIONS in 2026-04-18 and noted "polymorphism via enum wrapping" without pinning construction or pattern-match syntax for user enums. Only built-in `:Option<T>` and `:Result<T,E>` shipped with value support — the 2026-04-19 FOUNDATION-CHANGELOG entry called Option "the sole built-in enum." User enums via `(:wat::core::enum)` were declarable but uninstantiable. Wat-rs arc 048 (2026-04-24) closes the gap; this addendum captures what shipped.

### Construction — `:Enum::Variant`, mirrors Rust

**Unit variant** — bare keyword evaluates directly to the variant value:

```scheme
(:wat::core::enum :trading::types::PhaseLabel :Valley :Peak :Transition)

(:wat::core::define (:my::current -> :trading::types::PhaseLabel)
  :trading::types::PhaseLabel::Valley)
```

The keyword `:Enum::Variant` resolves through a substrate-side `unit_variants` map populated at startup; eval returns `Value::Enum { type_path, variant_name, fields: [] }` directly. Mirrors `:None`'s shortcut.

**Tagged variant** — invocation form, fields positional:

```scheme
(:wat::core::enum :my::market::Event
  (Candle  (open :f64) (close :f64))
  (Deposit (amount :f64))
  :Nothing)

(:wat::core::define (:my::an-event -> :my::market::Event)
  (:my::market::Event::Candle 100.0 105.0))
```

Each tagged variant gets an auto-synthesized `Function` entry at keyword path `:Enum::Variant` whose body is `(:wat::core::variant :Enum :Variant p1 p2 ... pn)`. The internal `:wat::core::variant` primitive is never user-facing — same role as `:wat::core::struct-new`.

The `::` separator is canonical Rust namespace syntax (`MyEnum::Variant`); embodying the host language. Variants are PascalCase, matching Rust convention + built-in `Some`/`None`/`Ok`/`Err`.

### Pattern matching — `:wat::core::match` extended

Match generalizes from Option/Result to user enums uniformly:

```scheme
(:wat::core::define
  (:my::summary (e :my::market::Event) -> :String)
  (:wat::core::match e -> :String
    ((:my::market::Event::Candle  o c)  (:wat::core::f64::to-string c))
    ((:my::market::Event::Deposit amt)  "deposit")
    (:my::market::Event::Nothing        "nothing")))
```

- Tagged-variant arm: `((:Enum::Variant binder1 binder2 ...) body)` — head is the full-path constructor; positional binders bind to the variant's fields, scoped to the body.
- Unit-variant arm: `(:Enum::Variant body)` — bare keyword pattern, no binders.
- Wildcard `_` covers any remaining variants.

The match expression's TYPE is the unified type of all arm bodies (declared via `-> :T` after the scrutinee), NOT the scrutinee's enum type.

The type checker enforces:
- **Exhaustiveness**: every variant of the scrutinee's enum must be covered (or include a `_` arm). The diagnostic names exactly which variants are uncovered.
- **Variant belongs to scrutinee enum**: pattern `(:OtherEnum::X ...)` on a `:Enum`-typed scrutinee errors clearly.
- **Binder arity**: tagged-variant arms must provide one binder per declared field.
- **Tagged-vs-unit shape**: a unit-variant pattern on a tagged variant (or vice versa) errors clearly.

### Runtime representation

At the Rust layer, user-enum instances live as `Value::Enum(Arc<EnumValue>)` with:

```rust
struct EnumValue {
    type_path: String,       // ":trading::types::PhaseLabel"
    variant_name: String,    // "Valley"
    fields: Vec<Value>,      // empty for unit variants; positional for tagged
}
```

One generic `Value::Enum` variant covers every user-declared enum. Built-in `:Option<T>` (`Value::Option`) and `:Result<T,E>` (`Value::Result`) keep their dedicated variants — substantial sweep cost to migrate them with no semantic gain. **Two representations coexist by design.**

### What this inscription does NOT add

- **Variants with named fields** (Rust's struct-style variants `MyEnum::V { x: u32 }`). 058-030's grammar uses tuple-style only; arc 048 ships positional construction. Add when a caller surfaces.
- **Generic user enums.** Only `:Option<T>` and `:Result<T,E>` are parametric; user enums are monomorphic. Open its own arc if needed.
- **Migrating Option/Result to `Value::Enum`.** Two representations coexist (same as Tuple-vs-Vec accessor split).
- **Enum-value introspection** (`(:enum-of value)` to recover the type). Add only if a real caller needs it.

### Implementation Reference

- wat-rs commit (2026-04-24) — `Value::Enum`, `EnumValue`, `:wat::core::variant` primitive, `register_enum_methods` auto-synthesis, `SymbolTable.unit_variants`, `CheckEnv.unit_variant_types`, match-pattern + exhaustiveness extensions for `MatchShape::Enum`
- `tests/wat_user_enums.rs` — 8 end-to-end cases covering unit + tagged construction, mixed match arms, exhaustiveness diagnostics, cross-enum rejection, arity mismatch, and tagged-vs-unit shape mismatch

---

## The Candidate

A **keyword-path-based type system** for the wat language, providing:

1. A small set of **built-in types** for the primitives the algebra exposes.
2. A **parametric type constructor** for containers (`:Vec<T>`, `:HashMap<K,V>`, `:fn(T,U)->R`).
3. **User-definable types** via keyword-path naming discipline (`:my::namespace::MyType`), through FOUR compile-time forms with distinct head keywords: `newtype`, `struct`, `enum`, `typealias`.
4. **Static type checking** at wat-vm startup — signatures of `define` and call sites must match before the main loop runs.

**No `deftype`. No `:is-a`. No `subtype`. No `impl`. No `trait`.** Four type-declaration heads, each unambiguous. Polymorphism for user types uses enums (closed variant set, like `:wat::holon::HolonAST`) or explicit per-type functions. Rust's compiled output groups wat function declarations into `impl` blocks automatically — the user writes functions, the compiler emits the impls.

### Built-in types

The type system has two tiers of built-ins: **algebraic types** (abstractions over VSA roles) and **Rust primitive types** (direct mappings to Rust's concrete types).

**Algebraic types:**

```
:wat::holon::HolonAST    — the algebra's AST type, declared as an enum with 6 variants
:Vector   — a raw encoded ternary vector in `{-1, 0, +1}^d` (post-encode form)
:AST      — a parsed source AST (for macro parameters; see 058-031-defmacro)
```

**`:wat::holon::HolonAST` is an enum, not a subtype root.** This matches the underlying Rust `HolonAST` enum exactly. Declared in FOUNDATION as:

```scheme
(:wat::core::enum :wat::holon::Holon
  (Atom        (payload :T))                                            ;; parametric per 058-001
  (Bind        (a :wat::holon::HolonAST) (b :wat::holon::HolonAST))
  (Bundle      (items :Vec<wat::holon::HolonAST>))
  (Permute     (child :wat::holon::HolonAST) (k :i32))
  (Thermometer (value :f64) (min :f64) (max :f64))
  (Blend       (a :wat::holon::HolonAST) (b :wat::holon::HolonAST) (w1 :f64) (w2 :f64)))
```

Six variants — the algebra core. `Orthogonalize`, `Resonance`, and `ConditionalBind` are NOT variants of `:wat::holon::HolonAST`: Orthogonalize (058-005) migrated to stdlib as `Reject` + `Project` macros over `Blend` + `:wat::holon::dot`; Resonance (058-006) and ConditionalBind (058-007) were rejected as speculative primitives with no production use. See their PROPOSAL.md REJECTED banners and FOUNDATION-CHANGELOG for the record.

Every algebra AST node is a **variant** of the `:wat::holon::HolonAST` enum. A function typed `(f (h :wat::holon::HolonAST) -> ...)` accepts any variant and pattern-matches to select behavior:

```scheme
(:wat::core::define (:wat::std::atom-value (h :wat::holon::HolonAST) -> :AtomLiteral)
  (:wat::core::match h
    ((Atom literal)  literal)
    (_               (error "atom-value: not an Atom variant"))))
```

No `:Atom`-as-subtype-of-`:wat::holon::HolonAST` — `Atom` is just a variant name used in `match`. No `:is-a` relationship. Same semantics as Rust's `match holon { HolonAST::Atom(lit) => ... }`.

**Note on `:Cleanup`:** REJECTED as a core form (see 058-025). Retrieval is presence measurement (cosine + noise floor), not argmax-over-codebook. No `:Cleanup` variant exists in the Holon enum.


**Rust primitive types** (mapped directly to Rust):

```
;; Integers — Rust's standard integer types:
:i8  :i16  :i32  :i64  :i128  :isize
:u8  :u16  :u32  :u64  :u128  :usize

;; Floating point:
:f32  :f64

;; Other primitives:
:bool        — true / false
:char        — Unicode scalar value
:&str        — string slice
:String      — owned string
:()          — unit (nothing)
```

**Meta types:**

```
:wat::core::keyword     — keyword literal (e.g., :foo, :foo::bar::baz)
:Type        — a type-name value (types as first-class keywords)
```

**NO `:Any`.** `:Any` would be an escape hatch ("I refuse to declare a type") — easy, not simple. Every apparent use case has a principled replacement:

- Universal algebra value → `:wat::holon::HolonAST`
- Heterogeneous data → **declare a named `:wat::core::enum`** with named variants. Every coproduct carries a discriminator; dispatch is explicit. Matches Rust exactly (Rust has no anonymous union type).
- Generic container element → parametric type parameter (`T`, `K`, `V`)
- `eval`'s return → `:fn(:wat::holon::HolonAST)->Holon` or parametric `:fn(:wat::holon::HolonAST)->T`
- Engram library entries → `:Vec<(Holon,Vector)>` (tuple-literal type)

If a programmer can't declare the type of their value, that is a design signal that the function hasn't been fully specified. The type system is the forcing function.

**NO `:Scalar` / `:Int` / `:Bool` / `:Null` abstractions.** Use the concrete Rust types directly. Blend's weights are `:f64`. Permute's step count is `:i32` or `:usize`. `nth`'s index is `:usize`. Booleans are `:bool`. The unit value is `:()`. Absence is `:Option<T>`, never null.

**NO null.** Rust doesn't have null; wat doesn't have null. `:Option<T>` is an enum with variants `:None` and `(Some value)` for optional values. `:()` (the unit type) represents "no meaningful return." Structural absence — a `when` that didn't fire, a branch that wasn't taken, a field that doesn't exist in a variant — is expressed by the form simply not being present. Atom literals are string, int, float, bool, keyword — no null.


### Parametric types

Parametric types use Rust-surface syntax as single-token keywords:

```
:Vec<wat::holon::HolonAST>                   ; Rust Vec<wat::holon::HolonAST>
:Vec<f64>                     ; Rust Vec<f64>
:Vec<Vec<wat::holon::HolonAST>>              ; nested Vec (lists of lists)
:Vec<u8>                      ; Rust Vec<u8> — byte buffer
:HashMap<K,V>                 ; Rust HashMap<K, V>
:HashSet<T>                   ; Rust HashSet<T>
:Option<wat::holon::HolonAST>                ; Rust Option<wat::holon::HolonAST>
:Result<wat::holon::HolonAST,Error>          ; Rust Result<wat::holon::HolonAST, Error>
:(Holon,Vector)               ; Rust tuple — 2-tuple
:(T,U,V)                      ; Rust tuple — 3-tuple
:Arc<wat::holon::HolonAST>                   ; Rust Arc<wat::holon::HolonAST>
```

**Coproducts use named enums.** Anonymous `:Union<T,U,V>` was considered and retired 2026-04-19 — Rust has no anonymous union type. Heterogeneous data is expressed with `(:wat::core::enum :my::Name ...)` declarations; every variant carries a named discriminator.

Function types mirror Rust's `fn(T, U) -> R` exactly:

```
:fn(Holon,Holon)->Holon              ; binary Holon → Holon
:fn(f64)->f64                        ; unary f64 → f64
:fn(Atom)->Holon                     ; Atom → Holon
:fn(Holon,wat::holon::HolonAST,f64,f64)->Holon      ; Blend's type
:fn()->Holon                         ; nullary
:fn(T)->T                            ; identity on T
:fn(Vec<T>,fn(T)->U)->Vec<U>         ; map's type
```

Arguments between the parens, return after `->`. Direct one-to-one correspondence with Rust's syntax.

### The tokenizer rule

`:` is **wat's symbol-literal reader macro** — one leading `:` marks the start of a symbol; the body that follows is a literal Rust path. Inside a keyword:
- NO internal whitespace (whitespace ends the keyword at paren-depth 0).
- Internal `::` is Rust's path separator — body characters, not special. `:wat::core::load!` is a single keyword.
- Every other character belongs to the keyword — `<`, `>`, `/`, `(`, `)`, `,`, `-`, `!`, `?`, letters, digits. These are plain chars; none has special tokenizer meaning except `(` and `)`.
- The tokenizer tracks PAREN depth only (because `(` and `)` can appear inside a keyword — as in `:fn(T,U)->R` or `:(i64,String)` — and the lexer must distinguish an internal matched pair from the outer `)` that closes the enclosing form).
- A keyword ends at whitespace at paren-depth 0, at an unmatched `)`, or at a `"` / `;`.
- `[]` and `{}` are NOT wat syntax; `<` and `>` are plain chars inside parametric type keywords like `:Vec<T>`.

Nested generics compose:

```
:HashMap<String,fn(i32)->i32>
:Result<HashMap<Atom,wat::holon::HolonAST>,String>
:fn(Vec<i32>)->Option<f64>
:Option<HashMap<Atom,Vec<wat::holon::HolonAST>>>
```

All single tokens. Each is a hashable string. The type-aware hash (058-001) applies at the whole-keyword granularity.

### Rust-mapping is direct

```
wat keyword                                    Rust
─────────────────────────────                  ──────────────────────────
:HashMap<K,V>                                  HashMap<K, V>
:Vec<T>                                       Vec<T>
:Option<T>                                     Option<T>
:Result<T,E>                                   Result<T, E>
:fn(T,U)->R                                    fn(T, U) -> R
:fn(List<i32>)->Option<f64>                    fn(Vec<i32>) -> Option<f64>
:HashMap<String,fn(i32)->i32>                  HashMap<String, fn(i32) -> i32>
:Union<T,U>                                    enum { T(T), U(U) }   (or Either<T,U>)
:(T,U)                                     (T, U)
```

The compiler strips the `:`, inserts spaces after commas, and emits Rust. Translation is string rewriting. No AST walk, no canonicalization pass — the keyword IS the type.

### User-definable types — four forms, four distinct heads

Users declare types using FOUR compile-time forms, each with a distinct head keyword and a distinct semantic. No ambiguity at parse time — the head tells you what operation is being declared.

```scheme
;; --- 1. newtype: nominal wrapper with distinct identity ---
;; Compiles to Rust: `struct Name(Inner);`
;; NOT substitutable for its inner type — explicit conversion required.

(:wat::core::newtype :project::trading::Price   :f64)
(:wat::core::newtype :project::trading::TradeId :u64)

;; --- 2. struct: named product type with typed fields ---
;; Compiles to Rust: `struct Name { field: Type, ... }`

(:wat::core::struct :project::market::Candle
  (open   :f64)
  (high   :f64)
  (low    :f64)
  (close  :f64)
  (volume :f64))

;; --- 3. enum: coproduct type with named variants ---
;; Compiles to Rust: `enum Name { Variant, Variant(Fields), ... }`
;; Variants are unit (no payload) or tagged (with typed fields).

(:wat::core::enum :project::trading::Direction :long :short)

(:wat::core::enum :project::market::Event
  (candle  (asset :Atom) (candle :project::market::Candle))
  (deposit (asset :Atom) (amount :f64)))

;; --- 4. typealias: structural shorthand for an existing type expression ---
;; Compiles to Rust: `type Name = Expr;`
;; :A and its expansion are the SAME type — useful for naming complex shapes.

(:wat::core::typealias :alice::types::Amount         :f64)
(:wat::core::typealias :alice::market::CandleSeries  :Vec<Candle>)
(:wat::core::typealias :alice::trading::Scores       :HashMap<Atom,f64>)
```

All four forms use keyword-path names for namespacing (discipline, not mechanism). They materialize into the Rust-backed wat-vm binary at build time; they cannot be redefined at runtime.

**Four distinct semantics, four distinct heads, zero ambiguity:**

| Form | Head | Rust compilation | Substitutable for inner? |
|---|---|---|---|
| `(newtype :A :B)` | `newtype` | `struct A(B);` | **No** — distinct nominal type |
| `(struct :A ...)` | `struct` | `struct A { ... }` | N/A (new product type) |
| `(enum :A ...)` | `enum` | `enum A { ... }` | N/A (new coproduct type) |
| `(typealias :A :B)` | `typealias` | `type A = B;` | **Yes** — same type, alternative name |

Users pick based on what they mean: distinct nominal wrapper (`newtype`), new product (`struct`), new coproduct (`enum`), alternative name for an existing type (`typealias`).

### Polymorphism — enums, not traits

"A function that works on multiple types" is expressed via **enum wrapping**, not via traits or subtype declarations. Example: a function that handles both `Candle` and `BullishCandle`:

```scheme
(:wat::core::enum :alice::market::Candleish
  (Regular  (c :project::market::Candle))
  (Bullish  (c :alice::market::BullishCandle)))

(:wat::core::define (:alice::market::analyze (c :Candleish) -> :Signal)
  (:wat::core::match c
    ((Regular candle)   ...)
    ((Bullish candle)   ...)))
```

The set of types the function accepts is **closed** at the enum declaration. Callers wrap their value in a variant. The function pattern-matches. Same pattern as `:wat::holon::HolonAST` uses for its 9 AST variants.

Alternatively, write per-type functions with distinct names:

```scheme
(:wat::core::define (:alice::market::analyze-candle   (c :Candle)         -> :Signal) ...)
(:wat::core::define (:alice::market::analyze-bullish  (c :BullishCandle)  -> :Signal) ...)
```

No polymorphism needed — the caller picks which function to invoke. Simple, Rust-honest.

### No `impl` in wat source — the function IS the impl

Rust groups methods under `impl Type { ... }` blocks. But wat's function declarations already carry the type information — `(define (name (arg :Candle) -> ...) body)` names `Candle` in its signature. The `impl` block is an artifact of Rust syntax, not something the wat author needs to write.

**The compiler generates Rust `impl` blocks from wat function declarations.** All `(define (... (c :Candle) ...) ...)` functions in the source get collected at compile time into one `impl Candle { ... }` block per crate. Automatic. The user writes functions; Rust gets the impls.

```scheme
;; wat source:
(:wat::core::define (:my::market::open     (c :Candle) -> :f64) body1)
(:wat::core::define (:my::market::high     (c :Candle) -> :f64) body2)
(:wat::core::define (:my::market::low      (c :Candle) -> :f64) body3)
(:wat::core::define (:my::market::close    (c :Candle) -> :f64) body4)

;; Compiler generates:
;;   impl Candle {
;;     pub fn open(&self)  -> f64 { ... }
;;     pub fn high(&self)  -> f64 { ... }
;;     pub fn low(&self)   -> f64 { ... }
;;     pub fn close(&self) -> f64 { ... }
;;   }
```

No `impl` keyword in wat. No `trait` keyword in wat. The function's typed signature carries everything Rust needs.

### No Nominal Subtyping — Enum Variants Instead

The wat type system has no nominal subtype relation (no `:A :is-a :B` keyword, no subtype declarations). This matches Rust exactly. The "every Atom is a Holon" relationship is expressed through the **Holon enum** — `Atom` is a variant of the `:wat::holon::HolonAST` enum, not a separate type that's a subtype of it.

```scheme
;; Pattern-matching extracts the variant:
(:wat::core::define (:my::app::encode (h :wat::holon::HolonAST) -> :Vector)
  (:wat::core::match h
    ((Atom payload)         ...)
    ((Bind a b)             ...)
    ((Bundle items)         ...)
    ((Permute child k)      ...)
    ((Thermometer v mn mx)  ...)
    ((Blend a b w1 w2)      ...)))
```

Same semantics as Rust's `match holon { HolonAST::Atom(lit) => ..., ... }`. Exhaustive. Compiler-verified. No runtime dispatch overhead.

**No built-in subtyping between Rust primitive types either.** `:i32` is NOT substitutable for `:i64`; `:f32` is NOT substitutable for `:f64`. Matches Rust's strictness — explicit coercion required (e.g., `(as-f64 int-value)`). Prevents silent precision loss.

**No user-defined subtyping.** If a user wants one struct to be usable where another struct is expected, they define an enum wrapping both variants (closed set; pattern-matched) OR write per-type functions with distinct names. Rust has no nominal subtyping; neither does wat.

### Variance Rules — Only Where Matters

Without nominal subtyping, most variance questions dissolve. Primitive types are invariant (`:i32` is `:i32`). User-declared types are invariant (`:Candle` is `:Candle`). Parametric containers are invariant by default (`:Vec<Candle>` is `:Vec<Candle>`).

The one case that still needs variance is **function types** — because Rust itself handles this for function pointers and closures. The rule is Liskov-standard:

**`:fn(args)->return` — contravariant in args, covariant in return.**

Concretely: a function is substitutable for another function if it accepts the same or BROADER inputs and returns the same or NARROWER outputs. In practice, with no nominal subtyping, this rule is rarely exercised — it exists for Rust closure types and for the edge cases the Rust compiler already handles.

**Parametric containers (`:Vec<T>`, `:HashMap<K,V>`, `:Vec<T>`, `:Option<T>`, `:Result<T,E>`, `:HashSet<T>`, `:(T,U)`) are invariant** — matches Rust's strictness for mutable containers. `:Vec<i32>` is `:Vec<i32>`, not interchangeable with `:Vec<i64>`. Explicit conversion required.

This is a simpler variance story than the previous `:is-a`-driven covariance rules, because the source of subtyping complexity (user-declared subtypes) is gone.

### Type annotations on `define` and `lambda`

From 058-028-define and 058-029-lambda, type annotations are required. The return type goes INSIDE the signature parens using `->`:

```scheme
(:wat::core::define (:my::ns::amplify (x :wat::holon::HolonAST) (y :wat::holon::HolonAST) (s :f64) -> :wat::holon::HolonAST)
  (:wat::holon::Blend x y 1 s))

(:wat::core::lambda ((t :wat::holon::HolonAST) -> :wat::holon::HolonAST)
  (:wat::holon::Permute t 1))

;; Matches Rust's fn name(args) -> ReturnType:
;;   fn amplify(x: Holon, y: Holon, s: f64) -> Holon { ... }
```

Each parameter uses `(name :Type)` — parenthesized sublist with a bare symbol name and a keyword type. The return type follows `->` at the end of the signature (all inside one set of parens). No dangling `: Type` outside the form. The body must produce a value of the return type, checked at startup.

**Macros use the same signature syntax as `define` and `lambda`** — every parameter is explicitly typed `: AST`; return is explicitly `-> :AST`. One consistent signature form across all three definition primitives. No implicit rules for the reader to remember.

```scheme
(:wat::core::defmacro (:wat::holon::Subtract (x :AST) (y :AST) -> :AST)
  `(:wat::holon::Blend ,x ,y 1 -1))
;; parameters and return are explicitly typed.
;; type-correctness of the EXPANSION is enforced by type-checking the expanded form
;; against the signatures of its constituent primitives (Blend, etc.).
```

Macro parameters carry ASTs (unevaluated source), so their type is always `:AST`. The return is always `:AST` (the expansion is a syntactic form). Stating this explicitly is simpler — one signature syntax across define/lambda/defmacro — than the easy shortcut of omission.

## Why This Earns Language-Core Status

**1. The Rust-backed wat-vm requires types for startup verification.**

Under Model A (fully static loading), the wat-vm verifies all code at startup before the main loop runs. When the verifier processes a `define`, it needs to know:

- What kind of value each argument is (Holon? Scalar? Integer? List?)
- What kind of value the function returns
- Whether the body produces a value of the declared return type

Without type annotations, the verifier would need to either infer types at every call site (slower, more fragile) or defer all type checks to runtime (undermines the static-verification guarantee).

With type annotations, verification is deterministic, complete, and happens once at startup. Runtime dispatch is a simple argument-type check against the known signature.

**2. Signatures are part of cryptographic provenance.**

Per FOUNDATION's "Cryptographic provenance" section, ASTs are signed. A `define`'s signature (parameter types + return type) is part of its EDN. Tampering with either signature or body breaks the hash. A signed function can be TRUSTED not just in its body but in its CONTRACT — a call site that matches the parameter types will get a return value of the declared return type.

**3. Types enable static verification of stdlib compositions.**

```scheme
(:wat::core::define (:wat::std::Chain (holons :Vec<wat::holon::HolonAST>) -> :wat::holon::HolonAST)
  (:wat::holon::Bundle (pairwise-map :wat::std::Then holons)))
```

The startup verifier can check:
- `holons` has type `:Vec<wat::holon::HolonAST>`
- `pairwise-map` returns `:Vec<wat::holon::HolonAST>` given `:wat::std::Then` (of type `:fn(Holon,Holon)->Holon`) and a `:Vec<wat::holon::HolonAST>`
- `Bundle` takes `:Vec<wat::holon::HolonAST>` and returns `:wat::holon::HolonAST`
- Body returns `:wat::holon::HolonAST`, matching the declared return

Without types, these checks defer to runtime or never happen. With types, stdlib correctness is mechanically verifiable at startup.

**4. Extension via user-defined types.**

Users author their own types with the same naming discipline as functions. `:alice::types::Price`, `:project::market::Candle`. The type system is open — any user can add types, and collisions are prevented by the keyword-path discipline plus startup verification (two structs with the same keyword-path name in the compile-time sources is a build error).

User types are usable anywhere built-in types are used:

```scheme
(:wat::core::define (:my::trading::analyze (c :project::market::Candle) -> :wat::holon::HolonAST)
  (:wat::holon::Sequential
    (:wat::core::vec (:wat::holon::Thermometer (:close c) 0 100)
          (:wat::holon::Thermometer (:volume c) 0 10000))))
```

## Arguments For

**1. Small, well-scoped type set.**

The built-in types correspond to the algebra's actual kinds. There is no speculative hierarchy — just the types the primitives actually produce and consume. Twelve built-ins, each corresponding to a concrete runtime kind.

**2. Keyword-path types match the naming discipline.**

Just as functions are keywords (`:wat::std::Difference`), user types are keywords (`:alice::types::Price`, `:project::market::Candle`). Same naming mechanism, same namespace discipline. Users learn one convention, use it everywhere.

Built-in types use shorthand within their own namespace: `:wat::holon::HolonAST` is shorthand for `:wat/types/Holon` when context makes it unambiguous.

**3. Parametric types handle the essential cases.**

Generics (`:Vec<T>`, `:HashMap<K,V>`, `:fn(args)->return`) cover the recurring need for higher-order stdlib and container operations. More elaborate generics (bounds, existentials, higher-kinded types) are out of scope — the target is "enough type system to dispatch correctly and map cleanly to Rust," not a full algebraic type theory.

**4. Structural typing for structural aliases; nominal for struct/enum/newtype.**

- `(typealias :CandleScores :HashMap<Atom,f64>)` is a structural alias, not a nominal type. `:CandleScores` and `:HashMap<Atom,f64>` are THE SAME type — interchangeable in signatures. Useful for "some shape that I'm naming."
- `(struct :project::market::Candle ...)` is nominal. A value is a Candle if and only if it was constructed as one. Distinct from other structs with identical fields.
- `(enum :Direction ...)` is nominal. Only values constructed via the enum's constructors inhabit the type.
- `(newtype :TradeId :u64)` is nominal. A `:TradeId` is NOT a `:u64` even though they share representation.

This matches how VSA-based data structures are used — nominal types protect semantics; structural aliases provide shorthand.

## Arguments Against

**1. Any type system adds complexity to the wat-vm.**

Without types, the verifier is simpler. With types, the wat-vm needs:
- Type environment (table of known types)
- Type inference (for literals and expression results)
- Type checking (signature vs. call-site matching)
- Generic resolution (for parametric types)

**Counter:** the complexity pays for itself — errors caught at startup instead of runtime, dispatch without probing, signatures that can be signed. The simpler untyped verifier is faster to implement but fragile in operation. Model A NEEDS types; this is not optional.

**2. Structural typing vs. nominal typing — mixed policy.**

Having `struct`/`enum`/`newtype` be nominal but `typealias` be structural may confuse readers. Why the asymmetry?

**Counter:** nominal identity matters for struct/enum/newtype — they're NEW types with their own semantics. Structural equivalence matters for `typealias` — it's an alternative NAME for an EXISTING shape. The two categories serve different needs; four distinct head keywords make the distinction unmissable at parse time.

**3. Type inference scope.**

This proposal REQUIRES explicit types on `define` and `lambda` parameters. Some languages infer these from usage. Scheme and Clojure are traditionally untyped; Haskell and F# infer aggressively; Rust infers locally.

**Counter:** explicit types on function boundaries are the Model A contract. Local inference (within function bodies, for intermediate values) IS supported — the verifier can infer that `(Blend a b 1 -1)` returns `:wat::holon::HolonAST` from Blend's signature. Function boundary types are required; internal types are derived. This matches Rust's approach.

**4. Generics complexity.**

Parametric types need generic resolution: when `map` receives a `:Vec<wat::holon::HolonAST>` and a `:fn(Holon)->f64`, the result is `:Vec<f64>` (the function's return type substituted for `T`). This is basic unification.

**Counter:** yes, but bounded. The wat language doesn't need variance, higher-kinded types, or other advanced features. Simple substitution suffices for the stdlib's needs.

**5. Heterogeneous data without `:Any`.**

Some applications genuinely have heterogeneous data — a list of mixed primitives, a dispatch table over variant types. Without `:Any`, how do these get typed?

**Counter:** use `:Union<T,U,V>` for closed heterogeneous sets, enums for named variant types, parametric types for generic containers. Every case that ever wanted `:Any` has a principled named alternative. The type system's benefit (static verification) depends on closure of the type universe — no escape hatch.

## Type Checking Semantics (Model A)

### Static check at startup

When the wat-vm boots, it processes all loaded files in order. For each `define`:

1. Parse the parameter list — each must be `(name :Type)`
2. Parse the return type — must be a well-formed type in the type environment
3. Type-check the body — every sub-expression must produce a type compatible with its usage
4. Verify the body's final expression matches the declared return type

Errors at this stage prevent the wat-vm from starting. No partial-state recovery.

### Dynamic check at call site (fast path)

When a call site is evaluated at runtime:

1. Look up the function by name in the static symbol table
2. Each argument's type must be a subtype/alias of the corresponding parameter type
3. If match, bind parameters, evaluate body, return result

If types matched at startup verification, the body is guaranteed to return the declared type — no per-call return check needed. The argument-type check at the call site guards against user data misuse (e.g., an `:f64` passed where a `:wat::holon::HolonAST` is expected).

### Primitive dispatch

Primitives like `Bundle` are built into the wat-vm with their signatures hardcoded:

```
Bundle:      :fn(:Vec<wat::holon::HolonAST>)->Holon
Bind:        :fn(Holon,Holon)->Holon
Blend:       :fn(Holon,wat::holon::HolonAST,f64,f64)->Holon
Permute:     :fn(Holon,i32)->Holon
Atom:        :fn(AtomLiteral)->Atom           ; AtomLiteral is a Union of permitted literal types
Thermometer: :fn(f64,f64,f64)->Holon
```

Where `:AtomLiteral` is an internally-defined Union type covering the permitted atom literals (see 058-001):

```
(typealias :AtomLiteral :Union<String,i32,f64,bool,wat::core::keyword>)
```

Stdlib `define`s compose these primitives; their types derive from the primitives' signatures via substitution.

### Constrained eval

Per FOUNDATION's "Constrained eval at runtime," `eval` can evaluate a dynamically-constructed AST as long as every function and type referenced is in the static universe. The type checker runs on the AST before execution:

- Every keyword-path reference must resolve to a known function or type.
- Every argument's type must match the called function's signature.
- Failures error before any body executes.

This gives safe runtime evaluation over a fixed, verified type/function universe.

## Implementation Scope

**wat-vm changes:**

Add type AST:

```rust
pub enum TypeAST {
    Named(Keyword),                          // :wat::holon::HolonAST, :f64, :alice::types::Price
    Parametric {                             // :Vec<wat::holon::HolonAST>, :HashMap<K,V>
        constructor: Keyword,
        args: Vec<TypeAST>,
    },
    Function {                               // :fn(T,U)->R
        args: Vec<TypeAST>,
        ret: Box<TypeAST>,
    },
    Union(Vec<TypeAST>),                     // :Union<T,U,V>
    Var(Keyword),                            // lexically-scoped type variable T, K, V
}
```

No `Any` variant. The type grammar is closed; the enum enumerates exactly the forms the language admits.

Type environment (frozen after startup):

```rust
pub struct TypeEnv {
    builtins: HashMap<wat::core::keyword, TypeDef>,     // :wat::holon::HolonAST, :Atom, etc.
    user_types: HashMap<wat::core::keyword, TypeDef>,   // struct, enum, newtype, typealias registrations
}

pub enum TypeDef {
    Builtin(BuiltinType),
    Struct(StructDef),
    Enum(EnumDef),
    Newtype(NewtypeDef),
    Alias(AliasDef),            // typealias
}
```

Type checker:

```rust
pub fn check_subtype(actual: &TypeAST, expected: &TypeAST, env: &TypeEnv) -> Result<(), TypeError> {
    // Named types must match (through typealias expansion; no :is-a hierarchy — no nominal subtyping)
    // Parametric types unify per argument, honoring variance
    // Function types unify contravariantly in args, covariantly in return
    // Union types: actual must match at least one expected variant; expected-as-union accepts any matching variant
    // Type variables bind during unification, checked for consistency
}

pub fn infer_expr(expr: &WatAST, env: &TypeEnv, locals: &Locals, table: &SymbolTable) -> Result<TypeAST, TypeError> {
    match expr {
        WatAST::Literal(lit) => Ok(literal_type(lit)),
        WatAST::Call { name, args } => {
            let f = table.lookup(name).ok_or(TypeError::UnknownFunction(name.clone()))?;
            for (arg, param) in args.iter().zip(&f.params) {
                let arg_type = infer_expr(arg, env, locals, table)?;
                check_subtype(&arg_type, &param.1, env)?;
            }
            Ok(f.return_type.clone())
        },
        // ... other AST variants
    }
}
```

Estimated ~500-800 lines of Rust for:
- TypeAST parsing / serialization
- TypeEnv with builtins
- Subtype checking with generic unification
- Static verification of `define` bodies at startup
- Runtime dispatch with type guard on arguments
- Type-checking for constrained eval

**`struct`, `enum`, `newtype`, `typealias` forms:**

New language-core forms (alongside `define` and `lambda`), all compile-time-registering. Build pipeline extracts them from wat files loaded via `(:wat::core::load! ...)`, generates Rust code, compiles. See FOUNDATION's "All loading happens at startup" section for the pipeline description.

## Questions for Designers

1. **Generics scope.** — **RESOLVED 2026-04-18 to YES on parametric polymorphism across the board.** The language ships parametric user types (`struct`/`enum`/`newtype`/`typealias` all accept type parameters), parametric functions (type variables in signatures), and parametric `Atom<T>` as substrate. Reasoning in FOUNDATION-CHANGELOG 2026-04-18 entry "Parametric polymorphism as substrate — programs ARE atoms, which demands it." The "start minimal" recommendation in the original draft is reversed: parametric Atom is load-bearing for the programs-as-holons principle (058-001), and you cannot have parametric Atom without the type system that expresses it. Higher-kinded types and type bounds (`T: Trait`) remain deferred — add when stdlib needs emerge. First-order parametric polymorphism (rank-1) is the commit.

2. **Type inference strength — RESOLVED 2026-04-19: required typed let bindings.** Parameter types on `define`/`lambda` are required. Let bindings are also required to declare their type explicitly: every binding is `((name :Type) rhs)` with no untyped form. The "infer intermediates; allow optional annotation" recommendation in the original draft was reversed after wat-rs slice 7b made the trade-off visible — anonymous functions must declare their constraints, and the discipline is cleanest when it applies uniformly to every named binding. No wiggle room: if you name a value in a let, you declare its type. See FOUNDATION-CHANGELOG 2026-04-19 "Typed-let discipline — every binding declares its type" for full reasoning.

3. **Nominal vs. structural typing.** Proposal uses nominal for struct/enum/newtype and structural for typealias. Is this the right split? Recommendation: yes — nominal protects semantics, structural provides shorthand. Four distinct head keywords make the distinction visible at parse time.

4. **`:Any` removed from grammar.** Resolved. `:Any` is not part of the type system. Use `:wat::holon::HolonAST` for any algebra value, `:Union<T,U,...>` for closed heterogeneous sets, parametric `T`/`K`/`V` for generics. The type universe is closed — no escape hatch — which is what makes startup verification total.

5. **Type promotion rules.** If a function takes `:f64` and you pass an `:i32`, does it auto-promote? Recommendation: no implicit promotion — explicit `(as-f64 int)` or similar. Matches Rust's strictness; prevents surprising behavior.

6. **Error reporting.** Type errors need to point at the offending expression with a useful message. "Expected `:wat::holon::HolonAST`, got `:f64` at line X" is the minimum. Structured error types with source locations are part of the implementation.

7. **Metadata on types.** `typealias` could accept documentation strings, constraints, validators. Worth including in the first version? Recommendation: start simple (just alias); add metadata if needed.

8. **Subtype hierarchy.** Is `:Atom` a subtype of `:wat::holon::HolonAST` (atoms ARE holons in the HolonAST)? Recommendation: yes — every Atom is a Holon. A parameter `:wat::holon::HolonAST` accepts an Atom value. Document the subtype relationships.

9. **Dependency ordering.** Types depend on nothing; `define` and `lambda` depend on types. Resolution order: 058-030 (types) first, then 058-028 (define) and 058-029 (lambda).

10. **First-class types.** Types as keyword values can be passed around. Does this enable type-reflecting code? Probably, though not the focus of this proposal. Example: `(type-of x)` returns the keyword `:wat::holon::HolonAST`. Useful for introspection but out of scope for language core.

11. **Keyword-path in type names with generic parameters — RESOLVED.** Rust-surface angle-bracket keyword syntax, single token, no internal spaces, no internal colons. The `:` is Lisp's quote — one at the start; everything else is inside. `:wat::std::Container<T>` at declaration, `:wat::std::Container<wat::holon::HolonAST>` at use. Function types use `:fn(args)->return` with parens and arrow (Rust's native syntax). The tokenizer tracks PAREN depth only (`()` is the only structural bracket in wat; `<` and `>` are plain chars that appear in parametric type keywords). A keyword ends at whitespace at paren-depth 0 or at an unmatched `)`.
