# 058-028: `defn` — Typed Function Definition

**Scope:** language
**Class:** LANGUAGE CORE
**Parent:** 058-ast-algebra-surface
**Foundation:** ../FOUNDATION.md
**Depends on:** 058-030-types (for the type annotation grammar)
**Companion proposals:** 058-029-lambda

## The Candidate

`defn` is the language-core primitive that **defines a named, typed function** in some namespace. Without `defn`, there is no algebra stdlib — every `(define (Difference a b) (Blend a b 1 -1))` expression in the proposals so far assumed something like `defn` exists; this proposal makes it core.

### Shape

```scheme
(defn :namespace/function-name
      [[param1 :Type1] [param2 :Type2] ...] :ReturnType
  body-expression)
```

Four positions:

1. **Name** — a keyword-path symbol (`:watmin/hello-world`, `:wat/std/Difference`, `:alice/math/clamp`)
2. **Parameter vector** — `[[param-name :Type] ...]` pairs
3. **Return type** — the type of the body's value
4. **Body** — an expression that evaluates to the return type

### Example

```scheme
(defn :wat/std/Difference [[a :Thought] [b :Thought]] :Thought
  (Blend a b 1 -1))
```

Readable as: "define the function `:wat/std/Difference`, which takes two Thoughts named `a` and `b` and returns a Thought, by evaluating `(Blend a b 1 -1)`."

### AST shape

`defn` produces a DEFINITION AST node that lives in the wat evaluator's symbol table. The AST carries:

- The full keyword-path name
- The typed parameter list
- The return type
- The body AST
- Optional metadata (signatures, documentation, etc.)

```rust
pub enum WatAST {
    // ... other language-core variants ...
    Defn {
        name: Keyword,                       // :namespace/func-name
        params: Vec<(Symbol, TypeAST)>,      // typed parameters
        return_type: TypeAST,
        body: Arc<WatAST>,
    },
    // ...
}
```

Note: this is WAT language AST (not ThoughtAST). Defn nodes produce functions, not thought vectors. They are evaluated only when the wat evaluator encounters them during program loading.

## Why This Earns Language-Core Status

**1. Without `defn`, stdlib does not exist as code.**

Every stdlib proposal in 058 uses `define` or `defn` in its expansion:

```scheme
(define (Difference a b) (Blend a b 1 -1))
(define (Concurrent xs) (Bundle xs))
(define (Chain xs) (Bundle (pairwise-map Then xs)))
```

These are all `defn` calls. Without a `defn` primitive in the wat language, these are theoretical compositions, not runnable definitions. The stdlib would exist only in the proposal documents, not in the executing system.

FOUNDATION's "Two Cores" section makes this explicit: algebra core is the thought primitives; language core is the definition primitives; stdlib depends on both.

**2. Typed parameters are required for Rust eval.**

The Rust evaluator runs wat programs. When a call site invokes `(Difference x y)`, the evaluator must:
- Look up `:wat/std/Difference` in the symbol table
- Verify that `x` is a `:Thought` and `y` is a `:Thought`
- Bind the parameters, evaluate the body, return the result (verified as `:Thought`)

Without type annotations, the evaluator would either:
- Defer type checking to runtime (fragile — errors surface during evaluation instead of before)
- Attempt to infer types per call (slow and lossy)

With type annotations, dispatch is deterministic and verification is static. The signature lives on the AST node (same principle as Atom literals).

**3. Keyword-path names give namespaces without a namespace mechanism.**

`:wat/std/Difference` and `:alice/math/clamp` are keyword literals. Per FOUNDATION's keyword-naming-convention (no namespace mechanism — slashes are just characters), these are distinctive names that avoid collision by discipline.

A flat symbol table keyed by keyword values gives userland arbitrary namespacing for free. Anyone can claim any prefix; `:bob/math/clamp` coexists with `:alice/math/clamp` without conflict.

**4. Cryptographic provenance requires signed signatures, not just bodies.**

