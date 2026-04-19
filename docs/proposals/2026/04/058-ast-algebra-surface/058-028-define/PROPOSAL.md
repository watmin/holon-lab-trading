# 058-028: `define` — Typed Function Definition

**Scope:** language
**Class:** LANGUAGE CORE
**Parent:** 058-ast-algebra-surface
**Foundation:** ../FOUNDATION.md
**Depends on:** 058-030-types (for the type annotation grammar)
**Companion proposals:** 058-029-lambda

## The Candidate

`define` is the language-core primitive that **defines a named, typed function** in some namespace. Without `define`, there is no algebra stdlib — every `(define (Difference a b) (Blend a b 1 -1))` expression in the stdlib proposals needs this primitive to exist; this proposal makes it core.

`define` is the existing name in wat's LANGUAGE.md. This proposal extends the existing form with required type annotations, keyword-path names, and cryptographic hashing — consistent with FOUNDATION's Model A static-loading architecture.

### Shape

```scheme
(:wat/core/define (:namespace/function-name (param1 :Type1) (param2 :Type2) ... -> :ReturnType)
  body-expression)
```

Four positions:

1. **Name** — a keyword-path value (`:watmin/hello-world`, `:wat/std/Difference`, `:alice/math/clamp`)
2. **Parameter list** — `(name :Type)` pairs; name is a bare symbol, type is a keyword
3. **Return type** — `-> :Type` inside the parameter list's closing paren
4. **Body** — an expression that evaluates to the return type

### Example

```scheme
(:wat/core/define (:wat/std/Difference (a :Holon) (b :Holon) -> :Holon)
  (:wat/algebra/Blend a b 1 -1))
```

Readable as: "define the function `:wat/std/Difference`, which takes two Holons named `a` and `b` and returns a Holon, by evaluating `(Blend a b 1 -1)`."

### AST shape

`define` produces a DEFINITION AST node that registers into the wat-vm's static symbol table during startup. The AST carries:

- The full keyword-path name
- The typed parameter list
- The return type
- The body AST
- Optional metadata (documentation strings)

```rust
pub struct Define {
    name: Keyword,                       // :namespace/func-name
    params: Vec<(Symbol, TypeAST)>,      // typed parameters
    return_type: TypeAST,
    body: Arc<WatAST>,
    docstring: Option<Arc<str>>,
}
```

Registered by name in the startup symbol table. After startup completes, the symbol table is frozen — no more `define`s register during the wat-vm's lifetime.

## Why This Earns Language-Core Status

**1. Without `define`, stdlib does not exist as code.**

Every stdlib proposal in 058 uses `define` in its expansion:

```scheme
(:wat/core/define (:wat/std/Difference a b) (:wat/algebra/Blend a b 1 -1))
(:wat/core/define (:wat/std/Concurrent xs) (:wat/algebra/Bundle xs))
(:wat/core/define (:wat/std/Chain xs) (:wat/algebra/Bundle (pairwise-map :wat/std/Then xs)))
```

Without a `define` primitive in the wat language, these are theoretical compositions, not runnable definitions.

FOUNDATION's "Two Cores" section makes this explicit: algebra core is the holon primitives; language core is the definition primitives; stdlib depends on both.

**2. Typed parameters are required for static dispatch and cryptographic signing.**

Under Model A, the wat-vm resolves symbols, type-checks, and verifies cryptographic signatures at startup — before the main loop runs. For the type checker to function:

- Each parameter's type must be explicit
- The return type must be explicit
- The body must produce the declared return type

Without types, the static verification pass cannot complete. With types, signatures are machine-checked; wrong-type calls fail before execution.

Type annotations are also part of the cryptographic signature. The hash of a `define` covers its name, parameter types, return type, AND body. Tampering with any part — including the type declarations — changes the hash and invalidates signatures.

**3. Keyword-path names give namespacing without a namespace mechanism.**

`:wat/std/Difference` and `:alice/math/clamp` are keyword literals. Per FOUNDATION's naming-convention guidance (no namespace MECHANISM; slashes are just characters), these are distinctive names that avoid collision by discipline.

Anyone can claim any prefix; `:bob/math/clamp` coexists with `:alice/math/clamp` in the same program (or fails at startup if both load the same name). The collision detection runs at startup and halts the wat-vm if ambiguity is found.

## Arguments For

**1. Aligns with existing wat.**

Current wat LANGUAGE.md already lists `define` as a host Lisp form. This proposal extends the existing form:
- Old: `(define (name args) body)` with optional type hints
- New: `(define (:namespace/name (arg :Type) ... -> :ReturnType) body)` with required types and keyword-path names

Backwards-incompatible in principle, but the pre-058 wat has no deployed stdlib authored with the old syntax — this is the polish pass before stdlib gets written.

**2. The parameter-vector syntax is Lisp-canonical.**

`(name :Type)` is readable, inspectable, walks cleanly with standard Lisp operations. Parenthesized sublists match wat's honest Lisp surface — all grouping is parens.

**3. Static-dispatch is predictable and fast.**

Under Model A, `define` registers at startup. Calls resolve through a fixed symbol table via name lookup. The evaluator's execution path is:
1. Parse call site: `(some-func arg1 arg2)`
2. Look up `some-func` in the static symbol table
3. Check argument types match parameter types
4. Bind parameters, evaluate body
5. Return result (verified as return type at startup, not re-checked per call)

No dynamic lookup; no runtime type probing; no late binding an attacker can hijack.

**4. Enables stdlib as real wat files.**

With `define` available:

