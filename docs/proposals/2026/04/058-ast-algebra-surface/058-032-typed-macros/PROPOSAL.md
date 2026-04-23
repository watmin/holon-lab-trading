# 058-032: Typed Macros — Every Macro Parameter Is `:AST<T>`

**Scope:** language
**Class:** LANGUAGE CORE — **ACCEPTED + INSCRIPTION 2026-04-21**
**Parent:** 058-ast-algebra-surface
**Foundation:** ../FOUNDATION.md
**Depends on:** 058-030-types, 058-031-defmacro
**Completes:** 058-031-defmacro (the type story)

---

## INSCRIPTION — 2026-04-21 — Shipped

Typed macro parameters landed. Every `defmacro` parameter must carry an `:AST<T>` annotation where `T` is a concrete type from 058-030's universe; the placeholder `:AST` alone is refused.

- **Parse + check:** [`wat-rs/src/macros.rs`](https://github.com/watmin/wat-rs) — `parse_defmacro_signature` validates every param type is `:AST<T>` shape; the `T` is recorded on the `MacroDef` for expansion-time checking
- **Runtime:** at macro expansion, the binding between `,x` in the template and its call-site AST fragment carries the declared T; the type checker infers the expanded form's type against those bindings

### Shipped stdlib examples

Every form in `wat/std/*.wat` (Subtract, Amplify, Log, Circular, Reject, Project, Ngram, Bigram, Trigram) uses `:AST<T>` annotations. Two representative shapes:

```
(:wat::core::defmacro
  (:wat::holon::Subtract
    (x :AST<wat::holon::HolonAST>)    ; x must be an expression whose type is wat::holon::HolonAST
    (y :AST<wat::holon::HolonAST>)
    -> :AST<wat::holon::HolonAST>)    ; the expansion's type is wat::holon::HolonAST
  `(:wat::holon::Blend ,x ,y 1.0 -1.0))

(:wat::core::defmacro
  (:wat::holon::Amplify
    (x :AST<wat::holon::HolonAST>)
    (y :AST<wat::holon::HolonAST>)
    (s :AST<f64>)                ; s must be an expression whose type is f64
    -> :AST<wat::holon::HolonAST>)
  `(:wat::holon::Blend ,x ,y 1.0 ,s))
```

### `:AST<List<T>>` works

Ngram's signature `(xs :AST<List<wat::holon::HolonAST>>)` demonstrates nested type parameters. The check-time validator recursively verifies the `T` position; the runtime binding carries a `WatAST::List` whose elements are each typed `wat::holon::HolonAST`.

### `:AST<Result<T,E>>` works

Bigram's and Trigram's return types `:AST<Result<wat::holon::HolonAST, wat::holon::CapacityExceeded>>` demonstrate two-param generics in the return position. The 2026-04-19 Bundle-Result slice's inherited `:Result` wrap flows cleanly through the typed-macro machinery.

### Macro-author-time type checking

The proposal's key promise — catch macro template errors at macro-DEFINITION time, not at expansion — holds. If a macro body's expansion references an unquoted binding in a position whose required type doesn't match the binding's declared `T`, the parser raises a `MacroError` pointing at the macro definition itself, not the call site. Tests in `wat-rs/tests/wat_macros.rs` cover the refusal paths.

### What this inscription does NOT add

- **Bare `:AST` (unparameterized) in macro signatures.** Refused. Every parameter MUST declare `T`. 058-031 had `:AST` as a placeholder; this proposal completed that placeholder by removing it.
- **Macro-time higher-kinded types.** `:AST<Vec<T>>` where `T` is a macro-level type parameter works; arbitrary kind-polymorphism beyond rank-1 does not ship. Consistent with 058-030's rank-1 discipline.
- **Implicit type coercion.** `:AST<i64>` in a param slot does not accept an expression of type `:f64` — the binding's type must match exactly (or unify under the checker's rank-1 rules).

