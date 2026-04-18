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
:Holon           — any HolonAST node (the universal substrate type)
:Atom            — an Atom node specifically (read literal via atom-value)
:Bundle          — a Bundle node (:is-a :Holon)
:Bind            — a Bind node (:is-a :Holon)
:Permute         — a Permute node (:is-a :Holon)
:Thermometer     — a Thermometer node (:is-a :Holon)
:Blend           — a Blend node (:is-a :Holon)
:Orthogonalize   — an Orthogonalize node (:is-a :Holon)
:Resonance       — a Resonance node (:is-a :Holon)
:ConditionalBind — a ConditionalBind node (:is-a :Holon)
:Vector          — a raw encoded ternary vector in `{-1, 0, +1}^d` (post-encode form; see FOUNDATION's "Output Space")
:AST             — a parsed source AST (for macro parameters; see 058-031-defmacro)
```

**Note on `:Holon`:** Holon (Koestler's sense) is the universal substrate — a thing that is simultaneously whole and part. Every algebra value IS a Holon: `Atom`, `Bind`, `Bundle`, `Permute`, `Thermometer`, `Blend`, `Orthogonalize`, `Resonance`, `ConditionalBind` are all subtypes of `:Holon`. The rename from `:Thought` to `:Holon` makes the algebra's universal type match the project's own name (holon-rs, holon-lab-*).

**Note on `:Cleanup`:** REJECTED as a core form (see 058-025). Retrieval is presence measurement (cosine + noise floor), not argmax-over-codebook. No `:Cleanup` type exists.


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
```

**NO `:Any`.** `:Any` would be an escape hatch ("I refuse to declare a type") — easy, not simple. Every apparent use case has a principled replacement:

- Universal algebra value → `:Holon`
- Heterogeneous primitives → `:Union<T,U,V>`
- Generic container element → parametric type parameter (`T`, `K`, `V`)
- `eval`'s return → `:fn(:Holon)->Holon` or parametric `:fn(:Holon)->T`
- Engram library entries → `:List<Pair<Holon,Vector>>`

If a programmer can't declare the type of their value, that is a design signal that the function hasn't been fully specified. The type system is the forcing function.

**NO `:Scalar` / `:Int` / `:Bool` / `:Null` abstractions.** Use the concrete Rust types directly. Blend's weights are `:f64`. Permute's step count is `:i32` or `:usize`. `nth`'s index is `:usize`. Booleans are `:bool`. The unit value is `:()`. Absence is `:Option<T>`, never null.

**NO null.** Rust doesn't have null; wat doesn't have null. `:Option<T>` is an enum with variants `:None` and `(Some value)` for optional values. `:()` (the unit type) represents "no meaningful return." Structural absence — a `when` that didn't fire, a branch that wasn't taken, a field that doesn't exist in a variant — is expressed by the form simply not being present. Atom literals are string, int, float, bool, keyword — no null.


### Parametric types

Parametric types use Rust-surface syntax as single-token keywords:

```
:List<Holon>                   ; list of holons
:List<f64>                     ; list of f64 values
:List<List<Holon>>             ; list of lists of holons (nested)
:Vec<u8>                       ; Rust Vec<u8> — byte buffer
:HashMap<K,V>                  ; Rust HashMap<K, V>
:HashSet<T>                    ; Rust HashSet<T>
:Option<Holon>                 ; Option<Holon>
:Result<Holon,Error>           ; Result<Holon, Error>
:Pair<Holon,Vector>            ; tuple of 2
:Tuple<T,U,V>                  ; tuple of 3
:Union<T,U,V>                  ; coproduct (for type annotations)
:Arc<Holon>                    ; Arc<Holon>
```

Function types mirror Rust's `fn(T, U) -> R` exactly:

```
:fn(Holon,Holon)->Holon              ; binary Holon → Holon
:fn(f64)->f64                        ; unary f64 → f64
:fn(Atom)->Holon                     ; Atom → Holon
:fn(Holon,Holon,f64,f64)->Holon      ; Blend's type
:fn()->Holon                         ; nullary
:fn(T)->T                            ; identity on T
:fn(List<T>,fn(T)->U)->List<U>       ; map's type
```

Arguments between the parens, return after `->`. Direct one-to-one correspondence with Rust's syntax.

### The tokenizer rule

The `:` is Lisp's quote. One at the start; the whole expression is a single keyword token. Inside a keyword:
- NO internal `:` (re-quoting is illegal)
- NO internal whitespace (whitespace ends the keyword)
- Structural characters `/`, `<`, `>`, `(`, `)`, `,`, `-`, `>` all belong to the keyword
- The tokenizer tracks bracket depth across three pairs — `()`, `[]`, `<>` — and ends the keyword at whitespace or an unmatched closing bracket

Nested generics compose:

```
:HashMap<String,fn(i32)->i32>
:Result<HashMap<Atom,Holon>,String>
:fn(List<i32>)->Option<f64>
:Option<HashMap<Atom,List<Holon>>>
```

All single tokens. Each is a hashable string. The type-aware hash (058-001) applies at the whole-keyword granularity.

### Rust-mapping is direct

```
wat keyword                                    Rust
─────────────────────────────                  ──────────────────────────
:HashMap<K,V>                                  HashMap<K, V>
:List<T>                                       Vec<T>
:Option<T>                                     Option<T>
:Result<T,E>                                   Result<T, E>
:fn(T,U)->R                                    fn(T, U) -> R
:fn(List<i32>)->Option<f64>                    fn(Vec<i32>) -> Option<f64>
:HashMap<String,fn(i32)->i32>                  HashMap<String, fn(i32) -> i32>
:Union<T,U>                                    enum { T(T), U(U) }   (or Either<T,U>)
:Pair<T,U>                                     (T, U)
```

The compiler strips the `:`, inserts spaces after commas, and emits Rust. Translation is string rewriting. No AST walk, no canonicalization pass — the keyword IS the type.

### User-definable types

Users declare types using the compile-time forms `struct`, `enum`, `newtype`, and `deftype` — all with keyword-path names and typed fields. Types register into the static type universe at startup (BEFORE the main loop runs) and are frozen thereafter.

```scheme
;; Structs — named product types with typed fields.
(struct :project/market/Candle
  (open   :f64)
  (high   :f64)
  (low    :f64)
  (close  :f64)
  (volume :f64))

;; Enums — coproduct types with optional tagged variants.
(enum :project/trading/Direction :long :short)

(enum :project/market/Event
  (candle  (asset :Atom) (candle :project/market/Candle))
  (deposit (asset :Atom) (amount :f64)))

;; Newtypes — nominal aliases with distinct identity.
;; Not a subtype of the wrapped type — nominal distinction.
(newtype :project/trading/TradeId :usize)
(newtype :project/trading/Price   :f64)

;; Deftypes — structural aliases; shorthand for existing type shapes.
(deftype :alice/types/Amount :f64)
(deftype :alice/market/CandleSeries :List<Candle>)
(deftype :alice/trading/Scores :HashMap<Atom,f64>)

;; Note: :Option<T> is Rust's enum Option<T>, declared as an enum:
;;   (enum :wat/std/Option<T>
;;     :None
;;     (Some (value :T)))
;; NOT a deftype alias — it has two distinct variants.

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
:Atom            :is-a :Holon
:Bundle          :is-a :Holon
:Bind            :is-a :Holon
:Permute         :is-a :Holon
:Thermometer     :is-a :Holon
:Blend           :is-a :Holon
:Orthogonalize   :is-a :Holon
:Resonance       :is-a :Holon
:ConditionalBind :is-a :Holon
```

Every specific HolonAST node kind **is a Holon**. A parameter typed as `:Holon` accepts any of these.

**No built-in subtyping between the Rust primitive types.** `:i32` is NOT a subtype of `:i64`; `:f32` is NOT a subtype of `:f64`. Matches Rust's strictness — explicit coercion required (e.g., `(as-f64 int-value)`). Prevents silent precision loss.

### Variance Rules

For parametric types, the type system has built-in variance rules (also stated as type-system knowledge):

**`:List<T>` — covariant in T.**

If `:A :is-a :B`, then `:List<A> :is-a :List<B>`. Example: `:List<Atom> :is-a :List<Holon>` because every Atom is a Holon.

Intuition: a list of subtypes is always usable where a list of supertypes is expected (the elements are already the right kind).

**`:fn(args)->return` — contravariant in args, covariant in return.**

If `:A :is-a :B` and `:C :is-a :D`, then:
- `:fn(B)->C :is-a :fn(A)->D`
- Reads: "Function accepting a wider argument and returning a narrower result is substitutable where a function accepting a narrower argument and returning a wider result is expected."

Liskov intuition:
- **Accept more (broader input)** — safe, caller's narrower input still fits
- **Return less (narrower output)** — safe, caller's wider-expected output is satisfied

Example: `:fn(Holon)->Atom :is-a :fn(Atom)->Holon`:
- The function on the left accepts any Holon (broader than Atom) and returns an Atom (narrower than Holon)
- Substitutable for a function expected to accept an Atom and return a Holon

**Other parametric types** (`:Vec<T>`, `:Arc<T>`, `:Option<T>`, `:Result<T,E>`, `:HashMap<K,V>`) — same pattern as their Rust analogs. `:Vec<T>` covariant, `:Option<T>` covariant, `:Result<T,E>` covariant in both, `:Arc<T>` covariant. `:HashMap<K,V>` invariant in K (hash-based lookup requires exact type) and covariant in V.

**User parametric types** (future; not in scope for 058) would declare variance in their type parameter declarations. For 058, variance is hardcoded for built-in parametric types.

### Type annotations on `define` and `lambda`

From 058-028-define and 058-029-lambda, type annotations are required. The return type goes INSIDE the signature parens using `->`:

```scheme
(define (:my/ns/amplify (x :Holon) (y :Holon) (s :f64) -> :Holon)
  (Blend x y 1 s))

(lambda ((t :Holon) -> :Holon)
  (Permute t 1))

;; Matches Rust's fn name(args) -> ReturnType:
;;   fn amplify(x: Holon, y: Holon, s: f64) -> Holon { ... }
```

Each parameter uses `(name :Type)` — parenthesized sublist with a bare symbol name and a keyword type. The return type follows `->` at the end of the signature (all inside one set of parens). No dangling `: Type` outside the form. The body must produce a value of the return type, checked at startup.

**Macros use the same signature syntax as `define` and `lambda`** — every parameter is explicitly typed `: AST`; return is explicitly `-> :AST`. One consistent signature form across all three definition primitives. No implicit rules for the reader to remember.

```scheme
(defmacro (:wat/std/Subtract (x :AST) (y :AST) -> :AST)
  `(Blend ,x ,y 1 -1))
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
(define (:wat/std/Chain (holons :List<Holon>) -> :Holon)
  (Bundle (pairwise-map :wat/std/Then holons)))
