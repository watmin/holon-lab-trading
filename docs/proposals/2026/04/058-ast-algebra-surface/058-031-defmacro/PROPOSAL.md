# 058-031: `defmacro` — Compile-Time Syntactic Expansion

**Scope:** language
**Class:** LANGUAGE CORE
**Parent:** 058-ast-algebra-surface
**Foundation:** ../FOUNDATION.md
**Depends on:** 058-030-types
**Companion proposals:** 058-028-define (contrast), multiple stdlib aliases now reframed as macros

## The Candidate

`defmacro` is a **compile-time language-core form** that registers a syntactic transformation. Unlike `define`, which creates a runtime function, `defmacro` defines a rewriter: it takes a source-level form and returns its canonical replacement BEFORE any evaluation, hashing, caching, or signing occurs.

```scheme
(:wat::core::defmacro (:namespace::macro-name (arg1 :AST<T1>) (arg2 :AST<T2>) ... -> :AST<R>)
  body-expression)
```

The body is a Lisp expression that evaluates AT PARSE TIME to produce a new AST. The resulting AST replaces the invocation.

Every macro parameter carries a concrete value type `T` via the `:AST<T>` wrapper (per 058-032). `T` is the value type the argument expression must produce — `:holon::HolonAST`, `:f64`, `:Vec<holon::HolonAST>`, etc. Bare `:AST` without `<T>` is not a valid parameter type; the language enforces the same discipline on macros as on every other typed position.

## Why This Form Exists

This proposal responds directly to Beckman's finding #4 (alias hash collision) from the designer review.

**The problem:**

Stdlib aliases like `Concurrent`, `Set`, `Subtract`, `Flip`, `Then`, `Chain` all expand to compositions of core primitives. Under the naive `(define (Alias ...) (Primitive ...))` encoding, the source AST retains the alias name as a distinct node:

```scheme
(:wat::std::Concurrent xs)    → AST: (Call :wat::std::Concurrent (xs))   hash: H1
(:wat::std::HashSet xs)       → AST: (Call :wat::std::HashSet (xs))      hash: H2
(:wat::algebra::Bundle xs)    → AST: (Call :wat::algebra::Bundle (xs))   hash: H3
```

All three produce the same vector (elementwise threshold sum). But they have three distinct hashes. FOUNDATION's claim — `hash(AST) IS the holon's identity` — becomes contradictory: **same meaning, different identities.**

**The resolution:**

If `Concurrent` and `Set` are MACROS rather than functions, they expand at parse time to their canonical form BEFORE hashing:

```scheme
(:wat::std::Concurrent xs)    → parser sees macro call → expands
                            → AST becomes: (Call :wat::algebra::Bundle (xs))
                            → hash: H3 (same as (:wat::algebra::Bundle xs) directly)

(:wat::std::HashSet xs)       → same expansion path → AST: (Call :wat::algebra::Bundle (xs))
                            → hash: H3

(:wat::algebra::Bundle xs)    → no macro expansion needed → AST: (Call :wat::algebra::Bundle (xs))
                            → hash: H3
```

All three have the same hash. `hash(AST) IS identity` holds. The reader clarity provided by `Concurrent` and `Set` at source level is preserved; the semantic identity at the algebra level is unified.

## The Two-Way Distinction

`define` vs `defmacro` is a fundamental split in language-core:

| Form | Timing | What it produces | Body runs | Arguments | Hashed as |
|---|---|---|---|---|---|
| `define` | Registers at startup; body runs at CALL time | A runtime function | Each invocation | Evaluated before call | A named call node with the function's name |
| `defmacro` | Registers at parse time; body runs at PARSE time | A syntactic transformer | Once per invocation, during parsing | Passed as AST (unevaluated) | Whatever the macro expands to |

**Key properties of `defmacro`:**

- **Parse-time expansion** — the macro body runs during parsing, not during evaluation.
- **Argument is the AST** — unlike function calls where arguments are evaluated first, macro arguments arrive as parsed ASTs (quoted forms).
- **Result replaces the invocation** — the macro's return value is an AST that entirely replaces the `(macro-call args)` site.
- **Result is then parsed again** — if the expansion contains another macro invocation, that gets expanded too (nested macros).
- **No runtime cost** — after parsing, the macro's call site no longer exists. The AST contains only the expansion.

## Shape

`defmacro` uses the **same signature syntax as `define` and `lambda`** — every parameter typed with a concrete value type, return type explicit. One consistent signature form across all three definition primitives. Macros use `:AST<T>` (per 058-032) rather than bare `:T` because the parameter arrives unevaluated at parse time; `T` still commits to the evaluation type.

```scheme
(:wat::core::defmacro (:namespace::macro-name (param1 :AST<T1>) (param2 :AST<T2>) ... -> :AST<R>)
  expansion-body)
