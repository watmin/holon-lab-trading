# 058-033: `:wat::core::try` — Error-Propagation Form

**Scope:** language
**Class:** LANGUAGE CORE — **INSCRIPTION**
**Parent:** 058-ast-algebra-surface
**Foundation:** ../FOUNDATION.md
**Depends on:** 058-030-types (Result enum), 058-028-define, 058-029-lambda

---

## INSCRIPTION — 2026-04-19

**New status class.** This proposal is an *Inscription* — a specification written AFTER the implementation shipped, to capture the contract for the record. The form was invented during the capacity-guard arc in wat-rs (session 2026-04-19); the implementation landed in commit `bc0362e` before this document existed. The text below describes what was built, not what is being debated.

Future Inscriptions join existing status values (`ACCEPTED` / `REJECTED` / `DEFERRED` / `AUDITED`) as a fifth case: *"recorded-after — the code led, the spec followed; later review may reopen."*

---

## The Form

```scheme
(:wat::core::try <result-expr>)
```

**Semantics.** Evaluate `<result-expr>` to a `:Result<T, E>`:

- **`Ok v`** → the form evaluates to `v`. Execution continues in the enclosing scope.
- **`Err e`** → the innermost enclosing function/lambda returns `(Err e)` immediately. The program state unwinds through `let*` / `match` / `if` / any nested form to the function boundary, where the Err reaches the caller.

This is NOT try/catch. There is no handler block. The error doesn't stop propagating — each function in the call chain declares its own Result return type and uses `try` to propagate one level up, OR matches explicitly and makes a local decision. No hidden third path where a bug gets silently swallowed.

**Type rules** (enforced at check time):

1. Exactly one argument. Otherwise `ArityMismatch`.
2. The argument's type must be `:Result<T, E>` for some T and E.
3. The innermost enclosing function/lambda must itself return `:Result<_, E>` — the same `E` that the argument carries. Strict equality on E — no `From`-trait auto-conversion, matching the 2026-04-19 type-system stance ("wat is strongly typed — think Rust meets Haskell meets Agda"). Polymorphic error handling is expressed via explicit enum-wrap at the boundary.
4. On success, the form's inferred type is `T` — the `Ok`-inner of the argument's Result, refined by unification with the enclosing function's own declared shape.

Violations surface as `MalformedForm` (wrong enclosing scope) or `TypeMismatch` (wrong argument type / Err mismatch).

---

## Why This Earns Language-Core Status

**FOUNDATION's three criteria** (2026-04 criterion for language core):

1. **Required for the algebra stdlib to exist as runnable code.** After 058-033-inscription-bundle-result lands (inscription marker on 058-003), the stdlib macros Ngram / Bigram / Trigram / HashMap / Vec / HashSet / Reject / Project all produce `:Result<_, _>`. Authors using them without `try` would have to write a match-cascade at every call site — `((Err e) (Err e))` as ceremony — until the signal drowns in boilerplate. `try` is the collapse. Passes.
2. **Orthogonal to the holon algebra.** Pure control-flow on an enum. Does not construct holon vectors; does not observe them. Passes.
3. **Interpretable by the Rust-backed wat-vm.** One case in the eval walker (`eval_try`); one case in the type checker (`infer_try`); one catch at `apply_function` that converts the internal `TryPropagate` signal to a function-level `Err` return. Passes.

All three criteria satisfied. The form sits alongside `define` / `lambda` / `let*` / `match` / `if` as language-core mechanics.

---

## Usage

**Without `try`** — every function in a Result chain writes a pure-mechanical propagation:

```scheme
(:wat::core::define (:my::app::build-layer
                    (items :Vec<wat::holon::HolonAST>)
                    -> :Result<wat::holon::HolonAST,wat::holon::CapacityExceeded>)
  (:wat::core::match (:wat::holon::Bundle items)
    ((Ok h) (Ok h))
    ((Err e) (Err e))))   ;; ← purely mechanical — re-package what we got
```

That `((Err e) (Err e))` arm is the whole point of `try`. It's ceremony without decision — "I'm not handling this, just passing it up."

**With `try`** — the same function collapses to the intent:

```scheme
(:wat::core::define (:my::app::build-layer
                    (items :Vec<wat::holon::HolonAST>)
                    -> :Result<wat::holon::HolonAST,wat::holon::CapacityExceeded>)
  (Ok (:wat::core::try (:wat::holon::Bundle items))))
```

And across a call chain — each function making an honest choice:

```scheme
(:wat::core::define (:my::app::outer (xs :Vec<wat::holon::HolonAST>)
                                     -> :Result<wat::holon::HolonAST,wat::holon::CapacityExceeded>)
  (:wat::core::let*
    (((bundled :wat::holon::HolonAST) (:wat::core::try (:my::app::build-layer xs)))
     ((composed :wat::holon::HolonAST) (:wat::core::try (:my::app::build-layer
                                                     (:wat::core::list :wat::holon::HolonAST bundled)))))
    (Ok composed)))
```