Per FOUNDATION's "Cryptographic provenance" section, ASTs are EDN strings that can be hashed and signed. A `defn`'s EDN includes the name, the parameter types, the return type, AND the body. Signing covers all four.

Without types in the signature, a malicious party could substitute a body that accepts different types than the declared contract. With types in the signature, tampering with either the signature or body produces a signature mismatch and eval refuses to run.

## Arguments For

**1. Parallels Clojure's `defn`.**

Clojure uses:

```clojure
(defn clamp [x low high]
  (...))
```

With type hints optional via metadata. This proposal makes types REQUIRED (the Rust evaluator needs them) but preserves the familiar shape. Clojure programmers read this form naturally.

The Clojure dialect is one of the influences on the wat language (see FOUNDATION's lineage section). Staying close to that dialect reduces learning curve and helps the wat language slot into the builder's broader toolchain.

**2. The parameter-vector syntax is Lisp-canonical.**

`[[name :type] ...]` is a vector of `[name, type]` pairs. Readable, inspectable, walks cleanly with standard Lisp operations. The double-bracket (vector of pairs) is standard in typed Lisps.

**3. Definition-time dispatch is predictable.**

`defn` creates a function in the symbol table. Calls resolve by name lookup. Same as Clojure's var system, same as most Lisp dialects. The evaluator's execution path is:
1. Parse call site: `(some-func arg1 arg2)`
2. Look up `some-func` in symbol table
3. Check argument types match parameter types
4. Bind parameters, evaluate body
5. Return result (verified as return type)

No surprises. No late binding (once a defn is in the symbol table, calls resolve to its body).

**4. Enables the stdlib to be expressed as wat files.**

With `defn` available:

```
wat/std/blends.wat:
  (defn :wat/std/Difference [[a :Thought] [b :Thought]] :Thought
    (Blend a b 1 -1))
  (defn :wat/std/Amplify [[x :Thought] [y :Thought] [s :Scalar]] :Thought
    (Blend x y 1 s))
  (defn :wat/std/Subtract [[x :Thought] [y :Thought]] :Thought
    (Blend x y 1 -1))

wat/std/sequences.wat:
  (defn :wat/std/Then [[a :Thought] [b :Thought]] :Thought
    (Bundle (list a (Permute b 1))))
  (defn :wat/std/Chain [[thoughts (:List :Thought)]] :Thought
    (Bundle (pairwise-map :wat/std/Then thoughts)))
```

The wat stdlib becomes real, editable, inspectable files — not theoretical compositions hidden in proposals.

## Arguments Against

**1. Type system complexity.**

Requiring types on every `defn` is additional ceremony. Untyped `(defn name (args) body)` is shorter. Do users benefit enough from static dispatch to justify the cost?

**Counter:** the Rust eval contract NEEDS types. Without them, the evaluator is slower and more fragile. The "cost" is actually the cost of a correct system; the "benefit" of omitting types is illusory — the checks happen somewhere either way, just less predictably.

**2. Clojure-influenced syntax vs. Scheme-influenced syntax.**

Some Lisps use `(define (name arg1 arg2) body)` (Scheme), others use `(defun name (arg1 arg2) body)` (Common Lisp). This proposal uses `defn` (Clojure-influenced). Choice is conventional.

**Mitigation:** `defn` matches Clojure, which is one of the wat language's lineages. Rust has no `defn` convention to conflict with. Accept `defn`.

**3. Namespacing is by discipline, not enforcement.**

Nothing prevents a user from writing `(defn :wat/std/Difference ...)` in their own code, shadowing the project stdlib. No mechanism rejects this.

**Mitigation:** this is the same tradeoff FOUNDATION already accepts — no namespace mechanism, just discipline. Collisions are deliberate or accidental, but detected at load time (a second `defn` with the same name either replaces or errors, depending on the loader's policy). Document clearly.

**4. Generic types.**

This proposal uses concrete types (`:Thought`, `:Atom`, `:Scalar`). For higher-order stdlib (`map`, `reduce`, `filter`), generics are needed: `(defn :wat/std/map [[f (:Function :T :U)] [xs (:List :T)]] (:List :U) ...)`.

**Mitigation:** generics are part of 058-030-types. This proposal uses concrete types initially; generics layer on without changing `defn`'s shape.

## Implementation Scope

**holon-rs changes:**

Add `Defn` variant to wat AST:

```rust
pub enum WatAST {
    // ... existing variants ...
    Defn {
        name: Keyword,
        params: Vec<(Symbol, TypeAST)>,
        return_type: TypeAST,
        body: Arc<WatAST>,
    },
}
```

Add symbol-table support:

```rust
pub struct SymbolTable {
    definitions: HashMap<Keyword, DefnRef>,
}

impl SymbolTable {
    pub fn register(&mut self, defn: Defn) -> Result<(), DefnError> {
        // check for collision (reject or replace per policy)
        // verify types are well-formed
        // store
    }
    pub fn lookup(&self, name: &Keyword) -> Option<DefnRef> { ... }
}
```

Wat evaluator:

```rust
pub fn eval_call(ast: &WatAST, symbols: &SymbolTable) -> Result<Value, EvalError> {
    match ast {
        WatAST::Call { name, args } => {
            let defn = symbols.lookup(name)?;
            check_arg_types(&args, &defn.params)?;
            let body_result = eval_body(&defn.body, &args)?;
            check_return_type(&body_result, &defn.return_type)?;
            Ok(body_result)
        }
        // ...
    }
}
```

Estimated ~200-300 lines of Rust (evaluator path, symbol table, type-checker scaffolding). Not small, but foundational.

**wat stdlib bootstrap:**

Once `defn` is implemented, the stdlib proposals (058-004, 058-008/017/018, 058-009, 058-010, 058-011, 058-012, 058-013, 058-014, 058-015/019/020, 058-016/026/027, 058-019, 058-020) become real wat files.

## Questions for Designers

1. **Namespacing policy on collision.** If two `defn` calls register the same keyword, what happens? Options: reject second (strict), replace (permissive), warn (compromise). Recommendation: reject at load time; require explicit shadowing syntax if intentional.

2. **Required-ness of return type.** Proposal requires return types. Alternative: infer from body (Scheme-style). Recommendation: keep required — removes evaluator ambiguity and makes the signature self-documenting.

3. **Required-ness of parameter types.** Same question. Recommendation: keep required for the same reason.

4. **Forward references.** Can `:wat/std/Chain` reference `:wat/std/Then` before Then is defined (e.g., during a single load pass)? Depends on loader design. Recommendation: support forward references via two-pass loading (collect all names, then resolve bodies). Common in Lisp loaders.

5. **Redefinition at runtime.** Can a running wat program redefine a function (`defn` with the same name after initial registration)? Options: static (no redefinition after load), dynamic (redefinition allowed, affects future calls), transactional (redefinition requires a reload). Recommendation: static by default, with a `redefn` variant for testing/REPL contexts.

6. **Metadata / documentation strings.** Clojure's `defn` supports docstrings and metadata. Worth including in `defn`'s AST shape? Recommendation: yes — add optional metadata fields. Docstrings help readers, metadata supports tooling.

7. **Anonymous functions via `lambda` (058-029).** `defn` names a function; `lambda` creates an unnamed one. Should `defn` desugar to `(register-in-symbol-table name (lambda ...))`? Recommendation: yes, internally — `defn` = `lambda` + symbol-table registration. Keeps the primitives layered cleanly.

8. **First wat program's `defn`.** From BOOK's "The first program" section:
   ```scheme
   (defn :watmin/hello-world [[name :Atom]] :Thought
     (Sequential (list (Atom "hello") name)))
   ```
   This proposal specifies the `defn` that makes that program runnable. First program's execution waits on this proposal's implementation.