```

The `expansion-body` is a Lisp expression. It can use:

- The parameter names (each bound to the AST of the corresponding argument)
- Lisp list-building primitives to construct the replacement AST
- Quasiquote (`` ` ``), unquote (`,`), and unquote-splicing (`,@`) for convenient template construction
- Other macros (which expand in turn)

### Examples

**Pure alias — Concurrent:**

```scheme
(:wat::core::defmacro (:wat::std::Concurrent (xs :AST<List<holon::HolonAST>>) -> :AST<holon::HolonAST>)
  `(:wat::algebra::Bundle ,xs))

;; User writes:
(:wat::std::Concurrent (:wat::core::vec a b c))

;; Parser expands:
(:wat::algebra::Bundle (:wat::core::vec a b c))
```

**Transforming — Subtract:**

```scheme
(:wat::core::defmacro (:wat::std::Subtract (x :AST<holon::HolonAST>) (y :AST<holon::HolonAST>) -> :AST<holon::HolonAST>)
  `(:wat::algebra::Blend ,x ,y 1 -1))

;; User writes:
(:wat::std::Subtract a b)

;; Parser expands:
(:wat::algebra::Blend a b 1 -1)
```

**Parameterized — Amplify:**

```scheme
(:wat::core::defmacro (:wat::std::Amplify (x :AST<holon::HolonAST>) (y :AST<holon::HolonAST>) (s :AST<f64>) -> :AST<holon::HolonAST>)
  `(:wat::algebra::Blend ,x ,y 1 ,s))

;; User writes:
(:wat::std::Amplify a b 2)

