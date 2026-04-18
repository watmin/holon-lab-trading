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
(defmacro :namespace/macro-name [arg1 : AST] [arg2 : AST] ... -> :AST
  body-expression)
```

The body is a Lisp expression that evaluates AT PARSE TIME to produce a new AST. The resulting AST replaces the invocation.

## Why This Form Exists

This proposal responds directly to Beckman's finding #4 (alias hash collision) from the designer review.

**The problem:**

Stdlib aliases like `Concurrent`, `Set`, `Subtract`, `Flip`, `Then`, `Chain` all expand to compositions of core primitives. Under the naive `(define (Alias ...) (Primitive ...))` encoding, the source AST retains the alias name as a distinct node:

```scheme
(Concurrent xs)    → AST: (Call :wat/std/Concurrent (xs))   hash: H1
(Set xs)           → AST: (Call :wat/std/Set (xs))          hash: H2
(Bundle xs)        → AST: (Call :wat/std/Bundle (xs))       hash: H3
```

All three produce the same vector (elementwise threshold sum). But they have three distinct hashes. FOUNDATION's claim — `hash(AST) IS the thought's identity` — becomes contradictory: **same meaning, different identities.**

**The resolution:**

If `Concurrent` and `Set` are MACROS rather than functions, they expand at parse time to their canonical form BEFORE hashing:

