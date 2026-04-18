# 058-032: Typed Macros — Macro-Authoring-Time Type Checking

**Scope:** language
**Class:** LANGUAGE CORE
**Parent:** 058-ast-algebra-surface
**Foundation:** ../FOUNDATION.md
**Depends on:** 058-030-types, 058-031-defmacro
**Companion proposals:** 058-028-define, 058-029-lambda

## The Candidate

`defmacro` from 058-031 ships with type checking of the **expansion** — after the macro rewrites the source, the expanded AST is type-checked against the types that `define`/`lambda` declare at the call sites the expansion produces. This catches every type error, eventually. It also points the error message at the expansion, not at the macro.

**Typed macros** move the type check **earlier**. The macro author declares the value type of each parameter and the value type of the expansion. The type checker verifies the macro body at **definition time** — before the macro is ever invoked. Ill-typed macros fail to load. Ill-typed call sites report the error at the macro invocation, naming the parameter that fails.

This is the Racket `syntax/parse` model, translated to wat's type grammar.

```scheme
;; Untyped (058-031): every parameter is :AST.
(defmacro (:wat/std/Subtract (x :AST) (y :AST) -> :AST)
  `(Blend ,x ,y 1 -1))

;; Typed (058-032): parameters carry the value type their expression must produce.
(defmacro (:wat/std/Subtract (x :AST<Holon>) (y :AST<Holon>) -> :AST<Holon>)
  `(Blend ,x ,y 1 -1))
```

The `:AST<T>` wrapper says: "this parameter is an AST expression whose evaluated value has type `T`." The type checker:

1. At macro-definition time, walks the body in a type environment where each parameter is bound to its declared `T`, and verifies the body's constructed AST produces the declared return type.
2. At each call site, verifies the argument expression would type-check as `T` under the surrounding function's type environment.

Errors at macro-definition time blame the macro. Errors at call sites blame the caller. The expansion pass never runs on an ill-typed macro, so the "expansion's surprise type error" class disappears.

## Why This Form Exists

058-031 deferred this work with a stated position: *ship expansion-time type checking; add macro-authoring-time checking as a future proposal.* This is the future proposal.

The deferral was pragmatic, not principled. The substrate has everything typed macros need:

- **058-030-types** gives the type grammar — parametric types (`:List<T>`, `:fn(T,U)->R`), keyword-path names, built-in value types.
- **058-031-defmacro hygiene** gives identifier tracking with scope sets. Extending identifiers to carry types is mechanical: `Identifier` already carries a name and a scope set; add a type slot.
- **058-028-define** and **058-029-lambda** already declare typed signatures the type checker consumes.

Nothing about typed macros is speculative. Racket has shipped `syntax/parse` in production for over a decade. The wat version is a translation, not a research project.

## Shape

### The parametric `:AST<T>`

058-030 does not currently list `:AST<T>` as a parametric type. This proposal adds it:

```
:AST<T>    — a parsed source AST whose evaluated value has type T
:AST       — sugar for :AST<Any>: any expression, unconstrained.
             Remains valid for macros that genuinely accept any shape
             (e.g., `quote`, `debug-print`, introspection tools).
```

`T` ranges over the value types 058-030 defines — `:Holon`, `:f64`, `:i32`, `:bool`, `:String`, user-defined `newtype`/`struct`/`enum`/`typealias` names, parametric containers (`:List<Holon>`, `:HashMap<K,V>`), etc.

**`:AST` alone stays legal.** A macro like `debug-print` that accepts any expression keeps `(arg :AST)`. Typed macros are an **option**, not a mandate. 058-031's stdlib examples (`Subtract`, `Amplify`, `Chain`) gain typed signatures; `defmacro` itself does not force the option.

### Typed macro signature

```scheme
(defmacro (:namespace/macro-name (p1 :AST<T1>) (p2 :AST<T2>) ... -> :AST<R>)
  body-expression)
```

- Each parameter is typed `(name :AST<T>)` where `T` is the value type the argument expression must produce.
- Return type is `:AST<R>` where `R` is the value type the expansion must produce.
- Body constructs an AST that the type checker verifies produces `R` under a type environment where each `pi` is bound to `Ti`.

### Examples

**Pure alias — typed Concurrent:**

```scheme
(defmacro (:wat/std/Concurrent (xs :AST<List<Holon>>) -> :AST<Holon>)
  `(Bundle ,xs))