```
wat/std/blends.wat:
  (define (:wat/std/Difference (a :Holon) (b :Holon) -> :Holon)
    (Blend a b 1 -1))
  (define (:wat/std/Amplify (x :Holon) (y :Holon) (s :f64) -> :Holon)
    (Blend x y 1 s))
  (define (:wat/std/Subtract (x :Holon) (y :Holon) -> :Holon)
    (Blend x y 1 -1))

wat/std/sequences.wat:
  (define (:wat/std/Then (a :Holon) (b :Holon) -> :Holon)
    (Bundle (list a (Permute b 1))))
  (define (:wat/std/Chain (holons :List<Holon>) -> :Holon)
    (Bundle (pairwise-map :wat/std/Then holons)))
```

The wat stdlib becomes real, editable, inspectable files.

## Arguments Against

**1. Type system ceremony.**

Requiring types on every `define` adds verbosity. Untyped `(define (name args) body)` is shorter. Do users benefit enough from static dispatch to justify the cost?

**Counter:** under Model A, the wat-vm REQUIRES types for startup verification. Without them, cryptographic signatures cannot cover function signatures meaningfully, and type-check failures surface at runtime instead of startup. The "cost" is actually the cost of a correct system; the "benefit" of omitting types is illusory — the checks happen somewhere either way, just less predictably.

**2. Namespacing is by discipline, not enforcement.**

Nothing prevents a user from writing `(define (:wat/std/Difference ...) ...)` in their own code, duplicating the project stdlib name.

**Counter:** this is the same tradeoff FOUNDATION already accepts — no namespace mechanism, just discipline. Collisions halt startup (name collision is a boot error in Model A), so silent shadowing is impossible. The programmer sees the error and reconciles at the source level.

**3. Generic types.**

This proposal uses concrete types (`:Holon`, `:Atom`, `:f64`). For higher-order stdlib (`map`, `reduce`, `filter`), generics are needed: `(define (:wat/std/map (f :fn(T)->U) (xs :List<T>) -> :List<U>) ...)`.

**Counter:** generics are part of 058-030-types. This proposal uses concrete types initially; generics layer on without changing `define`'s shape.

## Implementation Scope

**holon-rs changes (wat-vm):**

Add `Define` variant to wat AST:

```rust
pub enum WatAST {
    // ... existing variants ...
    Define {
        name: Keyword,
        params: Vec<(Symbol, TypeAST)>,
        return_type: TypeAST,
        body: Arc<WatAST>,
        docstring: Option<Arc<str>>,
    },
}
```

Startup registrar:

```rust
pub fn register_define(ast: &Define, table: &mut SymbolTable, types: &TypeEnv) -> Result<(), BootError> {
    // 1. Verify all parameter types exist in TypeEnv
    for (_, t) in &ast.params {
        types.resolve(t)?;
    }
    types.resolve(&ast.return_type)?;

    // 2. Type-check the body (recursively)
    let body_type = type_check_expr(&ast.body, &ast.params, types, table)?;

    // 3. Verify body type matches declared return type
    if !types.subtype_of(&body_type, &ast.return_type) {
        return Err(BootError::ReturnTypeMismatch { ... });
    }

    // 4. Verify no name collision
    if table.contains(&ast.name) {
        return Err(BootError::NameCollision(ast.name.clone()));
    }

    // 5. Register
    table.register(ast.name.clone(), Arc::new(Function::from_ast(ast)))
}
```

After startup completes, `table.freeze()` prevents further registrations.

Call dispatch at runtime:

```rust
pub fn eval_call(name: &Keyword, args: &[Value], table: &SymbolTable, env: &Environment) -> Result<Value, EvalError> {
    let f = table.lookup(name).ok_or(EvalError::UnknownFunction)?;
    check_arg_types_runtime(&args, &f.params)?;  // cheap — types were verified at startup
    let mut new_env = Environment::child_of_global(table);
    for ((name, _), v) in f.params.iter().zip(args) {
        new_env.bind(name.clone(), v.clone());
    }
    eval(&f.body, &new_env, table)
}
```

Estimated ~200-300 lines of Rust (evaluator path, symbol table, type-checker scaffolding).

**wat stdlib bootstrap:**

Once `define` is implemented (alongside `lambda` per 058-029 and types per 058-030), the stdlib proposals become real wat files loaded via `(load ...)` at startup.

## Questions for Designers

1. **Name collision policy.** If two `define` calls in loaded files share a name, startup halts with an error. Is this the right policy, or should there be an explicit `(redefine ...)` form for intentional shadowing? Recommendation: strict collision error by default; explicit shadowing is a later addition if needed.

2. **Required-ness of return type.** Proposal requires return types. Alternative: infer from body (Scheme-style). Recommendation: keep required — removes evaluator ambiguity and makes the signature self-documenting.

3. **Required-ness of parameter types.** Same question. Recommendation: keep required for the same reason.

4. **Forward references.** Can `:wat/std/Chain` reference `:wat/std/Then` before Then is defined (e.g., in a single load pass)? Since all loading happens at startup before the symbol table freezes, forward references are natural: the resolver runs after all parsing but before type-checking. Recommendation: support forward references within the startup phase; they do not complicate Model A.

5. **Metadata / documentation strings.** Clojure's `defn` supports docstrings and metadata. Worth including in `define`'s AST shape? Recommendation: yes — optional metadata field. Docstrings help readers; metadata supports tooling.

6. **Anonymous functions via `lambda` (058-029).** `define` names a function; `lambda` creates an unnamed one. `define` can be viewed as `lambda` + startup-time symbol-table registration. Keep the primitives layered cleanly.

7. **First wat program.** From BOOK's "The first program" section:

   ```scheme
   (:wat/core/define (:watmin/hello-world (name :Atom) -> :Holon)
     (:wat/std/Sequential (:wat/core/list (:wat/algebra/Atom "hello") name)))
   ```

   This proposal specifies the `define` that makes that program runnable. The first program's execution waits on this proposal's implementation plus 058-029 and 058-030.