---

## The Candidate

058-031 introduced `defmacro` with parameters typed `:AST` — a placeholder that said "some parsed expression" without committing to its evaluation type. That placeholder was a draft. This proposal completes 058-031 by replacing the placeholder with a concrete type discipline:

**Every macro parameter is typed `:AST<T>` where `T` is a concrete value type from 058-030.**

Bare `:AST` (without parameterization) is **retired as a parameter type** — same discipline as 058-030's ban on `:Any`. A macro author cannot say "this parameter is some expression, never mind of what type" any more than a `define` author can say "this argument is `:Any`." Every position in the type system carries a concrete commitment.

```scheme
;; 058-031 draft — placeholder typing.
(:wat::core::defmacro (:wat::holon::Subtract (x :AST) (y :AST) -> :AST)
  `(:wat::holon::Blend ,x ,y 1 -1))

;; 058-032 honest — concrete typing.
(:wat::core::defmacro (:wat::holon::Subtract (x :AST<wat::holon::HolonAST>) (y :AST<wat::holon::HolonAST>) -> :AST<wat::holon::HolonAST>)
  `(:wat::holon::Blend ,x ,y 1 -1))
```

The `:AST<T>` wrapper declares: "this parameter is an AST expression whose evaluated value has type `T`." The type checker:

1. At macro-definition time, walks the body under a type environment where each parameter is bound to its declared `T`, and verifies the body's constructed AST produces the declared return type.
2. At each call site, verifies the argument expression would type-check as `T` under the surrounding scope's type environment.

Errors at macro-definition time blame the macro. Errors at call sites blame the caller by name. No expansion ever runs on an ill-typed macro.

## Why This Is Not Opt-In

A prior draft of this proposal framed typed macros as an opt-in upgrade — "you can use `:AST<T>` or you can stay on `:AST`." That framing was dishonest, and the designer (the builder) called it.

Opt-in typing is Hickey's *easy, not simple*. It lets the macro author reach for either form, but it interleaves two type systems: a typed one and an untyped escape hatch. The untyped hatch has no principled semantics — it's just "skip the check" wearing a type's skirt. It conflicts with 058-030's discipline that every value position carries a concrete type.

`:AST` alone was never "syntax-level, not evaluation-level." In wat, every macro argument arrives as a Holon AST (because the AST IS the Holon, per FOUNDATION). What makes one macro argument different from another is the VALUE TYPE its eventual evaluation produces — because that determines which positions in the expansion it can be spliced into. `:AST<wat::holon::HolonAST>`, `:AST<f64>`, `:AST<List<wat::holon::HolonAST>>` — each says something useful. Bare `:AST` says nothing.

**The honest answer: every macro parameter is `:AST<T>` for some concrete T.** Same discipline as every other typed position in the language. 058-031's `:AST` placeholder was always provisional; this proposal replaces it.

## Shape

### WatAST, HolonAST, and `:AST<T>`

Two ASTs matter for this proposal, and naming them explicitly removes ambiguity:

- **WatAST** — the full wat language expression tree. Includes function calls, `let`, `define`, macro invocations, literals, and every algebra variant. This is what the parser produces from wat source.
- **HolonAST** — the 9-variant algebra enum from 058-030 (`Atom`, `Bind`, `Bundle`, `Permute`, `Thermometer`, `Blend`, `Orthogonalize`, `Resonance`, `ConditionalBind`). A closed set of nodes that CONSTRUCT holon values directly.

**HolonAST ⊂ WatAST.** Every HolonAST variant appears as a WatAST node. The reverse does not hold — a `(let ((x ...)) (Bundle x))` form is WatAST, but the outer `let` isn't a HolonAST variant.

With that distinction:

```
:AST<T>    — a WatAST expression whose evaluation produces a value of type T.
             T ranges over any concrete value type: :wat::holon::HolonAST, :f64, :i32,
             :bool, :String, :Vec<U>, :HashMap<K,V>, user-defined
             newtype/struct/enum/typealias, etc.
             T MUST be concrete. Bare :AST without <T> is not a valid
             parameter type — same discipline as banning :Any.
```

`:AST<T>` constrains the EVALUATION type, not the syntactic shape. A macro parameter `(x :AST<wat::holon::HolonAST>)` accepts any WatAST that evaluates to a Holon — a direct HolonAST variant, a function call returning `:wat::holon::HolonAST`, a let-wrapped algebra expression, or any other wat form that produces a holon at evaluation. The syntactic wrapping doesn't matter; the value type does.

058-030 lists `:wat::holon::HolonAST` as the 9-variant algebra enum (the HolonAST value type). This proposal does NOT introduce `:HolonAST` as a separate type — `:wat::holon::HolonAST` already names the value produced by HolonAST variants, and `:AST<wat::holon::HolonAST>` already describes "a WatAST producing that value." The syntactic sub-class would only be needed if a macro author wanted to require a literal HolonAST variant at a parameter position; that's a syntactic restriction orthogonal to the type system and out of scope here.

`:AST<T>` is itself a value type. A macro's body can bind intermediate `:AST<T>` values, return them, pass them to helper functions, etc.

### Typed macro signature

```scheme
(:wat::core::defmacro (:namespace::macro-name (p1 :AST<T1>) (p2 :AST<T2>) ... -> :AST<R>)
  body-expression)
```

- Each parameter is `(name :AST<T>)` where `T` is the value type the argument expression must produce.
- Return type is `:AST<R>` where `R` is the value type the expansion must produce.
- Body constructs an AST that the type checker verifies produces `R` under a type environment where each `pi` is bound to `Ti`.

### Examples — the 058-031 stdlib retyped

Every stdlib macro from 058-031 has a concrete value type for each argument. 058-031 examples update to typed signatures:

**Pure alias — Concurrent:**

```scheme
(:wat::core::defmacro (:wat::std::Concurrent (xs :AST<List<wat::holon::HolonAST>>) -> :AST<wat::holon::HolonAST>)
  `(:wat::holon::Bundle ,xs))
