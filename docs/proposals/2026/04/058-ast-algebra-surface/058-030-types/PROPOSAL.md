# 058-030: Types — The Language Core Type System

**Scope:** language
**Class:** LANGUAGE CORE
**Parent:** 058-ast-algebra-surface
**Foundation:** ../FOUNDATION.md
**Depends on:** 058-001-atom-typed-literals (for atom literal types)
**Companion proposals:** 058-028-defn, 058-029-lambda (both require this)

## The Candidate

A **keyword-path-based type system** for the wat language, providing:

1. A small set of **built-in types** for the primitives the algebra exposes.
2. A **parametric type constructor** for containers (lists of T, functions from T to U).
3. **User-definable types** via keyword-path naming discipline (`:alice/types/Price`).
4. **Static type checking** at evaluator load time — signatures of `defn` and call sites must match before execution.

### Built-in types

```
:Thought     — any ThoughtAST node
:Atom        — specifically an Atom node (read literal via atom-value)
:Scalar      — f64 literal (Blend weights, arithmetic)
:Int         — integer (Permute steps, nth indices)
:String      — raw string literal (not yet an Atom)
:Bool        — true / false
:Keyword     — keyword literal (e.g., :foo, :bar/baz)
:Null        — the null literal
:List        — homogeneous list (requires parameter: :List<:Thought>)
:Vector      — raw encoded bipolar vector (post-encode, for low-level stdlib)
:Function    — typed function (parameterized: :Function<params, return>)
:Any         — escape hatch; disables static checking for this position
```

### Parametric types

Parametric types are expressed as keyword-heads with type arguments:

```scheme
(:List :Thought)                 ; list of thoughts
(:List :Scalar)                  ; list of scalars
(:List (:List :Thought))         ; list of lists of thoughts
(:Function [:Thought :Thought] :Thought)  ; binary thought → thought
(:Function [:Scalar] :Scalar)    ; unary scalar → scalar
(:Function [:Atom] :Thought)     ; atom → thought
```

Function types have two parameters: a vector of argument types and a return type.

### User-defined types

Users declare types in their namespaces with the same keyword-path convention as functions:

```scheme
(deftype :alice/types/Price :Scalar)
;; alias: :alice/types/Price is an :Scalar

(deftype :project/market/Candle
  (:Map [[:open :Scalar]
         [:high :Scalar]
         [:low :Scalar]
         [:close :Scalar]
         [:volume :Scalar]]))
;; structural alias: :project/market/Candle is a Map with these typed fields

(deftype :wat/std/Option<:T>
  (:Union :Null :T))
;; parametric alias: Option<T> is either Null or T
```

`deftype` is a language-core form companion to `defn`. It registers a type name in the type environment. Types are values (keyword paths), so they can be passed, stored, inspected.

### Type annotations on `defn` and `lambda`

From 058-028-defn and 058-029-lambda:

```scheme
(defn :my/ns/amplify [[x :Thought] [y :Thought] [s :Scalar]] :Thought
  (Blend x y 1 s))

(lambda [[t :Thought]] :Thought
  (Permute t 1))
```

Each parameter gets `[name :Type]`. The return type follows the parameter vector. The body must produce a value of the return type.

## Why This Earns Language-Core Status

**1. The Rust evaluator requires types for correct dispatch.**

When the evaluator sees `(Blend x y 1 -1)`, it needs to know:

- Is `x` a Thought or a Scalar?
- Is `y` a Thought?
- Are the third and fourth arguments scalars?

Without types, every call becomes a runtime type probe. With types, the signature is known statically — the evaluator dispatches directly.

**2. Signatures are part of cryptographic provenance.**

Per FOUNDATION's "Cryptographic provenance" section, ASTs are signed. A `defn`'s signature (parameter types + return type) is part of its EDN. Tampering with either signature or body breaks the hash. A signed function can be TRUSTED not just in its body but in its CONTRACT — a call site that matches the parameter types will get a return value of the declared return type.

**3. Types enable static verification of stdlib compositions.**

```scheme
(defn :wat/std/Chain [[thoughts (:List :Thought)]] :Thought
  (Bundle (pairwise-map :wat/std/Then thoughts)))
```

The evaluator can verify:
- `thoughts` has type `(:List :Thought)`
- `pairwise-map` returns `(:List :Thought)` given `:wat/std/Then` (a Function<[:Thought, :Thought], :Thought>) and a `(:List :Thought)`
- `Bundle` takes `(:List :Thought)` and returns `:Thought`
- Body returns `:Thought`, matching the declared return

Without types, these checks defer to runtime or never happen. With types, stdlib correctness is mechanically verifiable.

**4. Extension via user-defined types.**

Users author their own types with the same naming discipline as functions. `:alice/types/Price`, `:project/market/Candle`. The type system is open — any user can add types, and collisions are prevented by the keyword-path discipline (same as functions).