```scheme
(Concurrent xs)    → parser sees macro call → expands
                   → AST becomes: (Call :wat/algebra/Bundle (xs))
                   → hash: H3 (same as (Bundle xs) directly)

(Set xs)           → same expansion path → AST: (Call :wat/algebra/Bundle (xs))
                   → hash: H3

(Bundle xs)        → no macro expansion needed → AST: (Call :wat/algebra/Bundle (xs))
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

`defmacro` uses the **same signature syntax as `define` and `lambda`** — every parameter typed `: AST`, return type `-> :AST`. One consistent signature form across all three definition primitives. Omission would be easier (less to write) but not simpler (introduces a special rule for macros that differs from define/lambda).

```scheme
(defmacro :namespace/macro-name [param1 : AST] [param2 : AST] ... -> :AST
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
(defmacro :wat/std/Concurrent [xs : AST] -> :AST
  `(Bundle ,xs))

;; User writes:
(Concurrent [a b c])

;; Parser expands:
(Bundle [a b c])
```

**Transforming — Subtract:**

```scheme
(defmacro :wat/std/Subtract [x : AST] [y : AST] -> :AST
  `(Blend ,x ,y 1 -1))

;; User writes:
(Subtract a b)

;; Parser expands:
(Blend a b 1 -1)
```

**Parameterized — Amplify:**

```scheme
(defmacro :wat/std/Amplify [x : AST] [y : AST] [s : AST] -> :AST
  `(Blend ,x ,y 1 ,s))

;; User writes:
(Amplify a b 2)

;; Parser expands:
(Blend a b 1 2)
```

**Higher-order expansion — Chain:**

```scheme
(defmacro :wat/std/Chain [thoughts : AST] -> :AST
  `(Bundle (pairwise-map Then ,thoughts)))

;; User writes:
(Chain [a b c d])

;; Parser expands:
(Bundle (pairwise-map Then [a b c d]))

;; which further expands Then:
(Bundle (pairwise-map
         (lambda ([a : Thought] [b : Thought] -> :Thought)
           (Bundle (list a (Permute b 1))))
         [a b c d]))
```

The final form contains only algebra core operations. No stdlib-alias function calls survive into the hashed AST.

## Why This Earns Language-Core Status

**1. It is required to resolve finding #4 without losing reader clarity.**

Without macros, we have two choices: drop the aliases (simplest but costs source-level clarity) or accept the hash collision (breaks FOUNDATION's identity claim). Macros give us both — aliases at source, canonical form at hash.

**2. It is the Lisp-tradition answer to source-to-AST transformation.**

Every Lisp since the 1960s has had macros. Common Lisp, Scheme, Racket, Clojure, Emacs Lisp. The mechanism is well-understood: hygienic or unhygienic, parameter-as-AST, expand-and-reparse. Choosing NOT to include macros would be a departure from Lisp tradition, not a minimalism.

**3. It is orthogonal to the thought algebra.**

`defmacro` doesn't construct thought vectors; it constructs source ASTs. It operates at the language level, alongside `define`, `lambda`, `struct`, `enum`, `newtype`, `deftype`, `load`, `load-types`. Orthogonal to algebra core.

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

**Step 2 is the new insertion.** Macros are registered at build time (same mechanism as type declarations — loaded via `load-macros "path.wat"` or embedded in compiled-in stdlib). The expansion pass walks every source AST and rewrites until fixpoint.

## Cryptographic Implications

**Signatures are computed on the EXPANDED form.**

If a user signs a wat file containing `(Concurrent xs)`, the signature is over the text that includes the macro invocation. Verification recomputes the signature over the same text. This works cleanly — the signature matches.

But the HASH used in the content-addressed symbol table (per FOUNDATION's Model A loading) is computed on the EXPANDED AST. Two source files — one using `Concurrent`, one using `Bundle` — that resolve to identical expanded ASTs will have:

- **Different file signatures** (the text differs)
- **Same expanded-AST hash** (the semantics are identical)

This is the correct behavior. Signing guarantees "this file was produced by this author." Hashing the expanded AST identifies thoughts by their canonical semantic content.

**An attacker cannot craft a malicious macro** that would pass signature verification and produce unexpected behavior. Macros are loaded at build time via the verified `load-macros` (or equivalent) form. Adding a new macro requires signing the file that introduces it. The expansion pass uses only verified macros. There is no path for unverified code to affect expansion.

## Type Checking

Types are checked on the EXPANDED form. A macro's body can produce ill-typed ASTs, but the type checker running after expansion will catch them. The macro writer is responsible for producing well-formed expansions; errors surface at startup type check.

Alternative: check types during macro authoring (requires macro parameters to be typed and the macro body to be typed). This is more sophisticated — closer to typed macros in Racket or template Haskell. Out of scope for this proposal; minimal version checks the expanded form.

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

Model A already had a careful compile-time vs runtime story (types compile-time, functions runtime, load vs load-types). Adding macros introduces one more compile-time form. Still clean; just one more concept.

**5. Interaction with types.**

If macros can expand to arbitrary forms, the type checker sees a different AST than the source. Good for keeping source readable; requires the type checker to work on the expanded form (standard in languages with macros).

## Comparison

| Form | Category | Timing | What runs | What's hashed |
|---|---|---|---|---|
| `define` | Runtime fn | Call time | Body | Function name + signature |
| `lambda` | Runtime fn (anon) | Call time | Body | Lambda AST |
| `struct`/`enum`/`newtype`/`deftype` | Compile-time type | Build time | N/A (declarative) | Type name + shape |
| `load`/`load-types` | Startup | Startup | Reads file, registers | Files covered at startup |
| `defmacro` | Compile-time macro | Parse time | Expansion body (at parse) | The EXPANDED form (not the macro call) |

`defmacro` is the only form that operates at parse time, producing syntactic transformations.

## Algebraic Question

Does `defmacro` compose with the existing algebra?

It is orthogonal to the algebra. The algebra is about thoughts and operations on thoughts. `defmacro` is about source-to-source rewriting — a meta-level concern. The two layers don't interact directly.

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
    macros: HashMap<Keyword, Arc<Macro>>,
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

3. **Typed macros.** Should macro parameters have types? Recommendation: yes — every parameter is explicitly typed `: AST`, and the return is explicitly `-> :AST`. One consistent signature syntax across `define`, `lambda`, and `defmacro` (omission would be easier but not simpler). Semantic type checking of the expansion body still happens after expansion — the signature annotations document the parse-time contract.

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

Confirmed: `hash(AST) IS the thought's identity` holds as an invariant after expansion. Source-level clarity (`Concurrent`, `Set`, `Subtract`, etc.) is preserved for readers; canonical semantic identity is preserved for the algebra and cryptography.