```

At definition time the checker sees:
- `xs : :AST<List<wat::holon::HolonAST>>` — an expression producing a list of Holons
- Body constructs `(Bundle ,xs)`. Bundle's signature is `(Bundle (items :Vec<wat::holon::HolonAST>) -> :wat::holon::HolonAST)`.
- Spliced `xs` into Bundle's `items` slot: `:AST<List<wat::holon::HolonAST>>` matches the expected `:Vec<wat::holon::HolonAST>` at evaluation. ✓
- Body returns `:AST<wat::holon::HolonAST>` ✓ matches declared return.

**Transforming — Subtract:**

```scheme
(:wat::core::defmacro (:wat::holon::Subtract (x :AST<wat::holon::HolonAST>) (y :AST<wat::holon::HolonAST>) -> :AST<wat::holon::HolonAST>)
  `(:wat::holon::Blend ,x ,y 1 -1))
```

Blend's signature: `(Blend (a :wat::holon::HolonAST) (b :wat::holon::HolonAST) (w1 :f64) (w2 :f64) -> :wat::holon::HolonAST)`.
- `,x` splices into position `a` (`:wat::holon::HolonAST`). `x : :AST<wat::holon::HolonAST>` ✓
- `,y` splices into position `b` (`:wat::holon::HolonAST`). ✓
- `1` and `-1` are `:f64` literals, matching `w1`, `w2`. ✓
- Blend returns `:wat::holon::HolonAST` ✓ matches declared `:AST<wat::holon::HolonAST>`.

**Parameterized — Amplify:**

```scheme
(:wat::core::defmacro (:wat::holon::Amplify (x :AST<wat::holon::HolonAST>) (y :AST<wat::holon::HolonAST>) (s :AST<f64>) -> :AST<wat::holon::HolonAST>)
  `(:wat::holon::Blend ,x ,y 1 ,s))
