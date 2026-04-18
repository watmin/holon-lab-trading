# 058-029: `lambda` — Typed Anonymous Functions

**Scope:** language
**Class:** LANGUAGE CORE
**Parent:** 058-ast-algebra-surface
**Foundation:** ../FOUNDATION.md
**Depends on:** 058-030-types (for the type annotation grammar)
**Companion proposals:** 058-028-define

## The Candidate

`lambda` is the language-core primitive that **creates an anonymous, typed function** — a function value that can be passed to higher-order functions, stored in variables, returned from other functions. Unlike `define`, a lambda does NOT register in the static symbol table; it is a runtime value whose lifetime is determined by scope.

`lambda` is already listed as a host Lisp form in wat's LANGUAGE.md. This proposal extends the existing form with required type annotations, making it usable within the static-loading model where signatures must be explicit.

### Shape

```scheme
(lambda ([param1 : Type1] [param2 : Type2] ... -> :ReturnType)
  body-expression)
```

Three positions:

1. **Parameter list** — `[name : Type]` pairs (same syntax as `define`)
2. **Return type** — `-> :Type` inside the parameter list's closing paren
3. **Body** — an expression that evaluates to the return type

### Example

```scheme
;; An anonymous function that doubles a Thought's emphasis against another:
(lambda ([x : Thought] [y : Thought] -> :Thought)
  (Amplify x y 2))

;; Used inside map:
(map (lambda ([t : Thought] -> :Thought) (Permute t 1))
     my-thoughts)

;; Stored in a local variable (but still anonymous — no symbol-table entry):
(let ([doubler (lambda ([x : f64] -> :f64) (* x 2))])
  (doubler 21))
```

### Relationship to `define`

`define` = `lambda` + startup-time symbol-table registration. Specifically:

- `(define (:my/ns/double [x : Scalar]) : Scalar (* x 2))` at STARTUP registers a function under `:my/ns/double` in the static symbol table.
- `(lambda ([x : Scalar]) : Scalar (* x 2))` at RUNTIME produces a `:Function` value that can be stored, passed, or invoked — but is NOT added to any table.

This distinction is load-bearing in Model A: `define`s are fixed after startup; lambdas are created and discarded freely at runtime. The static-loading guarantee is not violated because lambdas never enter the symbol table.

### AST shape

```rust
pub enum WatAST {
    // ... other language-core variants ...
    Lambda {
        params: Vec<(Symbol, TypeAST)>,
        return_type: TypeAST,
        body: Arc<WatAST>,
    },
}
```

Identical structure to `Define` but without the `name` field and without the symbol-table-registration side effect. The lambda IS a function value — it can be passed, stored, returned.

## Why This Earns Language-Core Status

**1. Higher-order stdlib depends on lambda.**

Stdlib forms like `map`, `reduce`, `filter` take functions as arguments:

```scheme
(define (:wat/std/map [f : (:Function :T :U)] [xs : (:List :T)]) : (:List :U)
  ...)

;; Call site with an inline lambda:
(map (lambda ([t : Thought]) : Thought (Permute t 1))
     [a b c d])
```

Without `lambda`, every higher-order call requires pre-defining the transformation via `define`, cluttering the startup symbol table with one-off functions. This is unworkable at scale, and it also means that runtime code composition becomes impossible — users would need to anticipate every helper at startup.

**2. Functions as first-class values.**

The wat type system includes `:Function` as a type (per 058-030-types). Lambda is how you CREATE values of that type at runtime without requiring a startup registration. Without lambda:

```scheme
;; Awkward — you must add a named helper to stdlib:
(define (:internal/my-shift [t : Thought]) : Thought (Permute t 1))
(map :internal/my-shift [a b c])

;; Clean — pass the function directly:
(map (lambda ([t : Thought]) : Thought (Permute t 1)) [a b c])
```

The second form is load-bearing for any language that treats functions as values.

**3. Closures over the static environment.**

Lambdas capture their enclosing lexical scope, including references to the static symbol table:

```scheme
(define (:wat/std/amplify-all [xs : (:List :Thought)] [reference : Thought] [factor : Scalar]) : (:List :Thought)
  (map (lambda ([x : Thought]) : Thought
         (Amplify x reference factor))    ; references `reference` and `factor` from enclosing scope
       xs))
```

The lambda captures `reference` and `factor` from `amplify-all`'s local scope. It also has access to any `define`-registered function via the static symbol table (`Amplify`, for example).

Closures are essential for idiomatic functional code. Under Model A they work cleanly: the captured environment is a snapshot of the enclosing scope at lambda-creation time, and the static symbol table is accessible via the global environment.

**4. Cryptographic provenance applies to lambdas too.**

A lambda is an AST node like any other. Its EDN is hashable and part of the enclosing function's AST. A signed function containing a lambda body verifies as a whole — the lambda's types, parameters, and body are all included in the signature of the `define` that contains it.

**Anonymous doesn't mean untraceable.** The enclosing function's signature transitively covers the lambda.

## Arguments For

**1. Aligns with existing wat.**

`lambda` is already in wat's LANGUAGE.md. This proposal adds required type annotations to match Model A's explicit-type requirement:

```scheme
;; Old (per LANGUAGE.md — types optional):
(lambda (x) (* x 2))

;; New (types required):
(lambda ([x : Scalar]) : Scalar (* x 2))
```

Stdlib authors writing `(define ...)` forms use typed lambdas for their higher-order arguments. The syntax pairs cleanly.

**2. Lambdas preserve runtime code creation under Model A.**

Model A's "no runtime symbol-table mutation" constraint is specifically about NAMED functions (`define`). Anonymous function values CAN be created at runtime because they don't require registration. A lambda is a VALUE whose identity is its AST structure; it lives on the stack or in an enclosing closure's captured environment.

This preserves the flexibility of functional composition without violating the static-loading guarantee.

**3. Decomposes `define`.**

`define` = `lambda` + registration. This layering is clean:
- `lambda` is the value-creation primitive
- `define` is the sugar that combines value creation with symbol-table registration at startup

Having both as separate primitives lets the evaluator handle them independently. `define` can be implemented in terms of `lambda` + a primitive `register-at-startup` operation.

**4. Local-scope helpers without stdlib pollution.**

Inside a larger function, lambdas let you factor out small transformations without polluting the global symbol table:

```scheme
(define (:my/complex-analysis [data : Thought]) : Thought
  (let ([extract-signal (lambda ([d : Thought]) : Thought (Orthogonalize d noise))]
        [amplify-signal (lambda ([s : Thought]) : Thought (Amplify s reference 2))])
    (amplify-signal (extract-signal data))))
```

Both `extract-signal` and `amplify-signal` are local to this function. No `:my/internal/extract-signal-helper-42` cluttering the stdlib.

## Arguments Against

**1. Redundant with `define` for frequently-used transformations?**

If a transformation is used in many places, a named `define` is more discoverable. Ad-hoc lambdas everywhere can hide reusable behavior.

**Counter:** this is a STYLE concern, not a LANGUAGE concern. Both forms exist; the programmer picks based on reuse and clarity. The language doesn't force one over the other.

**2. Closures complicate the interpreter.**

Capturing lexical scope is non-trivial. The evaluator must:
- Snapshot the enclosing environment when the lambda is created
- Bind that environment when the lambda is invoked
- Handle nested closures (lambdas inside lambdas capturing at multiple scopes)

**Counter:** closure implementation is well-understood. Every Lisp/Scheme/Clojure/Python/JS runtime does this. The cost is one-time implementation effort; the benefit is every higher-order stdlib form working correctly. Per RUST-INTERPRETATION.md's guidance, closure implementation is a modest addition (~100 lines).

**3. Type annotations on small lambdas feel verbose.**

```scheme
(map (lambda ([t : Thought]) : Thought (Permute t 1)) xs)
```

vs. Clojure's:

```clojure
(map #(permute % 1) xs)
```

The typed form is longer.