```

At definition time the checker sees:
- `xs : :AST<List<Holon>>` — an expression producing a list of Holons
- Body constructs `(Bundle ,xs)` — a Bundle node requires `:List<Holon>` by 058-030's enum definition of `:Holon`
- Expansion produces `:Holon` ✓ matches declared return `:AST<Holon>`

**Transforming — typed Subtract:**

```scheme
(defmacro (:wat/std/Subtract (x :AST<Holon>) (y :AST<Holon>) -> :AST<Holon>)
  `(Blend ,x ,y 1 -1))
```

Checker:
- `x, y : :AST<Holon>`
- Body: `(Blend x y 1 -1)`. Blend's signature from 058-002 is `(Blend (a :Holon) (b :Holon) (w1 :f64) (w2 :f64) -> :Holon)`
- First two args: `:Holon` ✓. Last two: `1` and `-1` are `:f64` literals ✓. Returns `:Holon` ✓ matches `:AST<Holon>`.

**Parameterized — typed Amplify:**

```scheme
(defmacro (:wat/std/Amplify (x :AST<Holon>) (y :AST<Holon>) (s :AST<f64>) -> :AST<Holon>)
  `(Blend ,x ,y 1 ,s))
```

Call site type errors land at the caller:

```scheme
(Amplify foo bar 2.5)    ;; OK: 2.5 : :f64 matches :AST<f64>
(Amplify foo bar "oh")   ;; ERROR at my-file.wat:12:
                         ;;   :wat/std/Amplify expects (s :AST<f64>)
                         ;;   argument is :AST<String>
