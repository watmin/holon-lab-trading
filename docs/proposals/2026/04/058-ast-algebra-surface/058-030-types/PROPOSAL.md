# 058-030: Types — The Language Core Type System

**Scope:** language
**Class:** LANGUAGE CORE
**Parent:** 058-ast-algebra-surface
**Foundation:** ../FOUNDATION.md
**Depends on:** 058-001-atom-typed-literals (for atom literal types)
**Companion proposals:** 058-028-define, 058-029-lambda

## The Candidate

A **keyword-path-based type system** for the wat language, providing:

1. A small set of **built-in types** for the primitives the algebra exposes.
2. A **parametric type constructor** for containers (lists of T, functions from T to U).
3. **User-definable types** via keyword-path naming discipline (`:my/namespace/MyType`), through the compile-time forms `struct`, `enum`, `newtype`, and `deftype`.
4. **Static type checking** at wat-vm startup — signatures of `define` and call sites must match before the main loop runs.

### Built-in types

The type system has two tiers of built-ins: **algebraic types** (abstractions over VSA roles) and **Rust primitive types** (direct mappings to Rust's concrete types).

**Algebraic types** (keyword names for VSA roles):

```
:Thought         — any ThoughtAST node
:Atom            — an Atom node specifically (read literal via atom-value)
:Bundle          — a Bundle node (:is-a :Thought)
:Bind            — a Bind node (:is-a :Thought)
:Permute         — a Permute node (:is-a :Thought)
:Thermometer     — a Thermometer node (:is-a :Thought)
:Blend           — a Blend node (:is-a :Thought)
:Orthogonalize   — an Orthogonalize node (:is-a :Thought)
:Resonance       — a Resonance node (:is-a :Thought)
:ConditionalBind — a ConditionalBind node (:is-a :Thought)
:Cleanup         — a Cleanup node (:is-a :Thought)
:Vector          — a raw encoded ternary vector in `{-1, 0, +1}^d` (post-encode form; see FOUNDATION's "Output Space")
:AST             — a parsed source AST (for macro parameters; see 058-031-defmacro)
```

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
:Keyword     — keyword literal (e.g., :foo, :foo/bar/baz)
:Type        — a type-name value (types as first-class keywords)
:Any         — escape hatch; disables static checking for this position
```

No `:Scalar` / `:Int` / `:Bool` / `:Null` abstractions. Use the concrete Rust types directly. Blend's weights are `:f64`. Permute's step count is `:i32` or `:usize`. `nth`'s index is `:usize`. Booleans are `:bool`. The unit value is `:()`.

### Parametric types

Parametric types are expressed as keyword-heads with type arguments:

```scheme
(:List :Thought)                 ; list of thoughts
(:List :f64)                     ; list of f64 values
(:List (:List :Thought))         ; list of lists of thoughts
(:Vec :u8)                       ; Rust Vec<u8> — byte buffer
(:Option :Thought)               ; Option<Thought>
(:Result :Thought :Error)        ; Result<Thought, Error>
(:Arc :Thought)                  ; Arc<Thought>
```

Function types use the `->` separator:

```scheme
(:Function :Thought :Thought -> :Thought)             ; binary Thought → Thought
(:Function :f64 -> :f64)                              ; unary f64 → f64
(:Function :Atom -> :Thought)                         ; Atom → Thought
(:Function :Thought :Thought :f64 :f64 -> :Thought)   ; Blend's type
```

All arguments appear on the left of `->`; the return type is on the right. Single parenthesized form; no dangling return type.

### User-definable types

Users declare types using the compile-time forms `struct`, `enum`, `newtype`, and `deftype` — all with keyword-path names and typed fields. Types register into the static type universe at startup (BEFORE the main loop runs) and are frozen thereafter.

```scheme
;; Structs — named product types with typed fields.
(struct :project/market/Candle
  [open   : f64]
  [high   : f64]
  [low    : f64]
  [close  : f64]
  [volume : f64])

;; Enums — coproduct types with optional tagged variants.
(enum :project/trading/Direction :long :short)

(enum :project/market/Event
  (candle  [asset : Atom] [candle : :project/market/Candle])
  (deposit [asset : Atom] [amount : f64]))

;; Newtypes — nominal aliases with distinct identity.
;; Not a subtype of the wrapped type — nominal distinction.
(newtype :project/trading/TradeId :usize)
(newtype :project/trading/Price   :f64)

;; Deftypes — structural aliases; shorthand for existing type shapes.
(deftype :alice/types/Amount :f64)
(deftype :wat/std/Option<:T> (:Union :() :T))

;; Deftype with :is-a — declares a new type that IS a subtype of the other.
;; Every value of :ChildType is substitutable where :ParentType is expected.
(deftype :alice/types/AtomicValue :is-a :Atom)
(deftype :project/market/BullishCandle :is-a :project/market/Candle)
```

All four forms use keyword-path names for namespacing (discipline, not mechanism). They are materialized into the Rust-backed wat-vm binary at build time; they cannot be redefined at runtime.

**Three distinct semantics for naming a new type:**

| Form | Semantics | Substitutable where original is expected? |
|---|---|---|
| `(deftype :A :B)` | Structural alias — `:A` and `:B` are the same type | Yes (they ARE the same) |
| `(deftype :A :is-a :B)` | Subtype declaration — `:A` is a new type, narrower than `:B` | Yes (via `:is-a`) |
| `(newtype :A :B)` | Nominal wrapper — `:A` has distinct identity; is NOT a subtype of `:B` | No (explicit conversion required) |

Users pick based on what they mean: identical (`deftype` alias), substitutable (`deftype :is-a`), or distinct (`newtype`).

### Subtype Hierarchy

The type system has built-in subtype facts (stated as type-system knowledge; users don't write them):

```
:Atom            :is-a :Thought
:Bundle          :is-a :Thought
:Bind            :is-a :Thought
:Permute         :is-a :Thought
:Thermometer     :is-a :Thought
:Blend           :is-a :Thought
:Orthogonalize   :is-a :Thought
:Resonance       :is-a :Thought
:ConditionalBind :is-a :Thought
:Cleanup         :is-a :Thought
```

Every specific ThoughtAST node kind **is a Thought**. A parameter typed as `:Thought` accepts any of these.

**No built-in subtyping between the Rust primitive types.** `:i32` is NOT a subtype of `:i64`; `:f32` is NOT a subtype of `:f64`. Matches Rust's strictness — explicit coercion required (e.g., `(as-f64 int-value)`). Prevents silent precision loss.

### Variance Rules

For parametric types, the type system has built-in variance rules (also stated as type-system knowledge):

**`(:List :T)` — covariant in T.**

If `:A :is-a :B`, then `(:List :A) :is-a (:List :B)`. Example: `(:List :Atom) :is-a (:List :Thought)` because every Atom is a Thought.

Intuition: a list of subtypes is always usable where a list of supertypes is expected (the elements are already the right kind).

**`(:Function args... -> return)` — contravariant in args, covariant in return.**

If `:A :is-a :B` and `:C :is-a :D`, then:
- `(:Function :B -> :C) :is-a (:Function :A -> :D)`
- Reads: "Function accepting a wider argument and returning a narrower result is substitutable where Function accepting a narrower argument and returning a wider result is expected."

Liskov intuition:
- **Accept more (broader input)** — safe, caller's narrower input still fits
- **Return less (narrower output)** — safe, caller's wider-expected output is satisfied

Example: `(:Function :Thought -> :Atom) :is-a (:Function :Atom -> :Thought)`:
- The function on the left accepts any Thought (broader than Atom) and returns an Atom (narrower than Thought)
- Substitutable for a function expected to accept an Atom and return a Thought

**Other parametric types** (`:Vec`, `:Arc`, `:Option`, `:Result`) — same pattern as their Rust analogs. `:Vec<:T>` covariant, `:Option<:T>` covariant, `:Result<:T :E>` covariant in both, `:Arc<:T>` covariant.

**User parametric types** (future; not in scope for 058) would declare variance in their type parameter declarations. For 058, variance is hardcoded for built-in parametric types.

### Type annotations on `define` and `lambda`

From 058-028-define and 058-029-lambda, type annotations are required. The return type goes INSIDE the signature parens using `->`:

```scheme
(define (:my/ns/amplify [x : Thought] [y : Thought] [s : f64] -> :Thought)
  (Blend x y 1 s))

(lambda ([t : Thought] -> :Thought)
  (Permute t 1))

;; Matches Rust's fn name(args) -> ReturnType:
;;   fn amplify(x: Thought, y: Thought, s: f64) -> Thought { ... }
```

Each parameter uses `[name : Type]` with spaces around the colon. The return type follows `->` at the end of the signature (all inside one set of parens). No dangling `: Type` outside the form. The body must produce a value of the return type, checked at startup.

**Macros use the same signature syntax as `define` and `lambda`** — every parameter is explicitly typed `: AST`; return is explicitly `-> :AST`. One consistent signature form across all three definition primitives. No implicit rules for the reader to remember.

```scheme
(defmacro :wat/std/Subtract [x : AST] [y : AST] -> :AST
  `(Blend ,x ,y 1 -1))
;; parameters and return are explicitly typed.
;; type-correctness of the EXPANSION is enforced by type-checking the expanded form
;; against the signatures of its constituent primitives (Blend, etc.).
```

Macro parameters carry ASTs (unevaluated source), so their type is always `:AST`. The return is always `:AST` (the expansion is a syntactic form). Stating this explicitly is simpler — one signature syntax across define/lambda/defmacro — than the easy shortcut of omission.

## Why This Earns Language-Core Status

**1. The Rust-backed wat-vm requires types for startup verification.**

Under Model A (fully static loading), the wat-vm verifies all code at startup before the main loop runs. When the verifier processes a `define`, it needs to know:

- What kind of value each argument is (Thought? Scalar? Integer? List?)
- What kind of value the function returns
- Whether the body produces a value of the declared return type

Without type annotations, the verifier would need to either infer types at every call site (slower, more fragile) or defer all type checks to runtime (undermines the static-verification guarantee).

With type annotations, verification is deterministic, complete, and happens once at startup. Runtime dispatch is a simple argument-type check against the known signature.

**2. Signatures are part of cryptographic provenance.**

Per FOUNDATION's "Cryptographic provenance" section, ASTs are signed. A `define`'s signature (parameter types + return type) is part of its EDN. Tampering with either signature or body breaks the hash. A signed function can be TRUSTED not just in its body but in its CONTRACT — a call site that matches the parameter types will get a return value of the declared return type.

**3. Types enable static verification of stdlib compositions.**

```scheme
(define (:wat/std/Chain [thoughts : (:List :Thought)]) : Thought
  (Bundle (pairwise-map :wat/std/Then thoughts)))
```

The startup verifier can check:
- `thoughts` has type `(:List :Thought)`
- `pairwise-map` returns `(:List :Thought)` given `:wat/std/Then` (a `(:Function [:Thought :Thought] :Thought)`) and a `(:List :Thought)`
- `Bundle` takes `(:List :Thought)` and returns `:Thought`
- Body returns `:Thought`, matching the declared return

Without types, these checks defer to runtime or never happen. With types, stdlib correctness is mechanically verifiable at startup.

**4. Extension via user-defined types.**

Users author their own types with the same naming discipline as functions. `:alice/types/Price`, `:project/market/Candle`. The type system is open — any user can add types, and collisions are prevented by the keyword-path discipline plus startup verification (two structs with the same keyword-path name in the compile-time sources is a build error).

User types are usable anywhere built-in types are used:

```scheme
(define (:my/trading/analyze [c : :project/market/Candle]) : Thought
  (Sequential
    (list (Thermometer (:close c) 0 100)
          (Thermometer (:volume c) 0 10000))))
```

## Arguments For

**1. Small, well-scoped type set.**

The built-in types correspond to the algebra's actual kinds. There is no speculative hierarchy — just the types the primitives actually produce and consume. Twelve built-ins, each corresponding to a concrete runtime kind.

**2. Keyword-path types match the naming discipline.**

Just as functions are keywords (`:wat/std/Difference`), user types are keywords (`:alice/types/Price`, `:project/market/Candle`). Same naming mechanism, same namespace discipline. Users learn one convention, use it everywhere.

Built-in types use shorthand within their own namespace: `:Thought` is shorthand for `:wat/types/Thought` when context makes it unambiguous.

**3. Parametric types handle the essential cases.**

Generics (`(:List :T)`, `(:Function [args] return)`) cover the recurring need for higher-order stdlib and container operations. More elaborate generics (variance, bounds, existentials) are out of scope — the target is "enough type system to dispatch correctly," not a full algebraic type theory.

**4. Structural typing for structural aliases; nominal for struct/enum/newtype.**

- `(deftype :Candle (:Map [[:open :Scalar] ...]))` is a structural alias, not a nominal type. Any Map with the declared fields of the declared types satisfies the alias. Useful for "some shape that I'm naming."
- `(struct :project/market/Candle ...)` is nominal. A value is a Candle if and only if it was constructed as one. Distinct from other structs with identical fields.
- `(enum :Direction ...)` is nominal. Only values constructed via the enum's constructors inhabit the type.
- `(newtype :TradeId :Int)` is nominal. A `:TradeId` is NOT a `:Int` even though they share representation.

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

Having `struct` be nominal but `deftype` be structural may confuse readers. Why the asymmetry?

**Counter:** nominal identity matters for struct/enum/newtype — they're new types with their own semantics. Structural matching matters for `deftype` — it's a NAME for an EXISTING shape. The two tools serve different needs and the asymmetry is deliberate.

**3. Type inference scope.**

This proposal REQUIRES explicit types on `define` and `lambda` parameters. Some languages infer these from usage. Scheme and Clojure are traditionally untyped; Haskell and F# infer aggressively; Rust infers locally.

**Counter:** explicit types on function boundaries are the Model A contract. Local inference (within function bodies, for intermediate values) IS supported — the verifier can infer that `(Blend a b 1 -1)` returns `:Thought` from Blend's signature. Function boundary types are required; internal types are derived. This matches Rust's approach.

**4. Generics complexity.**

Parametric types need generic resolution: when `map` receives a `(:List :Thought)` and a `(:Function [:Thought] :Scalar)`, the result is `(:List :Scalar)` (the Function's return type substituted for `T`). This is basic unification.

**Counter:** yes, but bounded. The wat language doesn't need variance, higher-kinded types, or other advanced features. Simple substitution suffices for the stdlib's needs.

**5. :Any as escape hatch — abuse risk.**

`:Any` disables type checking for a position. It exists because some stdlib forms (like `cleanup` taking arbitrary candidate types) genuinely need flexibility.

**Counter:** document `:Any` as a last resort. Prefer concrete types where possible. Audit usage in stdlib.

## Type Checking Semantics (Model A)

### Static check at startup

When the wat-vm boots, it processes all loaded files in order. For each `define`:

1. Parse the parameter list — each must be `[name : Type]`
2. Parse the return type — must be a well-formed type in the type environment
3. Type-check the body — every sub-expression must produce a type compatible with its usage
4. Verify the body's final expression matches the declared return type

Errors at this stage prevent the wat-vm from starting. No partial-state recovery.

### Dynamic check at call site (fast path)

When a call site is evaluated at runtime:

1. Look up the function by name in the static symbol table
2. Each argument's type must be a subtype/alias of the corresponding parameter type
3. If match, bind parameters, evaluate body, return result

If types matched at startup verification, the body is guaranteed to return the declared type — no per-call return check needed. The argument-type check at the call site guards against user data misuse (e.g., a `:Scalar` passed where a `:Thought` is expected).

### Primitive dispatch

Primitives like `Bundle` are built into the wat-vm with their signatures hardcoded:

```
Bundle: (:List :Thought) -> :Thought
Bind: :Thought :Thought -> :Thought
Blend: :Thought :Thought :Scalar :Scalar -> :Thought
Permute: :Thought :Int -> :Thought
Atom: :Any -> :Atom          ; :Any accommodates typed literals
Thermometer: :Scalar :Scalar :Scalar -> :Thought
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
    Named(Keyword),                          // :Thought, :Scalar, :alice/types/Price
    Parametric(Keyword, Vec<TypeAST>),       // (:List :Thought), (:Function [args] ret)
    Any,                                     // :Any escape hatch
}
```

Type environment (frozen after startup):

```rust
pub struct TypeEnv {
    builtins: HashMap<Keyword, TypeDef>,     // :Thought, :Atom, etc.
    user_types: HashMap<Keyword, TypeDef>,   // struct, enum, newtype, deftype registrations
}

pub enum TypeDef {
    Builtin(BuiltinType),
    Struct(StructDef),
    Enum(EnumDef),
    Newtype(NewtypeDef),
    Alias(AliasDef),            // deftype
}
```

Type checker:

```rust
pub fn check_subtype(actual: &TypeAST, expected: &TypeAST, env: &TypeEnv) -> Result<(), TypeError> {
    // :Any is always compatible
    // Named types must match (through aliases)
    // Parametric types unify per argument
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

**`struct`, `enum`, `newtype`, `deftype` forms:**

New language-core forms (alongside `define` and `lambda`), all compile-time-registering. Build pipeline extracts them from wat files loaded via `(load-types ...)`, generates Rust code, compiles. See FOUNDATION's "All loading happens at startup" section for the pipeline description.

## Questions for Designers

1. **Generics scope.** Is `(:Function [args] return)` and `(:List :T)` sufficient, or do we need variance, bounds (`T extends :Thought`), or existentials? Recommendation: start minimal — just List and Function parametrics. Add more if stdlib needs emerge.

2. **Type inference strength.** Parameter types on `define`/`lambda` are required. Should all intermediate expressions be inferred, or should `let` support optional type annotations? Recommendation: infer intermediates; allow optional `[let [[x : Thought] (Blend a b 1 -1)]]` for explicit annotation when helpful.

3. **Nominal vs. structural typing.** Proposal uses nominal for struct/enum/newtype and structural for deftype. Is this the right split? Recommendation: yes — nominal protects semantics, structural provides shorthand.

4. **:Any usage.** Document as last resort. Should it be restricted (only in specific primitive positions) or freely available? Recommendation: freely available, but linters flag its use.

5. **Type promotion rules.** If a function takes `:Scalar` and you pass an `:Int`, does it auto-promote? Recommendation: no implicit promotion — explicit `(to-scalar int)` or similar. Matches Rust's strictness; prevents surprising behavior.

6. **Error reporting.** Type errors need to point at the offending expression with a useful message. "Expected :Thought, got :Scalar at line X" is the minimum. Structured error types with source locations are part of the implementation.

7. **Metadata on types.** `deftype` could accept documentation strings, constraints, validators. Worth including in the first version? Recommendation: start simple (just alias); add metadata if needed.

8. **Subtype hierarchy.** Is `:Atom` a subtype of `:Thought` (atoms ARE thoughts in the ThoughtAST)? Recommendation: yes — every Atom is a Thought. A parameter `:Thought` accepts an Atom value. Document the subtype relationships.

9. **Dependency ordering.** Types depend on nothing; `define` and `lambda` depend on types. Resolution order: 058-030 (types) first, then 058-028 (define) and 058-029 (lambda).

10. **First-class types.** Types as keyword values can be passed around. Does this enable type-reflecting code? Probably, though not the focus of this proposal. Example: `(type-of x)` returns the keyword `:Thought`. Useful for introspection but out of scope for language core.

11. **Keyword-path in type names with generic parameters.** `(deftype :wat/std/Option<:T> (:Union :Null :T))` uses a `<>`-style generic parameter. Is this the right syntax, or should generic parameters be expressed differently? Recommendation: `<>` is readable; keep it. Alternative: explicit parameter list like `(deftype (:wat/std/Option :T) (:Union :Null :T))` — more Lispy but less visually distinct. Pick one, document.