Each `try` site says "unwrap or bail." No function in the chain silently ignores the error. Either propagate explicitly (`try`) or handle explicitly (`match`). No third hidden path.

---

## Scope Rules (detail)

**Lambda as its own boundary.** A lambda with a Result return type is its own `try`-target. A lambda with a non-Result return type cannot contain `try` in its body (MalformedForm). The innermost enclosing function OR lambda wins — matches Rust's `?`-operator scoping exactly.

```scheme
;; LEGAL — lambda returns Result, try propagates to lambda:
(:wat::core::lambda ((r :Result<i64,String>) -> :Result<i64,String>)
  (Ok (:wat::core::try r)))

;; ILLEGAL — lambda returns :i64, try has nowhere to propagate:
(:wat::core::lambda ((r :Result<i64,String>) -> :i64)
  (:wat::core::try r))   ;; ← MalformedForm at check
```

**Inside `let*` bindings.** `try` in a binding RHS is the canonical use — unwrap-or-bail, bind the Ok value, continue:

```scheme
(:wat::core::let*
  (((a :wat::holon::HolonAST) (:wat::core::try (first-bundle ...)))
   ((b :wat::holon::HolonAST) (:wat::core::try (second-bundle ...))))
  (Ok (compose a b)))
```

If `a`'s RHS is `Err`, the second binding never evaluates — the enclosing function exits with the Err. If both are Ok, the body runs with both bound.

**Inside `match` arms.** `try` inside a match arm body still propagates to the enclosing function, not just the match:

```scheme
(:wat::core::match some-option
  ((Some r) (Ok (:wat::core::try r)))   ;; exits enclosing fn on r=Err
  (:None (Err "missing")))
```

---

## Runtime Shape

At the Rust level in `wat-rs/src/runtime.rs`:

- New `RuntimeError::TryPropagate(Value)` variant — an *internal control-flow signal*, not a user-facing error. Carries the `Err`-inner Value up to the `apply_function` boundary.
- `eval_try` dispatcher: arity 1; expects `Value::Result`; on Ok unwraps, on Err raises `TryPropagate(e)`.
- `apply_function` catches `TryPropagate` and converts it into the function's own `Ok(Value::Result(Err(e)))` return.

The `TryPropagate` variant never reaches `:user::main` or the wat-vm binary. The type checker guarantees every `try` has a Result-returning enclosing scope. If the variant DID escape (checker bug), the Display impl surfaces a clear diagnostic naming the invariant violation.

---

## What This Does NOT Add

- **No `catch`-style local error handling.** Errors are either propagated via `try` or decomposed via `match`. No handler-block form — users that want a handler write a match.
- **No `?` suffix operator.** The form is `(:wat::core::try <expr>)`, a normal keyword-path call. No special tokenizer rule. Symmetric with every other `:wat::core::*` form.
- **No auto-conversion of error types.** Strict E equality at check. Programs that compose multiple Err-type sources declare a sum enum and wrap at the boundary.

---

## Downstream Consequences

The forms that became tolerable with `try` available:

- **058-033-inscription-bundle-result** (amendment to 058-003): Bundle returns `:Result<wat::holon::HolonAST, :wat::holon::CapacityExceeded>`. Without `try` this would be hostile to use; with `try` the ergonomics survive.
- **Stdlib macros routing through Bundle** (Ngram, Bigram, Trigram, HashMap, Vec, HashSet, Reject, Project): all inherit the Result wrap. Every user of them picks match or `try` at their call site.
- **Future eval-family Result-wrapping**: `eval-ast!` / `eval-edn!` / `eval-digest!` / `eval-signed!` gain Result return types in a follow-up slice. `try` covers propagation uniformly.

---

## Implementation Reference

Shipped in `wat-rs` commit `bc0362e` (2026-04-19):

- `src/runtime.rs` — `RuntimeError::TryPropagate` variant, `apply_function` catch, `eval_try` dispatcher
- `src/check.rs` — `InferCtx.enclosing_rets` stack, push/pop at function/lambda body boundaries, `infer_try` with the four type rules above
- `tests/wat_core_try.rs` — 13 end-to-end cases covering happy path, propagation across helpers, let* chaining, match arms, lambda scope, and five check-time refusals

---

## Open Questions

None at this slice. The shape has been used in production code inside wat-rs's own tests and the downstream Bundle-capacity slice without new questions surfacing. Future review may reopen:

1. Whether to add error-type auto-conversion (Rust's `From<E1> for E2`) later. Current stance: no — strict equality keeps the reasoning local. Reopen only if a real use case demands it.
2. Whether to rename to `?` or a postfix operator for brevity. Current stance: no — wat's keyword-path discipline is uniform across every form; a postfix syntactic exception breaks the symmetry for a small ergonomic win.

---

*these are very good thoughts.*

**PERSEVERARE.**