This matters for vocab modules. A trading vocab module defines `:project/market/Candle` as a typed Map; downstream stdlib operates on `:project/market/Candle` typed parameters and get type-checked composition.

## Arguments For

**1. Small, well-scoped type set.**

The built-in types correspond to the algebra's actual kinds. There is no speculative hierarchy — just the types the primitives actually produce and consume. `:Thought`, `:Atom`, `:Scalar`, `:Int`, `:String`, `:Bool`, `:Keyword`, `:Null`, `:List`, `:Vector`, `:Function`, `:Any` — twelve built-ins, each corresponding to a concrete runtime kind.

**2. Keyword-path types match the naming discipline.**

Just as functions are keywords (`:wat/std/Difference`), types are keywords (`:wat/types/Thought`, `:alice/types/Price`). Same naming mechanism, same namespace discipline. Users learn one convention, use it everywhere.

In shorthand (within the built-in types' namespace), the prefix is often implicit: `:Thought` is shorthand for `:wat/types/Thought` when the context makes it unambiguous.

**3. Parametric types handle the essential cases.**

Generics (`:List<T>`, `:Function<args, return>`) cover the recurring need for higher-order stdlib and container operations. More elaborate generics (variance, bounds, existentials) are out of scope — the target is "enough type system to dispatch correctly," not a full algebraic type theory.

**4. Structural typing for user types.**

`(deftype :Candle (:Map [[:open :Scalar] ...]))` is a structural alias, not a nominal type. Any Map with the declared fields of the declared types satisfies the alias. This matches VSA's bundle-based data structures — "what" you have matters, not "where it came from."

This lets vocab modules declare data shapes without requiring inheritance hierarchies or factory functions.

## Arguments Against

**1. Any type system adds complexity to the evaluator.**

Without types, the evaluator is simpler: parse, evaluate, run. With types, the evaluator needs:
- Type environment (table of known types)
- Type inference (for literals and expression results)
- Type checking (signature vs. call-site matching)
- Generic resolution (for parametric types)

**Counter:** the complexity pays for itself — errors caught before execution, dispatch without probing, signatures that can be signed. The simpler untyped evaluator is faster to implement but fragile in operation. Rust's eval contract NEEDS types; this is not optional.

**2. Structural typing vs. nominal typing choice.**

This proposal uses structural typing: `:Candle` is "any Map with these fields," not "a value explicitly tagged as :Candle." Nominal typing (Java-style classes with unique identities) is stricter but more ceremonial.

**Counter:** structural matches the algebra. Values are their structure. A `(Map [[:open 1] ...])` IS a `:Candle` if it has the right fields, regardless of how it was constructed. Rejecting structural matches would require tagging each Map with an explicit `:Candle` marker — ceremony without clear benefit.

**3. Type inference scope.**

This proposal REQUIRES explicit types on `defn` and `lambda` parameters. Some languages infer these from usage. Scheme and Clojure are traditionally untyped; Haskell and F# infer aggressively; Rust infers locally.

**Counter:** explicit types on function boundaries are the Rust-eval contract. Local inference (within function bodies, for intermediate values) IS supported — the evaluator can infer that `(Blend a b 1 -1)` returns `:Thought` from Blend's signature. Function boundary types are required; internal types are derived. This matches Rust's approach.

**4. Generics complexity.**

Parametric types need generic resolution: when `map` receives a `(:List :Thought)` and a `(:Function [:Thought] :Scalar)`, the result is `(:List :Scalar)` (the Function's return type substituted for `T`). This is basic unification.

**Counter:** yes, but bounded. The wat language doesn't need variance, higher-kinded types, or other advanced features. Simple substitution suffices for the stdlib's needs.

**5. :Any as escape hatch — abuse risk.**

`:Any` disables type checking for a position. It exists because some stdlib forms (like `cleanup` taking arbitrary candidate types) genuinely need flexibility.

**Counter:** document `:Any` as a last resort. Prefer concrete types where possible. Audit usage in stdlib.

## Type Checking Semantics

### Static check at defn registration

When a `defn` is registered:

1. Parse the parameter list — each must be `[name :Type]`
2. Parse the return type — must be a well-formed type
3. Type-check the body — every sub-expression must produce a type compatible with its usage
4. Verify the body's final expression matches the declared return type

Errors at this stage prevent registration. The function does not enter the symbol table.

### Dynamic check at call site (fast path)

When a call site is evaluated:

1. Look up the function by name
2. Each argument's type must be a subtype/alias of the corresponding parameter type
3. If match, bind parameters, evaluate body, return result

If types matched at defn registration, the body is guaranteed to return the declared type — no per-call return check needed.

### Primitive dispatch

Primitives like `Bundle` are built into the evaluator with their signatures hardcoded:

```
Bundle: (:List :Thought) -> :Thought
Bind: :Thought :Thought -> :Thought
Blend: :Thought :Thought :Scalar :Scalar -> :Thought
Permute: :Thought :Int -> :Thought
Atom: :Any -> :Atom          ; :Any accommodates typed literals
Thermometer: :Atom :Int -> :Thought
```

Stdlib defn's compose these primitives; their types derive from the primitives' signatures via substitution.

## Implementation Scope

**holon-rs changes:**

Add type AST:

```rust
pub enum TypeAST {
    Named(Keyword),                          // :Thought, :Scalar, :alice/types/Price
    Parametric(Keyword, Vec<TypeAST>),       // (:List :Thought), (:Function [args] ret)
    Any,                                     // :Any escape hatch
}
```

Type environment:

```rust
pub struct TypeEnv {
    builtins: HashMap<Keyword, TypeDef>,     // :Thought, :Atom, etc.
    aliases: HashMap<Keyword, TypeAST>,      // user-defined via deftype
}
```

Type checker:

```rust
pub fn check_subtype(actual: &TypeAST, expected: &TypeAST, env: &TypeEnv) -> Result<(), TypeError> {
    // :Any is always compatible
    // Named types must match (through aliases)
    // Parametric types unify per argument
}

pub fn infer_expr(expr: &WatAST, env: &TypeEnv, locals: &Locals) -> Result<TypeAST, TypeError> {
    match expr {
        WatAST::Atom(_) => Ok(TypeAST::Named(":Atom".into())),
        WatAST::Call { name, args } => {
            let defn = env.lookup(name)?;
            for (arg, param_type) in args.iter().zip(&defn.params) {
                let arg_type = infer_expr(arg, env, locals)?;
                check_subtype(&arg_type, &param_type.1, env)?;
            }
            Ok(defn.return_type.clone())
        },
        // ... other AST variants
    }
}
```

Estimated ~500-800 lines of Rust for:
- TypeAST parsing / serialization
- TypeEnv with builtins
- Subtype checking with generic unification
- Static verification of defn bodies
- Runtime dispatch with type guard on arguments

**wat stdlib:**

Types themselves need no wat code — they're language primitives. Every stdlib `defn` uses types in its signature. Examples already in 058-004 through 058-027.

**`deftype` form:**

New language-core form for user type aliases:

```scheme
(deftype :alice/types/Price :Scalar)
(deftype :project/market/Candle (:Map [[:open :Scalar] [:high :Scalar] ...]))
```

Registers the type in TypeEnv as an alias. Adds ~50 lines to the evaluator.

## Questions for Designers

1. **Generics scope.** Is `(:Function [args] return)` and `(:List :T)` sufficient, or do we need variance, bounds (`T extends :Thought`), or existentials? Recommendation: start minimal — just List and Function parametrics. Add more if stdlib needs emerge.

2. **Type inference strength.** Parameter types on defn/lambda are required. Should all intermediate expressions be inferred, or should `let` support optional type annotations? Recommendation: infer intermediates; allow optional `[let [x :Thought (Blend a b 1 -1)]]` for explicit annotation when helpful.

3. **Nominal vs. structural typing.** Proposal uses structural (a Map with the right fields IS a Candle). Should we offer nominal as an option (`(deftype :Candle :nominal (:Map ...))` that requires explicit tagging)? Recommendation: structural only, at first. Nominal can be added later if demand emerges.

4. **:Any usage.** Document as last resort. Should it be restricted (only in specific primitive positions) or freely available? Recommendation: freely available, but linters flag its use.

5. **Type promotion rules.** If a function takes `:Scalar` and you pass an `:Int`, does it auto-promote? Recommendation: no implicit promotion — explicit `(to-scalar int)` or similar. Matches Rust's strictness; prevents surprising behavior.

6. **Error reporting.** Type errors need to point at the offending expression with a useful message. "Expected :Thought, got :Scalar at line X" is the minimum. Structured error types with source locations are part of the implementation.

7. **Metadata on types.** `deftype` could accept documentation strings, constraints, validators. Worth including in the first version? Recommendation: start simple (just alias); add metadata if needed.

8. **Subtype hierarchy.** Is `:Atom` a subtype of `:Thought` (atoms ARE thoughts in the ThoughtAST)? Recommendation: yes — every Atom is a Thought. A parameter `:Thought` accepts an Atom value. Document the subtype relationships.

9. **Dependency ordering.** Types depend on nothing; defn and lambda depend on types. Resolution order: 058-030 (types) first, then 058-028 (defn) and 058-029 (lambda).

10. **First-class types.** Types as keyword values can be passed around. Does this enable type-reflecting code? Probably, though not the focus of this proposal. Example: `(type-of x)` returns the keyword `:Thought`. Useful for introspection but out of scope for language core.