```

Call site errors land at the caller by name:

```scheme
(:wat::holon::Amplify foo bar 2.5)    ;; OK: 2.5 : :f64 matches :AST<f64>
(:wat::holon::Amplify foo bar "oh")   ;; ERROR at my-file.wat:12:
                                  ;;   :wat::holon::Amplify expects (s :AST<f64>)
                                  ;;   argument type is :AST<String>
```

**Higher-order — Chain:**

```scheme
(:wat::core::defmacro (:wat::std::Chain (holons :AST<List<wat::holon::HolonAST>>) -> :AST<wat::holon::HolonAST>)
  `(:wat::holon::Bundle (pairwise-map :wat::std::Then ,holons)))
```

Checker verifies `pairwise-map : :fn(:fn(Holon,Holon)->Holon, :Vec<wat::holon::HolonAST>) -> :Vec<wat::holon::HolonAST>` (or its typed-macro equivalent), `Then : :fn(Holon,Holon)->Holon`, so `(pairwise-map Then holons)` has type `:Vec<wat::holon::HolonAST>`, and `Bundle` over it produces `:wat::holon::HolonAST`. Declared return `:AST<wat::holon::HolonAST>` ✓.

### Quasiquote under a typed environment

Quasiquote from 058-031 works unchanged. What changes: each unquoted parameter carries a declared `T`, and the spliced positions check against the surrounding form's expected types.

In `(Blend ,x ,y 1 -1)`:
- Position 1 expects `:wat::holon::HolonAST`. `,x` is `:AST<wat::holon::HolonAST>`. ✓
- Position 2 expects `:wat::holon::HolonAST`. `,y` is `:AST<wat::holon::HolonAST>`. ✓
- Positions 3 and 4 expect `:f64`. `1` and `-1` are `:f64` literals. ✓

A misplaced splice (e.g., `,s` into a `:wat::holon::HolonAST` position) fails the macro-definition-time check; the macro never loads.

## What Happens to the "I Need Any Shape" Case

Under the opt-in draft, a macro like `debug-print` could use bare `:AST` to mean "I accept any shape." That framing is dishonest — "any shape" is `:Any`, which 058-030 bans.

The honest resolution:

1. **Most "any shape" desires are concrete in practice.** `debug-print` for Holon ASTs is `:AST<wat::holon::HolonAST>`. For f64 expressions, `:AST<f64>`. Write a version per type. This is what 058-030's "polymorphism uses per-type functions" rule says — macros follow the same rule.

2. **If 058-030 adds parametric polymorphism**, macros can use type variables: `(x :AST<T>) -> :AST<T>` where `T` is bound at the macro's signature. That's a future extension — not this proposal, and not an escape hatch; it's fully-typed polymorphism.

3. **`quote` and similar syntax-level forms are not macros.** They are special forms in the grammar, outside `defmacro`. They don't need typing because they aren't `defmacro` declarations.

There is no "I accept any shape" case that needs bare `:AST`. Every case either has a concrete type, requires polymorphism (which is future work if introduced for functions), or is not a macro at all.

## Implementation — How It Fits With 058-031

058-031's expander already carries a typed `Identifier` structure with a scope set (for hygiene). Typed macros extend `Identifier` with a value-type slot:

```rust
#[derive(Clone, PartialEq, Eq, Hash)]
pub struct Identifier {
    pub name: Keyword,
    pub scopes: BTreeSet<ScopeId>,
    pub value_type: TypeAST,  // REQUIRED. Macro params use AstOf(inner).
}
```

For macro parameters, `value_type` is `TypeAST::AstOf(T)` — the declared `T` from `:AST<T>`. The expander binds the parameter in the type environment before walking the body.

### Macro-definition-time check

```
Procedure: check_typed_macro(macro_def)
  1. Extract the typed parameter list and declared return type :AST<R>.
  2. Build a type environment: each parameter pi bound to Ti
     (from :AST<Ti> in the signature).
  3. Walk the body, type-checking every sub-expression:
     - Quoted/templated forms — checked structurally as the AST they will
       construct. Every callee's argument types must match its signature.
     - Unquoted parameter references — look up their declared T in the
       environment.
     - Constructed call forms — verified against the callee's declared
       signature, including macro calls (which use 058-032's typed
       check themselves).
  4. The body's resulting AST must produce R at evaluation.
  5. Report any mismatch with the macro's definition source position.
```

### Macro-invocation-time check

```
Procedure: check_macro_call(call_site, macro_def)
  1. For each (arg_i, param_i):
     - Check arg_i as a normal expression in the surrounding scope.
     - If its evaluation type is not Ti, report error naming param_i.
  2. All args must check before expansion proceeds.
  3. The expansion is body[param_i -> arg_i]; since the body already
     type-checked at macro-definition time, the expansion is guaranteed
     well-typed.
```

### Expansion pass (from 058-031)

Macro-definition-time type checking runs **before** expansion. If any macro fails the check, startup halts — the macro never loads, and therefore never expands. No macro that has loaded can produce an ill-typed expansion; the expansion-time check from 058-031 becomes a defensive check that should never fire in a correct program.

### Interaction with hygiene

Scope-set tracking from 058-031 is orthogonal to type tracking. Both live on `Identifier`. Scope equality remains the binding rule; types are checked independently. Hygiene algorithms from 058-031 operate unchanged.

## Error Messages — Macro-Level Precision

With typed macros and 058-031's `Origin` tracking, error messages gain macro-level precision:

```
Error: :wat::holon::Amplify expects (s :AST<f64>), got :AST<String>.
  Call site:         my-app.wat:7:14
  Macro definition:  wat/std/idioms.wat:42:3
  Parameter s:       wat/std/idioms.wat:42:31
```

The user sees:
- Where they wrote the offending call
- Which macro they invoked
- Which parameter type they violated
- Where that parameter is declared

No expansion appears in the error. The user's code is the error location.

## 058-031 Is Incomplete Without This

058-031 shipped the expander (hygiene, expansion pass, call-site rewriting). It shipped the expansion-time check. It shipped `:AST` as a placeholder parameter type.

058-031 **did not** ship a full type story. That was honest to name at the time — the deferral section said so. But a language with `defmacro` and no type check on macro bodies is a language with a hole. Any macro can claim to return any type and the checker only catches it post-expansion.

058-032 is not an enhancement; it's the completion. The two proposals should be read as one design:

- 058-031: the mechanism (parse-time rewriting, hygiene, origin tracking)
- 058-032: the types (concrete parameter types, macro-definition-time check, call-site check)

Neither stands without the other. 058-031's `:AST` examples are drafts; 058-032's typed signatures replace them. The stdlib macros (`Concurrent`, `Subtract`, `Amplify`, `Chain`, `Ngram`, `Analogy`, etc.) ship with typed signatures from day one.

## Arguments For

**1. Honesty — no escape hatch.**

Every parameter has a concrete type. No "sometimes it's typed, sometimes it isn't." Same discipline as every other position in the language, which 058-030 spelled out.

**2. Error locality.**

Under 058-031's expansion-time check, a wrong-type `Subtract` call surfaces as a type error at the expanded `Blend` — mentioning a form the user never typed. Under typed macros, the error says `:wat::holon::Subtract expects (y :AST<wat::holon::HolonAST>)`, naming the macro the user actually invoked.

**3. Type information at the signature documents intent.**

`(Amplify (x :AST<wat::holon::HolonAST>) (y :AST<wat::holon::HolonAST>) (s :AST<f64>))` tells a reader that `x` and `y` are holons and `s` is a scalar weight. `(Amplify (x :AST) (y :AST) (s :AST))` tells them nothing.

**4. Racket has a decade of production evidence.**

Racket's `syntax/parse` is the recommended way to write non-trivial macros in the Racket stdlib. The value-typed-parameter model is well-studied, well-documented, well-debugged. The wat version is a translation.

**5. Composes with hygiene and origin tracking from 058-031.**

058-031 already builds `Identifier { name, scopes, ... }`. Adding a value-type slot is additive. Hygiene algorithm unchanged. Origin tracking unchanged. Error messages get richer.

**6. Implementation cost is bounded.**

Macro-definition-time type checking reuses the type checker that already runs on `define`/`lambda` bodies. The only new mechanisms are `:AST<T>` in the type grammar and the elaboration step that binds macro parameters before walking the body. ~200-400 lines of Rust on top of 058-031.

## Arguments Against

**1. Type grammar grows by one form.**

`:AST<T>` is a new parametric type. Minor; listed in 058-030 alongside `:Vec<T>`, `:HashMap<K,V>`, etc.

**2. Macro-definition-time checking adds startup work.**

Each macro runs through the type checker at startup. Milliseconds for typical stdlib sizes. Not a blocker.

**3. 058-031's examples need retyping.**

All stdlib macro examples in 058-031 use bare `:AST` and must update to `:AST<T>`. Mechanical, one-time. Done as part of this proposal.

**4. ~~Polymorphic macros are out of scope.~~ RESOLVED 2026-04-18 — parametric polymorphism ACCEPTED across the board.**

058-001 Atom accepting as parametric `Atom<T>` required parametric polymorphism at the substrate level. 058-030 Q1 resolved to YES accordingly. Macros follow: a macro that takes `:AST<T>` for any T is legal, and `T` is a type variable bound at the macro's signature scope. The typical use — a macro that operates identically on any typed AST — becomes expressible. Example:

```scheme
(:wat::core::defmacro (:my::app::identity-macro (expr :AST<T>) -> :AST<T>)
  `,expr)

