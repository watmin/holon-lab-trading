# 058-036: `:wat::core::cond` — Typed Multi-Way Branch

**Scope:** language core
**Class:** LANGUAGE CORE — **INSCRIPTION 2026-04-21**
**Parent:** 058-ast-algebra-surface
**Foundation:** ../FOUNDATION.md
**Depends on:** 058-028-define, 058-029-lambda, 058-030-types

---

## INSCRIPTION

Code led, spec follows. `:wat::core::cond` shipped in wat-rs on
2026-04-21 as a factoring of the nested-`if` ceremony caught in
`wat/std/hermetic.wat`'s `exit-code-prefix` after arc 012's
closure. The primitive landed in commit `841cacc` before this
document existed. The text below describes what was built.

Joins the existing INSCRIPTION-class proposals (058-033-try,
058-034-stream-stdlib, 058-035-fork-substrate, plus the
amendment-inscriptions on 058-003 and 058-030).

wat-rs reference: `src/runtime.rs` (eval_cond + eval_cond_tail),
`src/check.rs` (infer_cond), `tests/wat_core_cond.rs`, plus the
surface-reduction rewrite in `wat/std/hermetic.wat`.

---

## Motivation

After arc 012 closed, `wat/std/hermetic.wat`'s `exit-code-prefix`
had to translate five exit codes to string prefixes. Written in
nested `:wat::core::if`, the cascade read:

```scheme
(:wat::core::define
  (:wat::kernel::exit-code-prefix (code :i64) -> :String)
  (:wat::core::if (:wat::core::= code 1) -> :String
    "[runtime error]"
    (:wat::core::if (:wat::core::= code 2) -> :String
      "[panic]"
      (:wat::core::if (:wat::core::= code 3) -> :String
        "[startup error]"
        (:wat::core::if (:wat::core::= code 4) -> :String
          "[:user::main signature]"
          "[nonzero exit]")))))
```

Every `-> :String` after the first was ceremony, not
information. The reader learns the type once at the declaration
point; repeating it four times carried no meaning. Nesting
obscured the flat cascade the author was expressing.

Chapter 22 of the book named the pattern:

> *find the ceremony the user keeps writing; factor it into the
> substrate; ship the macro alias that names the factored form
> in the user's voice.*

Chained-`if` was the substrate saying *"I have cond, use it"* —
except we didn't. Factored.

---

## The Form

```scheme
(:wat::core::cond -> :T
  ((test-bool-expr) body-T)
  ((test-bool-expr) body-T)
  ...
  (:else body-T))
```

**Semantics.**

1. The `-> :T` annotation declares the result type, once, at the
   head.
2. Each arm is a 2-element list `(test body)` where:
   - `test` is an expression that unifies with `:bool`.
   - `body` is an expression that unifies with the declared `:T`.
3. The last arm MUST be `(:else body)` — `:else` is a bare
   keyword marker; the body is the default value evaluated when
   no prior test matched.
4. At runtime, tests evaluate in order. The first
   `Value::bool(true)` wins, and its body becomes the cond's
   value. On false, iteration continues. If no test matches, the
   `:else` arm's body runs.

**Type rules** (enforced at check time):

1. Arity minimum 3 args: `->`, `:T`, and at least one arm (the
   `:else` arm). Otherwise `MalformedForm`.
2. `args[0]` must be the symbol `->`; `args[1]` must be a type
   keyword.
3. Every arm is a 2-element list. Test arms: `test` unifies with
   `:bool`; `body` unifies with `:T`. The `:else` arm skips the
   test-type check (no test to type) and unifies its body with
   `:T`.
4. The last arm's head must be `WatAST::Keyword(":else")`. If
   not, `MalformedForm`: *"last arm must be (:else body) — cond
   requires an explicit default."*

**Per-arm error messages.** Type mismatches name which arm
diverged — *"arm #N test expected :bool, got …"* or *"arm #N
body expected :String, got …"* — matching `infer_if`'s
branch-specific diagnostics.

**Tail-position preserved.** `eval_cond_tail` threads tail
position into the selected body via `eval_tail`, so a
tail-recursive function with `cond` at its tail trampolines
correctly — same TCO discipline `if` inherits from arc 003. A
test at 100k depth confirms.

Violations surface as `MalformedForm` (shape errors, missing
`:else`) or `TypeMismatch` (non-`:bool` test, body-type
divergence).

---

## Why this earns language-core status

**FOUNDATION's three criteria for language core:**

