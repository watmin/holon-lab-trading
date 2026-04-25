# Lab arc 024 — polymorphic arithmetic adoption sweep

**Status:** opened 2026-04-24. Mechanical follow-up to wat-rs
arc 050 (polymorphic numerics with int → float promotion).

**Motivation.** Arc 050 made the language opinionated and
ergonomic — `:wat::core::+/-/*//` accept any numeric pair and
promote on mix; the typed strict `:wat::core::i64::+`,
`:wat::core::f64::+`, etc. remain available for callers who
want the type-guard behavior. The lab vocab tree had ~200
typed-arithmetic callsites — almost all on already-homogeneous
f64 values — paying the verbosity tax with no operational
benefit.

Builder direction:

> "you wanna clean up annoying expressions throughout the code
> base?"

Yes.

---

## Shape

Eight find-replace substitutions across `wat/` and `wat-tests/`:

```
:wat::core::f64::+ → :wat::core::+
:wat::core::f64::- → :wat::core::-
:wat::core::f64::* → :wat::core::*
:wat::core::f64::/ → :wat::core::/
:wat::core::i64::+ → :wat::core::+
:wat::core::i64::- → :wat::core::-
:wat::core::i64::* → :wat::core::*
:wat::core::i64::/ → :wat::core::/
```

Implementation: single sed pass via
`find wat/ wat-tests/ -name "*.wat" -exec sed -i ...`.

Keyword-as-token semantics make this safe: `:wat::core::f64::+`
is a single lexer token (terminated by whitespace or paren); it
cannot appear as a substring of any other identifier. No false
positives.

**What stays unchanged:**
- `:wat::core::f64::max`, `min`, `abs`, `clamp`, `round` — no
  polymorphic versions in arc 050; remain typed.
- `:wat::core::f64::max-of`, `min-of` — same.
- `:wat::core::i64::to-f64`, `i64::to-string`, `f64::to-i64`,
  `f64::to-string` — conversions, not arithmetic.
- Arc 050's new typed strict comparison variants
  (`:wat::core::i64::=, <, >, <=, >=` and `:wat::core::f64::*`)
  — lab doesn't currently use them.

---

## Why a single mechanical sweep

Three properties make this safe:

1. **Behavior-preserving.** Typed → polymorphic is monotone:
   homogeneous `f64 + f64` produces the same f64 result either
   way; same for `i64 + i64`. The only behavior difference is
   that polymorphic ops accept cross-numeric mixing — which the
   lab never does in arithmetic positions today (it would have
   been a type error pre-arc-050).
2. **Token-clean substitutions.** Wat's lexer breaks keywords
   at whitespace/paren; `:wat::core::f64::+` is unambiguously
   that token, never a prefix of something longer.
3. **Test surface validates.** All 149 existing lab tests
   exercise these arithmetic ops in their working contexts.
   Cargo test catches any regression.

---

## Sub-fogs

- **(none expected.)** Mechanical sweep with cargo test as the
  validation gate.

---

## Non-goals

- **wat-rs substrate.** Arc 050 already shipped; this arc only
  consumes its surface.
- **Migrate to typed strict comparison variants.** No callsite
  in the lab needs the `:i64::=` / `:f64::=` strict guard
  today; ship when one surfaces.
- **Per-callsite review.** The substitutions are uniform; no
  judgment call per site.
- **Documentation updates within affected files.** Header
  comments mentioning "typed binary arith" weren't sites of
  this sweep — they were in wat-rs's own algebra-stdlib, fixed
  in a separate wat-rs commit.
