# 058-029: `lambda` — Typed Anonymous Functions

**Scope:** language
**Class:** LANGUAGE CORE
**Parent:** 058-ast-algebra-surface
**Foundation:** ../FOUNDATION.md
**Depends on:** 058-030-types (for the type annotation grammar)
**Companion proposals:** 058-028-defn

## The Candidate

`lambda` is the language-core primitive that **creates an anonymous, typed function** — a function without a name, usable as a value (passed to higher-order functions, stored in data structures, returned from other functions).

### Shape

```scheme
(lambda [[param1 :Type1] [param2 :Type2] ...] :ReturnType
  body-expression)
```

Three positions:

1. **Parameter vector** — `[[param-name :Type] ...]` pairs (same syntax as `defn`)
2. **Return type** — the type of the body's value
3. **Body** — an expression that evaluates to the return type

### Example

```scheme
;; An anonymous function that doubles a Thought's emphasis against another:
(lambda [[x :Thought] [y :Thought]] :Thought
  (Amplify x y 2))

;; Used inside map:
(map (lambda [[t :Thought]] :Thought (Permute t 1))
     my-thoughts)

;; Stored in a variable (but still anonymous — no stdlib registration):
(let [doubler (lambda [[x :Scalar]] :Scalar (* x 2))]
  (doubler 21))
```

### Relationship to `defn`

`defn` = `lambda` + symbol-table registration. Specifically:

```scheme
(defn :my/ns/double [[x :Scalar]] :Scalar (* x 2))

;; ≡

(register :my/ns/double
  (lambda [[x :Scalar]] :Scalar (* x 2)))
```

This is the layering: `lambda` produces a typed function value; `defn` produces that same value AND registers it in the symbol table under a keyword-path name.

### AST shape

```rust
pub enum WatAST {
    // ... other language-core variants ...
    Lambda {
        params: Vec<(Symbol, TypeAST)>,
        return_type: TypeAST,
        body: Arc<WatAST>,
    },
    // ...
}
```

Identical structure to `Defn` but without the `name` field. The lambda IS a function value — it can be passed, stored, returned, compared.

## Why This Earns Language-Core Status

**1. Higher-order stdlib depends on lambda.**

Stdlib forms like `map`, `reduce`, `filter` take functions as arguments:

```scheme
(defn :wat/std/map [[f (:Function :T :U)] [xs (:List :T)]] (:List :U)
  ...)

;; Call site with an inline lambda:
(map (lambda [[t :Thought]] :Thought (Permute t 1))
     [a b c d])
```

Without `lambda`, every higher-order call requires pre-defining the transformation via `defn`, cluttering the symbol table with one-off functions. This is unworkable at scale.

**2. Functions as first-class values.**

The wat type system includes `:Function` as a type (per 058-030-types). Lambda is how you CREATE values of that type inline. Without lambda:

```scheme
;; Awkward — you must define then reference:
(defn :internal/my-shift [[t :Thought]] :Thought (Permute t 1))
(map :internal/my-shift [a b c])

;; Clean — pass the function directly:
(map (lambda [[t :Thought]] :Thought (Permute t 1)) [a b c])
```

The second form is load-bearing for any language that treats functions as values.

**3. Closures for local context.**

Lambdas capture their enclosing lexical scope:

```scheme
(defn :wat/std/amplify-all [[xs (:List :Thought)] [reference :Thought] [factor :Scalar]] (:List :Thought)
  (map (lambda [[x :Thought]] :Thought
         (Amplify x reference factor))    ; references `reference` and `factor` from enclosing scope
       xs))
```

The lambda captures `reference` and `factor` from `amplify-all`'s scope. Closures are essential for idiomatic functional code.

**4. Cryptographic provenance applies to lambdas too.**

A lambda is an AST node like any other. Its EDN is hashable and signable. A signed AST containing a lambda body verifies as a whole — the lambda's types, parameters, and body are all included.

Anonymous doesn't mean untraceable. The hash identifies the specific lambda even without a name.

## Arguments For

**1. Clojure parallel.**

Clojure:

```clojure
(fn [x] (* x 2))
;; or:
#(%1 * 2)   ; anonymous function literal shorthand
```

Typed equivalent:

```scheme
(lambda [[x :Scalar]] :Scalar (* x 2))
```

Same shape minus the types. Staying close to Clojure reduces learning curve.

**2. Scheme parallel.**

Scheme:

```scheme
(lambda (x) (* x 2))
```

Typed version adds explicit parameter and return types. Same concept, more verbose signature.

**3. Decomposes `defn`.**

`defn` = `lambda` + registration. This layering is clean:
- `lambda` is the value-creation primitive
- `defn` is the sugar that combines value creation with symbol-table registration

Having both as separate primitives lets the evaluator handle them independently. `defn` can be implemented in terms of `lambda` + a primitive `register` operation.

**4. Local-scope helpers.**

Inside a larger function, lambdas let you factor out small transformations without polluting the global symbol table:

```scheme
(defn :my/complex-analysis [[data :Thought]] :Thought
  (let [extract-signal (lambda [[d :Thought]] :Thought (Orthogonalize d noise))
        amplify-signal (lambda [[s :Thought]] :Thought (Amplify s reference 2))]
    (amplify-signal (extract-signal data))))
```

Both `extract-signal` and `amplify-signal` are local to this function. No `:my/internal/extract-signal-helper-42` cluttering the symbol table.

## Arguments Against

**1. Redundant with `defn` for non-inline uses.**

If every lambda eventually needs a name for debugging/stacktraces, why not always `defn`?

**Counter:** many lambdas genuinely don't need names. A `map` closure, a comparator, a short predicate — giving each a stdlib name is overhead. Lambda allows local-scope function values without global registration.

**2. Closures complicate the evaluator.**

Capturing lexical scope is non-trivial. The evaluator must:
- Snapshot the enclosing environment when the lambda is created
- Bind that environment when the lambda is invoked
- Handle nested closures (lambdas inside lambdas capturing at multiple scopes)

**Counter:** closure implementation is well-understood. Every Lisp/Scheme/Clojure/Python/JS runtime does this. The cost is one-time implementation effort; the benefit is every higher-order stdlib form working correctly.

**3. Anonymous functions harder to cryptographically identify.**

A `defn` has a keyword-path name that's stable across rewrites (rename the name, lose identity). A lambda is identified only by its AST hash — which changes with any rewrite.

**Counter:** this is a feature. A lambda's identity IS its structure — two lambdas with the same body and types should have the same hash and be interchangeable. If you want stable identity across rewrites, use `defn`.

**4. Type annotations on small lambdas feel verbose.**

```scheme
(map (lambda [[t :Thought]] :Thought (Permute t 1)) xs)
```

vs. Clojure's:

```clojure
(map #(permute % 1) xs)
```

The typed form is longer.

**Counter:** explicit types are the Rust-eval contract (see 058-028-defn's argument 2). Brevity sugars (like Clojure's `#(...)`) could be added later as user-facing shortcuts that expand to full lambdas with inferred types — but the underlying primitive stays typed. Brevity is a sugar concern, not a primitive concern.

## Comparison

| Form | Class | Purpose | Shape |
|---|---|---|---|
| `defn` | LANG CORE (058-028) | Named, registered function | `(defn :name [[params]] :return body)` |
| `lambda` | LANG CORE (this) | Anonymous, inline function | `(lambda [[params]] :return body)` |
| Callable reference | value | Reference to a named defn | `:wat/std/Difference` (as a keyword) |
| Lambda value | value | Reference to an inline lambda | `(lambda ...)` evaluates to a function |

Both produce function values. `defn` also registers the name in the symbol table.

## Implementation Scope

**holon-rs changes:**

Add `Lambda` variant to wat AST:

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
    captured_env: Arc<Environment>,            // snapshot of lexical scope
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

pub fn eval_call(closure: &Closure, args: &[Value]) -> Result<Value, EvalError> {
    let new_env = closure.captured_env.extend_with_args(closure.lambda.params, args)?;
    eval_body(&closure.lambda.body, &new_env)
}
```

Estimated ~150-250 lines of Rust. Closure implementation is the main new work (~100 lines); the rest overlaps with defn's evaluator path.

## Questions for Designers

1. **Closure capture semantics.** Value-capture (snapshot at creation) or reference-capture (see later mutations)? Recommendation: value-capture, since the algebra is immutable (per FOUNDATION's "The Algebra Is Immutable" section). Nothing to mutate; snapshot is sufficient.

2. **Recursion in lambdas.** A lambda can't reference itself by name (no name). How to do recursion? Options: (a) force use of `defn` for recursive functions, (b) support `Y` combinator pattern, (c) add a name-binding form like Clojure's `fn` with optional self-name: `(lambda self [[params]] :return body)` where `self` refers to the lambda itself. Recommendation: (c) — add optional self-name syntax. Rare feature but enables recursion without `defn`.

3. **Higher-order parameter types.** `:Function` as a type works but is generic. For stricter typing: `(:Function :Thought :Thought)` (a function from `:Thought` to `:Thought`). Handled in 058-030-types.

4. **Brevity sugars.** Clojure's `#(...)` anonymous function shortcut. Python's `lambda x: expr`. Rust's `|x| expr`. Should wat have a shortcut? Recommendation: skip for now — the explicit form with types is the load-bearing primitive. Sugars can come later.

5. **Free variables and captured environment.** If a lambda references a name not in its parameters or enclosing scope, what happens? Recommendation: load-time error (unresolved reference). Fail fast.

6. **Serialization.** A lambda's AST serializes to EDN; its captured environment does not (captured values may be unencodable, large, or privacy-sensitive). Should lambda EDN include the captured env? Recommendation: no — EDN contains the lambda's AST only. Captured env is evaluator-runtime state, not part of the signed AST.

7. **Compiled form.** A frequently-called lambda could be JIT-compiled to native for speed. Out of scope for this proposal but worth noting; lambdas are natural JIT boundaries because they're self-contained.