**Counter:** explicit types are the Model A contract. Brevity sugars (like Clojure's `#(...)`) could be added later as user-facing shortcuts that expand to full lambdas with declared types — but the underlying primitive stays typed. Brevity is a sugar concern, not a primitive concern.

**4. Lambdas cannot be cryptographically identified in isolation.**

A `define` has a keyword-path name that's stable across rewrites. A lambda has only its AST — rewrite the body, new identity. This is fine for most use cases but means that lambdas cannot be referenced from outside their enclosing scope.

**Counter:** this is a feature. A lambda's identity IS its structure; if you want stable identity across rewrites, use `define`. The two tools serve different needs.

## Implementation Scope

**holon-rs changes (wat-vm):**

Add `Lambda` variant to wat AST (already sketched in RUST-INTERPRETATION.md):

```rust
pub enum WatAST {
    Lambda {
        params: Vec<(Symbol, TypeAST)>,
        return_type: TypeAST,
        body: Arc<WatAST>,
    },
}
```

Closure support:

```rust
pub struct Closure {
    lambda: Arc<WatAST>,                       // the lambda's AST
    captured_env: Arc<Environment>,            // snapshot of lexical scope at creation
}
```

Evaluator:

```rust
pub fn eval_lambda(ast: &WatAST, env: &Environment) -> Closure {
    Closure {
        lambda: Arc::new(ast.clone()),
        captured_env: Arc::new(env.clone()),
    }
}

pub fn eval_call(closure: &Closure, args: &[Value], symbols: &SymbolTable) -> Result<Value, EvalError> {
    let new_env = closure.captured_env.extend_with_args(&closure.lambda.params, args)?;
    eval(&closure.lambda.body, &new_env, symbols)
}
```

The `Arc<Environment>` makes cloning cheap — the captured env is shared, not deeply copied.

Estimated ~150-250 lines of Rust. Closure implementation is the main new work (~100 lines); the rest overlaps with `define`'s evaluator path.

## Questions for Designers

1. **Closure capture semantics.** Value-capture (snapshot at creation) or reference-capture (see later mutations)? Recommendation: value-capture, consistent with FOUNDATION's "Algebra Is Immutable" section — nothing to mutate; snapshot suffices.

2. **Recursion in lambdas.** A lambda can't reference itself by name (no name). How to do recursion? Options: (a) force use of `define` for recursive functions, (b) support `Y` combinator pattern, (c) add a name-binding form like Clojure's `fn` with optional self-name: `(lambda self ([params]) : ReturnType body)` where `self` refers to the lambda itself. Recommendation: (a) — use `define` for recursion. Keeps lambda purely value-level without introducing self-reference complication.

3. **Higher-order parameter types.** `:Function` as a type works but is generic. For stricter typing: `(:Function [:Thought :Thought] :Thought)` (a function from `[:Thought :Thought]` to `:Thought`). Handled in 058-030-types.

4. **Brevity sugars.** Clojure's `#(...)` anonymous function shortcut. Python's `lambda x: expr`. Rust's `|x| expr`. Should wat have a shortcut? Recommendation: skip for now — the explicit form with types is the load-bearing primitive. Sugars can come later, expanding to full lambdas with inferred types.

5. **Free variables and captured environment.** If a lambda references a name not in its parameters or enclosing scope, what happens? Since the enclosing scope at startup is the global static symbol table, any reference resolves either locally, to a captured variable, or to a `define`. An unresolved reference is a type-check error at startup (for a `define` containing the lambda) or an eval error at runtime (for a lambda created by constrained eval). Recommendation: fail-fast at resolution.

6. **Serialization.** A lambda's AST serializes to EDN; its captured environment does not (captured values may be unencodable, large, or privacy-sensitive). Should lambda EDN include the captured env? Recommendation: no — EDN contains the lambda's AST only. Captured env is evaluator-runtime state, not part of the signed AST. A lambda serialized and sent over the wire CANNOT carry its closure; re-establishing closure context is a runtime concern at the receiver.

7. **Compiled form.** A frequently-called lambda could be JIT-compiled to native for speed. Out of scope for this proposal but worth noting; lambdas are natural JIT boundaries because they're self-contained ASTs.