```

The startup verifier can check:
- `holons` has type `:List<Holon>`
- `pairwise-map` returns `:List<Holon>` given `:wat/std/Then` (of type `:fn(Holon,Holon)->Holon`) and a `:List<Holon>`
- `Bundle` takes `:List<Holon>` and returns `:Holon`
- Body returns `:Holon`, matching the declared return

Without types, these checks defer to runtime or never happen. With types, stdlib correctness is mechanically verifiable at startup.

**4. Extension via user-defined types.**

Users author their own types with the same naming discipline as functions. `:alice/types/Price`, `:project/market/Candle`. The type system is open — any user can add types, and collisions are prevented by the keyword-path discipline plus startup verification (two structs with the same keyword-path name in the compile-time sources is a build error).

User types are usable anywhere built-in types are used:

```scheme
(define (:my/trading/analyze (c :project/market/Candle) -> :Holon)
  (Sequential
    (list (Thermometer (:close c) 0 100)
          (Thermometer (:volume c) 0 10000))))
```

## Arguments For

**1. Small, well-scoped type set.**

The built-in types correspond to the algebra's actual kinds. There is no speculative hierarchy — just the types the primitives actually produce and consume. Twelve built-ins, each corresponding to a concrete runtime kind.

**2. Keyword-path types match the naming discipline.**

Just as functions are keywords (`:wat/std/Difference`), user types are keywords (`:alice/types/Price`, `:project/market/Candle`). Same naming mechanism, same namespace discipline. Users learn one convention, use it everywhere.

Built-in types use shorthand within their own namespace: `:Holon` is shorthand for `:wat/types/Holon` when context makes it unambiguous.

**3. Parametric types handle the essential cases.**

Generics (`:List<T>`, `:HashMap<K,V>`, `:fn(args)->return`) cover the recurring need for higher-order stdlib and container operations. More elaborate generics (bounds, existentials, higher-kinded types) are out of scope — the target is "enough type system to dispatch correctly and map cleanly to Rust," not a full algebraic type theory.

**4. Structural typing for structural aliases; nominal for struct/enum/newtype.**

- `(deftype :CandleScores :HashMap<Atom,f64>)` is a structural alias, not a nominal type. Any HashMap with the declared key/value types satisfies the alias. Useful for "some shape that I'm naming."
- `(struct :project/market/Candle ...)` is nominal. A value is a Candle if and only if it was constructed as one. Distinct from other structs with identical fields.
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

Having `struct` be nominal but `deftype` be structural may confuse readers. Why the asymmetry?

**Counter:** nominal identity matters for struct/enum/newtype — they're new types with their own semantics. Structural matching matters for `deftype` — it's a NAME for an EXISTING shape. The two tools serve different needs and the asymmetry is deliberate.

**3. Type inference scope.**

This proposal REQUIRES explicit types on `define` and `lambda` parameters. Some languages infer these from usage. Scheme and Clojure are traditionally untyped; Haskell and F# infer aggressively; Rust infers locally.

**Counter:** explicit types on function boundaries are the Model A contract. Local inference (within function bodies, for intermediate values) IS supported — the verifier can infer that `(Blend a b 1 -1)` returns `:Holon` from Blend's signature. Function boundary types are required; internal types are derived. This matches Rust's approach.

**4. Generics complexity.**

Parametric types need generic resolution: when `map` receives a `:List<Holon>` and a `:fn(Holon)->f64`, the result is `:List<f64>` (the function's return type substituted for `T`). This is basic unification.

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

If types matched at startup verification, the body is guaranteed to return the declared type — no per-call return check needed. The argument-type check at the call site guards against user data misuse (e.g., an `:f64` passed where a `:Holon` is expected).

### Primitive dispatch

Primitives like `Bundle` are built into the wat-vm with their signatures hardcoded:

```
Bundle:      :fn(:List<Holon>)->Holon
Bind:        :fn(Holon,Holon)->Holon
Blend:       :fn(Holon,Holon,f64,f64)->Holon
Permute:     :fn(Holon,i32)->Holon
Atom:        :fn(AtomLiteral)->Atom           ; AtomLiteral is a Union of permitted literal types
Thermometer: :fn(f64,f64,f64)->Holon
```

Where `:AtomLiteral` is an internally-defined Union type covering the permitted atom literals (see 058-001):

```
(deftype :AtomLiteral :Union<String,i32,f64,bool,Keyword>)
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
    Named(Keyword),                          // :Holon, :f64, :alice/types/Price
    Parametric {                             // :List<Holon>, :HashMap<K,V>
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
    builtins: HashMap<Keyword, TypeDef>,     // :Holon, :Atom, etc.
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
    // Named types must match (through aliases, through :is-a hierarchy)
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

**`struct`, `enum`, `newtype`, `deftype` forms:**

New language-core forms (alongside `define` and `lambda`), all compile-time-registering. Build pipeline extracts them from wat files loaded via `(load-types ...)`, generates Rust code, compiles. See FOUNDATION's "All loading happens at startup" section for the pipeline description.

## Questions for Designers

1. **Generics scope.** Is `:fn(args)->return` and `:List<T>` (plus `:HashMap<K,V>`, `:Option<T>`, `:Result<T,E>`, `:Pair<T,U>`, `:Union<T,U,V>`, `:Arc<T>`, `:Vec<T>`) sufficient, or do we need bounds (`T: Holon`), higher-kinded types, or existentials? Recommendation: start minimal — the host-inherited parametric constructors plus user parametric types via `deftype`/`struct`/`enum` parametric declarations. Add bounds if stdlib needs emerge.

2. **Type inference strength.** Parameter types on `define`/`lambda` are required. Should all intermediate expressions be inferred, or should `let` support optional type annotations? Recommendation: infer intermediates; allow optional `(let (((x :Holon) (Blend a b 1 -1))))` for explicit annotation when helpful.

3. **Nominal vs. structural typing.** Proposal uses nominal for struct/enum/newtype and structural for deftype. Is this the right split? Recommendation: yes — nominal protects semantics, structural provides shorthand.

4. **`:Any` removed from grammar.** Resolved. `:Any` is not part of the type system. Use `:Holon` for any algebra value, `:Union<T,U,...>` for closed heterogeneous sets, parametric `T`/`K`/`V` for generics. The type universe is closed — no escape hatch — which is what makes startup verification total.

5. **Type promotion rules.** If a function takes `:f64` and you pass an `:i32`, does it auto-promote? Recommendation: no implicit promotion — explicit `(as-f64 int)` or similar. Matches Rust's strictness; prevents surprising behavior.

6. **Error reporting.** Type errors need to point at the offending expression with a useful message. "Expected `:Holon`, got `:f64` at line X" is the minimum. Structured error types with source locations are part of the implementation.

7. **Metadata on types.** `deftype` could accept documentation strings, constraints, validators. Worth including in the first version? Recommendation: start simple (just alias); add metadata if needed.

8. **Subtype hierarchy.** Is `:Atom` a subtype of `:Holon` (atoms ARE holons in the HolonAST)? Recommendation: yes — every Atom is a Holon. A parameter `:Holon` accepts an Atom value. Document the subtype relationships.

9. **Dependency ordering.** Types depend on nothing; `define` and `lambda` depend on types. Resolution order: 058-030 (types) first, then 058-028 (define) and 058-029 (lambda).

10. **First-class types.** Types as keyword values can be passed around. Does this enable type-reflecting code? Probably, though not the focus of this proposal. Example: `(type-of x)` returns the keyword `:Holon`. Useful for introspection but out of scope for language core.

11. **Keyword-path in type names with generic parameters — RESOLVED.** Rust-surface angle-bracket keyword syntax, single token, no internal spaces, no internal colons. The `:` is Lisp's quote — one at the start; everything else is inside. `:wat/std/Container<T>` at declaration, `:wat/std/Container<Holon>` at use. Function types use `:fn(args)->return` with parens and arrow (Rust's native syntax). The tokenizer tracks bracket depth across `()`, `[]`, `<>` and ends the keyword at whitespace or an unmatched closer.