1. **Required for the algebra stdlib to exist as runnable code.**
   `exit-code-prefix` (in `wat/std/hermetic.wat`) is already
   stdlib code that the substrate ships. The nested-`if` it was
   using was structurally dishonest — every type annotation
   after the first was ceremony. A cascading dispatch on `:i64`
   cannot use `:wat::core::match` (wat's match is for enum
   variants and Option/Result, not integer equality patterns).
   Without `cond`, every multi-way dispatch on a primitive
   value grows nested-`if` ceremony linearly with the number of
   branches. Passes.

2. **Orthogonal to the holon algebra.** Pure control-flow.
   Doesn't construct holon vectors, doesn't observe them. Same
   orthogonality `if` and `match` have. Passes.

3. **Interpretable by the Rust-backed wat-vm.** Two cases in the
   eval walker (`eval_cond` + `eval_cond_tail`, mirroring
   `if`'s tail/non-tail pair for TCO); one case in the type
   checker (`infer_cond`, mirroring `infer_if`); one shared
   shape validator. No new type-system machinery. Passes.

All three criteria satisfied. Sits alongside `define` / `lambda`
/ `let*` / `match` / `if` / `try` as language-core.

---

## Usage

**Before cond** — nested `if` with repeated type annotations:

```scheme
(:wat::core::if (:wat::core::= code 1) -> :String
  "[runtime error]"
  (:wat::core::if (:wat::core::= code 2) -> :String
    "[panic]"
    (:wat::core::if (:wat::core::= code 3) -> :String
      "[startup error]"
      "[other]")))
```

**After cond** — flat cascade, type annotation at declaration
point:

```scheme
(:wat::core::cond -> :String
  ((:wat::core::= code 1) "[runtime error]")
  ((:wat::core::= code 2) "[panic]")
  ((:wat::core::= code 3) "[startup error]")
  (:else                  "[other]"))
```

14 lines → 8 lines in the shipped stdlib rewrite. Every `->
:String` after the first vanishes.

**When to use `cond` vs `if`.** `cond` earns its slot at three
or more cascading branches. A `cond` with one test arm plus
`:else` is just `if` with more ceremony — for a single binary
branch, `if` is the honester primitive. The
stdlib-as-blueprint rule from `CONVENTIONS.md` applies: each
primitive lives where it fits; don't reach for the bigger
primitive when the smaller one is honest.

---

## Convergence with prior art

Scheme's `(cond (test expr) ... (else expr))` — same clause
shape, same first-truthy-wins semantics, same `else` marker.
Clojure's `(cond test expr ... :else expr)` — different clause
shape (flat pairs rather than parenthesized lists), same
semantics, `:else` keyword as default marker.

wat's cond adopts Scheme's parenthesized clause shape because it
matches wat's existing match-arm syntax (`((Some v) body)`)
better than Clojure's flat-pair style. The `:else` keyword-as-
marker follows Clojure's convention and matches wat's existing
`:None` / `:Some` conventions for keyword-marked pattern
positions.

The form is older than both Scheme and Clojure. McCarthy 1960:
*"cond[(p1, e1), (p2, e2), …]"* — the original multi-way
conditional in LISP 1.5. Sixty-five years of conditional
expression; the clause shape settled early and carries.

---

## What this proposal does NOT add

- **Multi-expression arm bodies.** Scheme `cond`'s clauses
  accept `(test expr1 expr2 ... exprN)` where the last is the
  result. wat's `cond` takes exactly 2 elements per arm. For
  multi-expression bodies, wrap in `let*`.
- **`=>` fall-through.** Scheme supports `(test => fn)` — test
  result applied to `fn`. Out of scope; not a pattern the
  substrate has demanded.
- **Pattern-style `cond` over enum variants.** Existing
  `:wat::core::match` fills that role; `cond` is for boolean
  tests on arbitrary `:bool` expressions.
- **Implicit default.** `:else` is required. No silent
  fall-through to `:()` or runtime panic.

---

## Status

INSCRIPTION — shipped 2026-04-21 in wat-rs commit `841cacc`.

Tests:
- 10 integration tests in `tests/wat_core_cond.rs` covering
  happy paths (first-arm / middle-arm / else-fallthrough /
  single-else / bound-value), type-checker refusals (missing
  `:else`, non-`:bool` test, body-type mismatch), tail position
  (100k-deep tail-recursive countdown), and nested cond
  composition.
- Surface-reduction rewrite in `wat/std/hermetic.wat`.
- Zero regressions: 518 Rust unit tests, 25+ integration
  groups, 31 wat-level tests green.

**Signature:** *these are very good thoughts.* **PERSEVERARE.**