;; Parser expands:
(:wat::algebra::Blend a b 1 2)
```

**Higher-order expansion — Chain:**

```scheme
(:wat::core::defmacro (:wat::std::Chain (holons :AST<List<holon::HolonAST>>) -> :AST<holon::HolonAST>)
  `(:wat::algebra::Bundle (pairwise-map :wat::std::Then ,holons)))

;; User writes:
(:wat::std::Chain (:wat::core::vec a b c d))

;; Parser expands:
(:wat::algebra::Bundle (pairwise-map :wat::std::Then (:wat::core::vec a b c d)))

;; which further expands Then:
(:wat::algebra::Bundle (pairwise-map
         (:wat::core::lambda ((a :holon::HolonAST) (b :holon::HolonAST) -> :holon::HolonAST)
           (:wat::algebra::Bundle (:wat::core::vec a (:wat::algebra::Permute b 1))))
         (:wat::core::vec a b c d)))
```

The final form contains only algebra core operations. No stdlib-alias function calls survive into the hashed AST.

## Why This Earns Language-Core Status

**1. It is required to resolve finding #4 without losing reader clarity.**

Without macros, we have two choices: drop the aliases (simplest but costs source-level clarity) or accept the hash collision (breaks FOUNDATION's identity claim). Macros give us both — aliases at source, canonical form at hash.

**2. It is the Lisp-tradition answer to source-to-AST transformation.**

Every Lisp since the 1960s has had macros. Common Lisp, Scheme, Racket, Clojure, Emacs Lisp. The mechanism is well-understood: hygienic or unhygienic, parameter-as-AST, expand-and-reparse. Choosing NOT to include macros would be a departure from Lisp tradition, not a minimalism.

**3. It is orthogonal to the holon algebra.**

`defmacro` doesn't construct holon vectors; it constructs source ASTs. It operates at the language level, alongside `define`, `lambda`, `struct`, `enum`, `newtype`, `typealias`, `load!`. Orthogonal to algebra core.

**4. It is interpretable by the Rust-backed wat-vm.**

Macro expansion runs at parse time. The wat-vm's parser (or a prior expansion pass) invokes each macro's body, receives the expansion, and substitutes. This is well-established — every Lisp implementation handles macros this way. Estimated implementation cost: ~200-400 lines of Rust, plus the expansion pass in the startup pipeline.

## Expansion Sequence in the Startup Pipeline

Under Model A, startup proceeds:

1. Parse all wat files (source → untyped AST with macro calls intact).
2. **Macro expansion pass** — walk the AST; for every call matching a registered macro name, invoke the macro's body with the argument ASTs; substitute the expansion; repeat until no macro calls remain. *(New pass; this proposal.)*
3. Resolve symbols (function names, type names — all now either concrete or from macro-generated code).
4. Type-check `define`/`lambda` bodies against the type environment.
5. Compute hashes of the fully-expanded AST.
6. Verify cryptographic signatures (on the expanded form).
7. Register verified `define`s into the static symbol table.
8. Freeze symbol table and type environment.
9. Enter main loop.

**Step 2 is the new insertion.** Macros are registered at build time (same mechanism as type declarations — loaded via `(:wat::core::load! ...)` or embedded in compiled-in stdlib). The expansion pass walks every source AST and rewrites until fixpoint.

## Cryptographic Implications

**Signatures are computed on the EXPANDED form.**

If a user signs a wat file containing `(Concurrent xs)`, the signature is over the text that includes the macro invocation. Verification recomputes the signature over the same text. This works cleanly — the signature matches.

But the HASH used in the content-addressed symbol table (per FOUNDATION's Model A loading) is computed on the EXPANDED AST. Two source files — one using `Concurrent`, one using `Bundle` — that resolve to identical expanded ASTs will have:

- **Different file signatures** (the text differs)
- **Same expanded-AST hash** (the semantics are identical)

This is the correct behavior. Signing guarantees "this file was produced by this author." Hashing the expanded AST identifies holons by their canonical semantic content.

**An attacker cannot craft a malicious macro** that would pass signature verification and produce unexpected behavior. Macros are loaded at build time via the verified `(:wat::core::load! ...)` (or equivalent) form. Adding a new macro requires signing the file that introduces it. The expansion pass uses only verified macros. There is no path for unverified code to affect expansion.

## Type Checking

Types are checked on the EXPANDED form. A macro's body can produce ill-typed ASTs, but the type checker running after expansion will catch them. The macro writer is responsible for producing well-formed expansions; errors surface at startup type check.

Alternative: check types during macro authoring (requires macro parameters to be typed and the macro body to be typed). This is more sophisticated — closer to typed macros in Racket or template Haskell. Out of scope for this proposal; minimal version checks the expanded form.

## Hygiene — Racket's Sets-of-Scopes Model

Macro expansion must be **safe by construction.** A macro author cannot introduce a capture bug — variable-capture-free hygiene is a language guarantee, not a discipline.

### The model

Every identifier in the AST carries a **set of scopes** (Flatt, 2016 — the modern Racket expander model). Two identifiers are "the same" if and only if they have the same name AND the same scope set. When a macro introduces a new identifier (a `let`-bound variable in its expansion, say), the expander attaches a fresh scope to that identifier. User-supplied identifiers keep their original scopes. Name collision between macro-introduced and user-supplied identifiers becomes impossible because their scope sets differ.

### Data model

```rust
#[derive(Clone, PartialEq, Eq, Hash)]
pub struct ScopeId(u64);                      // fresh integer per macro invocation

#[derive(Clone, PartialEq, Eq, Hash)]
pub struct Identifier {
    pub name: Keyword,                        // e.g., `tmp`, `let`, `my/fn`
    pub scopes: BTreeSet<ScopeId>,            // the scope set
}

pub enum WatAST {
    Ref(Identifier),                          // a bare identifier (reference)
    Call(Identifier, Vec<WatAST>),            // function/macro call
    Let(Vec<(Identifier, WatAST)>, Vec<WatAST>),  // binding form
    // ... other nodes carry Identifier not raw strings
}
```

Every node that holds a name holds an `Identifier` — not a bare string. Every `Identifier` carries its scope set.

### The algorithm

1. **At macro invocation**, the expander generates a fresh `ScopeId` (the **macro scope**).
2. The macro's template is walked. Any identifier in the template that **originates from the macro's own source** has the macro scope added to its scope set. Identifiers that came from the macro's **arguments** (user-supplied) retain their original scope sets.
3. Binding forms (`let`, `lambda`, `define`) in the expanded code attach the macro scope to the identifier they bind AND to all references to that identifier within their body scope. Correct binder resolution follows from scope-set equality.
4. **Reference resolution** looks up bindings by `(name, scope_set)` pairs. The same name with different scope sets resolves to different bindings (or is an unbound reference error).

Matthew Flatt's 2016 paper — *"Binding as Sets of Scopes"* — is the reference implementation model. Racket uses it in production.

### Why it works

```scheme
;; Macro introduces `tmp`:
(:wat::core::defmacro (:my::vocab::swap-thoughts (a :AST<holon::HolonAST>) (b :AST<holon::HolonAST>) -> :AST<holon::HolonAST>)
  `(:wat::core::let ((tmp ,a))          ; `tmp` here has macro-scope M
     (set! ,a ,b)
     (set! ,b tmp)))

;; User writes:
(:wat::core::let ((tmp :my-thought))    ; `tmp` here has user-scope U (outer lexical scope)
  (:my::vocab::swap-thoughts tmp other-var))

;; After expansion:
(:wat::core::let ((tmp[U] :my-thought))                 ; user's tmp retains U
  (:wat::core::let ((tmp[M] tmp[U]))                    ; macro's tmp gets M; references user's U
    (set! tmp[U] other-var)                           ; user's tmp — resolved via U
    (set! other-var tmp[M])))                         ; macro's tmp — resolved via M
```

`tmp[U]` and `tmp[M]` are DIFFERENT identifiers even though both print as `tmp`. The expander's internal representation distinguishes them. Capture is structurally impossible.

### Why NOT Clojure's `#`-gensym

Clojure's `name#` auto-gensym rule is simpler to implement but leaves a foot-gun: if the author forgets to add `#` to an introduced binding, capture silently occurs. Racket's sets-of-scopes model removes the foot-gun — the author writes natural code and the expander guarantees safety.

**For wat, correct-by-construction beats one-rule-to-remember.** The Rust implementation carries a `BTreeSet<ScopeId>` on every `Identifier`. Scope-set operations are cheap (small set union, equality check). The expander allocates scope IDs as fresh integers. Macros cannot introduce capture bugs, at all, ever.

### Implementation cost estimate

~300-500 additional lines on top of the basic macro expander:
- `Identifier` type with scope-set field (~30 lines)
- Scope generator (monotonic `u64` counter, ~20 lines)
- Template walker that tracks "came from macro source" vs "came from macro argument" (~100 lines)
- Binding-form handlers that attach scopes during let/lambda/define expansion (~100 lines)
- Reference resolver using (name, scope-set) (~50 lines)
- Tests + error reporting (~100-200 lines)

Matches holon-rs's engineering rigor elsewhere. Rust's type system helps — scope sets are a data type with `#[derive(PartialEq, Eq, Hash)]`; the expander passes them around without indirection.

## Debugging — Source Positions Carried on Scope-Tracked Identifiers

Since every `Identifier` carries a scope set, and scope IDs are allocated fresh per macro invocation, the expander knows the **origin** of every identifier in an expanded AST. Error messages and stack traces can point at:

- The macro invocation (the call site the user wrote)
- The macro definition (the template that introduced the identifier)
- The chain of expansions (for nested macros)

```rust
pub struct ScopeInfo {
    pub id: ScopeId,
    pub origin: Origin,                       // Macro invocation site + source position
}

pub enum Origin {
    MacroInvocation {
        macro_name: Keyword,
        invocation_site: SourcePosition,      // where the user wrote the macro call
        macro_definition: SourcePosition,     // where the macro was defined
    },
    UserCode {
        source_position: SourcePosition,      // where the user wrote this code directly
    },
}
```

A runtime error in `(Blend x y 1 -1)` (from a `(Subtract x y)` macro invocation) can produce an error message:

```
Error: type mismatch at Blend's third argument
  Location: (Blend x y 1 -1)
  From macro: Subtract
    Defined at: wat/std/idioms.wat:42
    Invoked at: my-app.wat:7
```

The user sees the Subtract they wrote AND the Blend expansion AND the macro's definition. Debugging is source-map-complete by virtue of the hygiene infrastructure — we built the scope-tracking data; surfacing it in error messages is a small additional cost.

Full implementation: ~100 extra lines across the expander and error reporting. Source positions are already tracked by the parser; extending them into Origin is mechanical.

## Provenance — Macro-Set Versioning and Distributed Consensus

FOUNDATION's distributed-verifiability claim assumes two nodes producing the same AST produce the same hash. With `defmacro`, the "same AST" depends on the macro set running on each node.

**Lock the project stdlib macro set as part of the algebra version.** Specifically:

1. **Project stdlib macros** (Chain, Ngram, Analogy, Subtract, Amplify, Flip, Log, Circular, HashMap, Vec, HashSet) are defined in `wat/std/*.wat` files shipped with the algebra release. The content-addressed symbol table is seeded with these macros at wat-vm startup. Two nodes running **the same algebra version** have **bit-identical stdlib macros** — guaranteed by versioning, not by coincidence.

2. **User macros** (`:my::vocab::*`) are expanded locally. Their expansions produce hashes that are VALID LOCALLY. A receiving node that wants to verify a hash produced by a user macro must either:
   - Receive the user macro's definition alongside (and expand it the same way), OR
   - Receive the **pre-expanded AST** (the hash's source) directly, bypassing the user macro

3. **Distributed consensus operates on the expanded AST**, not on the source + macro-set pair. Nodes ship ASTs, not source-with-macros. Source is a convenience for authoring; ASTs are the ground truth for verification.

4. **Macro-set upgrades are coordinated events**, like algebra-version upgrades. A node running algebra v1.2 with stdlib-macros v1.2 cannot verify hashes produced by a node running v1.3 if the stdlib macros changed. This is the honest cost of defmacro's parse-time rewriting. Document it; don't pretend it's invisible.

**Version gate in the algebra header.** The wat-vm's startup manifest includes an `algebra-version: "v1.2"` tag. Loading a file signed under a different algebra version requires explicit opt-in (or explicit upgrade path). This is standard cryptographic-protocol versioning, not novel to wat.

## Typed Macros — Completed in 058-032

058-031 alone is an INCOMPLETE type story. Parameters were drafted as `:AST` — a placeholder that said "some parsed expression" without committing to its evaluation type. That placeholder is dishonest: every other typed position in the language carries a concrete type commitment (058-030 bans `:Any` for exactly this reason). A macro parameter is no exception.

**058-032 completes the type story.** It adds `:AST<T>` to the type grammar, mandates it for every macro parameter, and runs a type check at macro-definition time under a type environment where each parameter is bound to its declared `T`. Bare `:AST` without `<T>` is retired as a parameter type. Errors surface at the macro invocation, naming the parameter that failed.

058-031 and 058-032 read as one design:

- 058-031 ships the mechanism — parse-time rewriting, hygiene, origin tracking.
- 058-032 ships the types — concrete parameter types, macro-definition-time check, call-site check.

Neither stands alone. 058-031's `:AST<T>` examples above reflect the typed discipline that 058-032 mandates; they ship typed from day one, not as a retrofit.

## Arguments For

**1. Resolves #4 without compromising reader clarity.**

The central reason. Without macros, `Concurrent`, `Set`, `Array`-as-alias, `Unbind` must either be dropped (lost clarity) or kept with collision (broken identity). Macros preserve both.

**2. Enables future metaprogramming without redesign.**

Beyond aliases, macros support: conditionals based on configuration (`(when-feature :foo ...)`), DSL construction, compile-time optimizations, proof transformations. Not in scope for 058, but the primitive is already there once we land this.

**3. Minimal implementation cost.**

Macro expansion is a well-understood pass. Rust crates exist (`syn`, `quote` — though these target Rust, the patterns translate). Custom implementation for wat is ~200-400 lines.

**4. Lisp-family alignment.**

Every major Lisp has macros. Clojure's `defmacro` is idiomatic and familiar. Common Lisp, Scheme, Racket — all have macro systems. Wat without macros would feel incomplete as a Lisp.

## Arguments Against

**1. Startup-time complexity.**

A macro expansion pass adds a step to startup. On the order of milliseconds for typical stdlib sizes. Not a blocker; worth naming.

**2. Debugging expanded forms.**

When a macro expansion has a bug, errors appear in the EXPANSION, not in the user's source. Requires tooling support: show the expansion when diagnosing errors, include source location in expanded nodes, etc. Standard Lisp problem with well-known solutions (source maps, expansion tracing).

**3. Macro hygiene.**

Classical Lisp macros can accidentally capture variable names. `(defmacro swap (x y) `(let ((tmp ,x)) (set! ,x ,y) (set! ,y tmp)))` — `tmp` might collide with a caller's variable. Hygienic macros (Scheme-style) avoid this via automatic renaming. This proposal: start with unhygienic macros (simpler); add hygiene if collision issues emerge in practice.

**4. Complicates the compile-time story slightly.**

Model A already had a careful compile-time vs runtime story (types compile-time, functions runtime, load!). Adding macros introduces one more compile-time form. Still clean; just one more concept.

**5. Interaction with types.**

If macros can expand to arbitrary forms, the type checker sees a different AST than the source. Good for keeping source readable; requires the type checker to work on the expanded form (standard in languages with macros).

## Comparison

| Form | Category | Timing | What runs | What's hashed |
|---|---|---|---|---|
| `define` | Runtime fn | Call time | Body | Function name + signature |
| `lambda` | Runtime fn (anon) | Call time | Body | Lambda AST |
| `struct`/`enum`/`newtype`/`typealias` | Compile-time type | Build time | N/A (declarative) | Type name + shape |
| `load!` | Startup | Startup | Reads file, registers all toplevel forms | Files covered at startup |
| `defmacro` | Compile-time macro | Parse time | Expansion body (at parse) | The EXPANDED form (not the macro call) |

`defmacro` is the only form that operates at parse time, producing syntactic transformations.

## Algebraic Question

Does `defmacro` compose with the existing algebra?

It is orthogonal to the algebra. The algebra is about holons and operations on holons. `defmacro` is about source-to-source rewriting — a meta-level concern. The two layers don't interact directly.

Is it a distinct source category?

Yes — it's the one language-core form that runs at parse time rather than startup or runtime.

## Simplicity Question

Is this simple or easy?

Simple. One form. One rule (parse-time rewrite). One clear criterion for when it applies (source aliases that should collapse to canonical forms).

Is anything complected?

Nothing beyond what Lisp macros always have: the parse-time/runtime distinction. The Lisp tradition has dealt with this cleanly for 60 years.

Could existing forms express it?

No. `define` registers runtime functions; `defmacro` registers parse-time rewriters. Different categories.

## Implementation Scope

**Rust (wat-vm) changes:**

- Add `Macro` variant to compile-time AST:

```rust
pub enum WatCompileTimeAST {
    // ... existing compile-time forms ...
    Defmacro {
        name: Keyword,
        params: Vec<Symbol>,
        body: Arc<WatAST>,
    },
}
```

- Add macro registry:

```rust
pub struct MacroRegistry {
    macros: HashMap<wat::core::keyword, Arc<Macro>>,
}

pub struct Macro {
    name: Keyword,
    params: Vec<Symbol>,
    body: Arc<WatAST>,
}
```

- Add expansion pass:

```rust
pub fn expand_macros(ast: &mut WatAST, registry: &MacroRegistry) -> Result<(), ExpansionError> {
    // Walk AST. For each Call node:
    //   If name is in registry, expand.
    //   Continue until fixpoint.
    // Error if expansion depth exceeds limit (prevents infinite recursion).
}
```

Estimated ~200-400 lines of Rust (registry, expansion pass, error reporting with source locations).

**wat stdlib bootstrap:**

Once `defmacro` lands, the stdlib alias proposals get rewritten from `(define ...)` to `(defmacro ...)`. See companion task to reshape ~13-14 proposals.

## Questions for Designers

1. **Hygiene.** Should macros be hygienic (automatic variable renaming to prevent capture) or unhygienic (user-managed)? Recommendation: start unhygienic (simpler); add hygiene via gensym or per-macro-namespace if collision issues emerge.

2. **Recursion.** Can a macro invoke itself? Yes (standard). Expansion limit (e.g., 1000 recursive rewrites) prevents infinite loops at expansion time.

3. **Typed macros.** Resolved in 058-032. Every macro parameter is `:AST<T>` with a concrete value type — same discipline as every other typed position in the language. Bare `:AST` without `<T>` is retired, matching 058-030's no-`:Any` rule. Macro-definition-time type checking runs before expansion; call-site checking names the parameter by its declared type.

4. **Introspection.** Should userland code be able to see what a macro call expands to? Useful for debugging. Recommendation: yes, via `(macroexpand form)` — returns the fully-expanded AST without evaluation. Classical Lisp feature.

5. **Signature-verification over expansion.** Should the hash used for cryptographic identity be on the expanded AST (per FOUNDATION's Model A) or on the source AST? Recommendation: expanded AST. Two semantically-identical source files should have the same content identity. Source signatures are a separate concern (author identity vs. content identity).

6. **Stdlib aliases as macros — complete list.** Which stdlib forms become macros? Companion proposal rewrite list:
   - 058-010 Concurrent
   - 058-011 Then
   - 058-012 Chain
   - 058-013 Ngram
   - 058-014 Analogy
   - 058-015 Amplify (parameterized)
   - 058-019 Subtract
   - 058-020 Flip
   - 058-024 Unbind
   - 058-026 Array (if kept; else drop per Hickey's review)
   - 058-027 Set (if kept; else drop)
   - 058-008/017/018 Linear/Log/Circular (scalar-encoder reframings)
   - 058-009 Sequential (reframing — becomes macro expanding to Bundle-of-Permutes)

   Roughly 13-14 proposals change classification from "stdlib `define`" to "stdlib `defmacro`." Content is almost unchanged; just the form-level definition.

## Resolving Beckman's Finding #4

This proposal directly resolves finding #4 from the designer review. The "alias hash-collision" concern evaporates once:

1. `defmacro` is core.
2. All stdlib aliases are rewritten as macros.
3. Expansion runs before hashing.

Confirmed: `hash(AST) IS the holon's identity` holds as an invariant after expansion. Source-level clarity (`Concurrent`, `Set`, `Subtract`, etc.) is preserved for readers; canonical semantic identity is preserved for the algebra and cryptography.