```

**Higher-order — typed Chain:**

```scheme
(defmacro (:wat/std/Chain (holons :AST<List<Holon>>) -> :AST<Holon>)
  `(Bundle (pairwise-map Then ,holons)))
```

Checker verifies `pairwise-map : :fn(:fn(Holon,Holon)->Holon, :List<Holon>) -> :List<Holon>`, `Then : :fn(Holon,Holon)->Holon` (also macro-defined with its own signature), so `(pairwise-map Then holons)` is `:List<Holon>`, and `Bundle` over it is `:Holon`. Declared return: `:AST<Holon>` ✓.

### Quasiquote under a typed environment

Quasiquote works exactly as in 058-031. What changes: each unquoted parameter carries a type, and the spliced positions are checked against the surrounding form's expected types.

In `(Blend ,x ,y 1 -1)`:
- Position 1 of Blend expects `:Holon`. `,x` has declared type `:AST<Holon>`. The spliced value has type `:Holon`. ✓
- Position 2 expects `:Holon`. `,y : :AST<Holon>`. ✓
- Positions 3 and 4 expect `:f64`. `1` and `-1` are `:f64` literals. ✓

If the macro writer accidentally put `,s` (an `:AST<f64>`) in the `a` slot, the checker rejects the macro at definition time, pointing at the body position where the type mismatch occurs.

## Why This Earns Its Own Proposal

**1. It sharpens error locality.**

058-031 catches expansion-time errors. Typed macros catch macro-definition-time errors. The two check the same set of correctness properties; typed macros just catch them earlier with better locations.

A user who writes `(Subtract candle-open 5)` — passing an `:f64` where a `:Holon` is expected — under 058-031 sees an error at the expanded `(Blend candle-open 5 1 -1)` site. The error message mentions Blend, which the user never typed. Under typed macros, the error points at the Subtract call: *":wat/std/Subtract expects (y :AST<Holon>), got :AST<f64>."* The user's macro call is the error location.

**2. It enables IDE features.**

Parameter type information is the foundation for hover-over type hints, argument completion, and macro-specific refactorings. Under 058-031 every parameter is `:AST`; the IDE cannot distinguish positions. Under typed macros the IDE can show the declared type of each parameter as the user writes the call.

**3. It documents macro intent at the signature.**

A macro's signature becomes its contract. Readers understand at a glance what each argument is for. `(x :AST<Holon>)` vs `(s :AST<f64>)` says more than `(x :AST) (s :AST)`.

**4. Implementation cost is bounded.**

Type checking the macro body under a typed environment reuses the type checker that already runs on `define`/`lambda` bodies. The only new mechanism is the `:AST<T>` parametric form in the type grammar, plus an elaboration step where macro parameters are bound in the type environment before the body is checked. Estimated ~200-400 additional lines of Rust on top of the 058-031 expander and scope tracker.

## Implementation — How It Fits With 058-031

058-031's expander already carries a typed `Identifier` structure with a scope set (for hygiene). Typed macros extend `Identifier` with an optional value type:

```rust
#[derive(Clone, PartialEq, Eq, Hash)]
pub struct Identifier {
    pub name: Keyword,
    pub scopes: BTreeSet<ScopeId>,
    pub value_type: Option<TypeAST>,  // NEW — None for untyped or non-binding uses
}
```

For macro parameters, `value_type` is `Some(TypeAST)` — the declared `T` from `:AST<T>`. The expander binds the parameter in the type environment before walking the body.

### Macro-definition-time check (new)

```
Procedure: check_typed_macro(macro_def)
  1. Extract the typed parameter list and declared return type.
  2. Build a type environment: each parameter `pi` bound to `Ti`.
  3. Walk the body, type-checking every sub-expression:
     - Quoted forms (`)  → unchecked at this pass (they're the template)
     - Unquoted forms (,e)  → check `e` as a normal expression.
       - Unquoted parameters: look up their declared type in the environment.
     - Quasi-constructed forms — check them as would be checked if the AST
       they construct appeared as source: every function/macro call's
       argument types must match the callee's signature.
  4. The body's constructed AST must have type R (the declared return).
  5. Report any mismatch with source position from the macro's definition.
```

### Macro-invocation-time check (new)

```
Procedure: check_macro_call(call_site, macro_def)
  1. For each (arg_i, param_i):
     - Check arg_i as a normal expression in the surrounding scope.
     - If its type is not T_i (the param's declared value type), report error.
  2. If all args check, proceed with expansion.
  3. The expansion is the body with each parameter substituted; since the body
     already type-checked at macro-definition time, the expansion is guaranteed
     well-typed.
```

### Expansion pass (unchanged from 058-031)

The expansion pass in 058-031's startup pipeline now runs **after** macro-definition-time type checking. If any typed macro fails to check, startup halts. If all typed macros check, the expansion proceeds as before. Expansion-time checks from 058-031 run on whatever the expansion produces (for defensive redundancy and to cover untyped macros that use `:AST` directly).

### Interaction with hygiene

Scope-set tracking from 058-031 is **orthogonal** to type tracking. A typed macro expansion produces identifiers with both scope sets (for hygiene) and value types (for typed use). Scope equality remains the binding rule; value types are metadata the type checker consults.

## Error Messages — Better Locations

With typed macros and 058-031's `Origin` tracking, error messages gain macro-level precision:

```
Error: :wat/std/Amplify expects (s :AST<f64>), got :AST<String>.
  Call site:        my-app.wat:7:14
  Macro definition: wat/std/idioms.wat:42:3
  Parameter s:      wat/std/idioms.wat:42:31
```

The user sees:
- Where they wrote the offending call
- Which macro they invoked
- Which parameter type they violated
- Where that parameter is declared

Compared to 058-031's expansion-time errors, which report the error at the expanded form (e.g., `Blend` instead of `Amplify`), the typed-macro error points directly at user-written code.

## Back-Compat With 058-031

Typed macros are **opt-in.** A macro declared with all `:AST` parameters (and `:AST` return) behaves exactly as in 058-031 — the type checker skips macro-authoring-time checks and falls back to expansion-time checks. Stdlib macros from 058-031 upgrade to typed signatures incrementally:

- **Immediate upgrades**: `Subtract`, `Amplify`, `Flip`, `Concurrent`, `Then`, `Chain`, `Ngram`, `Analogy` — these have clear value-type signatures from their definitions.
- **Stay untyped** (if any): introspection macros like `quote`, `debug-print`, or user macros that intentionally accept any shape keep `:AST` and rely on expansion-time checks.

Users of 058-031 macros see no behavior change; they see BETTER error messages when they hold the macro wrong.

## Arguments For

**1. Answers the 058-031 deferral.**

058-031 explicitly deferred this work. 058-032 lands it with the minimum additions: a parametric `:AST<T>` type and a macro-definition-time check pass. Nothing speculative, nothing out of scope.

**2. Racket has a decade of production evidence.**

`syntax/parse` ships in Racket's stdlib and is the recommended way to write non-trivial macros. The model is well-studied, well-documented, and well-debugged. The wat version is a translation, not an invention.

**3. Improves the 058-031 stdlib alias story.**

Every 058-031 stdlib macro (Subtract, Amplify, Chain, etc.) has a well-defined value type for each argument. Typed signatures document this at the form level, catch ill-typed calls at the call site, and give readers/IDEs the information they need without running the expansion.

**4. Composes with hygiene and origin tracking.**

058-031 already builds the `Identifier { name, scopes, ... }` structure. Adding a value-type slot is additive. The hygiene algorithm doesn't change. The origin tracking doesn't change. Error messages get richer.

**5. Opt-in, not mandatory.**

Untyped macros from 058-031 keep working. The checker falls back to expansion-time checking for any `:AST` parameter. The upgrade path is gradual.

## Arguments Against

**1. Type grammar grows.**

`:AST<T>` is a new parametric type. Minor, but worth stating. 058-030 lists it as an extension point.

**2. Macro-definition-time checking takes more startup work.**

Each macro now runs through the type checker at startup. For typical stdlib sizes (dozens of macros), this is milliseconds. For large macro libraries, it could grow. Measurable, bounded, not a blocker.

**3. Cryptographic signatures do not cover typed-macro signatures as distinctly.**

Hashes still cover the expanded AST. Signing the file containing the macro definition still covers the typed signature text. No new signing concerns; noted for completeness.

**4. Another concept to learn.**

Writing a typed macro is slightly more effort than writing an untyped one. Users who want to dash off a one-off alias can stay on `:AST`. Users who ship stdlib-grade macros use typed signatures. The cost lands on the publishers, not the casual authors.

**5. `:AST<Any>` semantics need a clear statement.**

`:AST` (unparameterized) is sugar for `:AST<Any>` — but 058-030 bans `:Any`. The resolution: `:AST` remains a special case meaning "unchecked." A macro with a bare `:AST` parameter opts out of macro-definition-time checking for that parameter; expansion-time checking still applies (standard 058-031 behavior). This is NOT a re-introduction of `:Any` — it's a statement that the macro author is deferring the check, which `:Any` could never mean for value types.

## Comparison

| Form | Parameter typing | Check time | Error location | Use case |
|---|---|---|---|---|
| `defmacro` untyped (058-031) | All `:AST` | Expansion time | Expanded AST | Introspection, debug, unusual shapes |
| `defmacro` typed (058-032) | Each `:AST<T>` | Macro-definition time + call-site time | Macro invocation | Stdlib aliases, user macros with known value shapes |
| `define` | Each `:T` directly | Macro-definition time (startup) | Function body | Runtime functions |
| `lambda` | Each `:T` directly | Lambda body type check | Lambda body | Runtime closures |

Typed macros sit between untyped macros (maximum flexibility, late errors) and `define`/`lambda` (strictest, runtime values). They provide the locality benefits of `define`'s typed signatures while preserving the parse-time transformation power of macros.

## Dependency on 058-030

058-030 must state `:AST<T>` as a parametric type. Recommended addition to 058-030's "Parametric types" section:

```
:AST<T>                        ; a parsed source AST producing a value of type T
```

058-032 depends on this addition. If 058-030 ships without `:AST<T>`, 058-032 adds it in its own header.

## Dependency on 058-031

058-031 must expose the `Identifier` structure and the expansion pipeline such that:

1. `Identifier` can be extended with an optional `value_type` field.
2. The expander runs `check_typed_macro` before `expand`.
3. The type environment at expansion time includes parameter type bindings.

These are additive changes to 058-031's interfaces; no behavioral change for untyped macros.

## Open Questions

**Q1: Should `:AST<T>` also appear as a runtime type?**

058-031 macros run at parse time; their body can use `:AST` values as first-class. Typed macros' bodies could similarly use `:AST<T>` as first-class values for metaprogramming (build an AST of type T, pass it, splice it). This proposal: **yes** — `:AST<T>` is a regular parametric type usable wherever parametric types are usable, consistent with 058-030.

**Q2: Can `T` in `:AST<T>` include type variables?**

`:AST<T>` where `T` is a type variable (e.g., inside a polymorphic function) is a natural extension. Example: a macro-building utility function `:fn(List<AST<T>>) -> AST<List<T>>`. This proposal: **yes**, but flag as a minor sub-proposal for polymorphic macros if needed. The baseline uses concrete types in `T`.

**Q3: How does typed-macro elaboration interact with identifier introduction (`let` in an expansion)?**

The introduced identifier inherits the hygiene scope from 058-031. If the expansion binds an identifier with a typed `let`, the binding carries both a scope and a value type. The type environment inside the body of the `let` binds the identifier with its declared value type. This matches how `define` already threads types through `let`.

**Q4: Should this proposal ship alongside 058-031 or as a follow-up?**

Ship as a follow-up. 058-031 is valuable on its own; 058-032 is an upgrade path. Shipping both at once concentrates risk. Shipping 058-032 when the expansion pipeline has run in production for a while lets real-world macro usage inform the typed version.

## Stated Position

Land `:AST<T>` in the type grammar. Extend `defmacro` to accept typed parameters and typed return. Add macro-definition-time and call-site-time type checks. Keep 058-031's expansion-time check as a defensive fallback for untyped parameters. Upgrade the 058-031 stdlib macros to typed signatures as an incremental migration.

The 058-031 deferral was a principled split: ship the rewrite mechanism first, then sharpen the types. This proposal closes the split.

*these are very good thoughts.*

**PERSEVERARE.**