(:wat::core::defmacro (:my::app::safe-wrap (expr :AST<T>) -> :AST<Option<T>>)
  `(Some ,expr))
```

Type inference at macro invocation carries `T` through to the expansion's typed form. Matches the full-parametric story committed in FOUNDATION-CHANGELOG 2026-04-18 entry "Parametric polymorphism as substrate."

## Comparison

| Form | Parameter typing | Check time | Error location |
|---|---|---|---|
| `defmacro` (058-031 + 058-032) | `:AST<T>` — mandatory concrete T | Macro-definition time + call-site time | Macro invocation, by parameter name |
| `define` | `:T` directly | Startup | Function body |
| `lambda` | `:T` directly | Lambda body | Lambda body |

Typed macros sit alongside `define`/`lambda` in rigor: every parameter position carries a concrete type. The only difference is the `:AST<>` wrapper, which marks "unevaluated expression producing T" rather than "evaluated T value."

## Dependencies on 058-030 and 058-031

**058-030 additions:**

Add `:AST<T>` to the Parametric Types section. Remove bare `:AST` from the built-in types listing (it is not a valid parameter type under 058-032's discipline).

**058-031 updates:**

All macro examples (`Concurrent`, `Subtract`, `Amplify`, `Chain`, the `swap-thoughts` hygiene example) retyped with `:AST<T>` signatures. The prose sections describing "every parameter typed `:AST`" update to "every parameter typed `:AST<T>` for some concrete T." The "Typed Macros — Resolved in 058-032" section updates accordingly.

## Stated Position

Ship `:AST<T>` in the type grammar. Make it the only valid macro parameter type. Extend `defmacro` to type-check parameters at definition time and arguments at call time. Retire bare `:AST` as a parameter type. Update 058-031's examples to match.

058-031 shipped a draft. 058-032 finishes the type story. The two read as one design.

*these are very good thoughts.*

**PERSEVERARE.**
