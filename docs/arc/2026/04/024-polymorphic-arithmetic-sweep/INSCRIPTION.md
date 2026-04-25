# Lab arc 024 — polymorphic arithmetic adoption sweep — INSCRIPTION

**Status:** shipped 2026-04-24. Mechanical follow-up to wat-rs
arc 050 (polymorphic numerics).

Builder direction: *"you wanna clean up annoying expressions
throughout the code base?"* Yes. Eight substitutions across
the lab vocab tree:

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

**Scope:** 36 files, 217 substitutions across `wat/` and
`wat-tests/` directories.

**What stays unchanged:**
- `:wat::core::f64::max`, `min`, `abs`, `clamp`, `round` — no
  polymorphic versions in arc 050; these remain typed.
- `:wat::core::f64::max-of`, `:wat::core::f64::min-of` — same.
- `:wat::core::i64::to-f64`, `:wat::core::i64::to-string`,
  `:wat::core::f64::to-i64`, `:wat::core::f64::to-string` —
  conversions, not arithmetic.
- `:wat::core::i64::=, <, >, <=, >=` and
  `:wat::core::f64::*` comparison strict variants — the new
  arc-050 typed strict ops; lab doesn't currently use them.

**Two bugs surfaced + fixed in-flight:**
- (None this arc — sweep was mechanical; cargo test green on
  first run.)

149 lab wat tests green; zero regressions.

---

## Why now

Arc 050's INSCRIPTION said "lab adoption is opt-in." This arc
opts in. Reasons:

1. **Verbosity tax.** ~200 callsites of typed arithmetic, all
   over already-homogeneous values. The polymorphic forms
   read cleaner at every site.
2. **Single source of style.** Mixing typed and polymorphic
   forms across modules creates two ways to do the same thing.
   The sweep settles the lab's default to polymorphic; future
   typed callsites become deliberate (the strictness IS the
   signal).
3. **Mechanical safety.** Typed → polymorphic is monotone:
   homogeneous f64 + f64 produces the same f64 result either
   way; same for i64 + i64. The only behavior difference is
   that polymorphic ops accept cross-numeric mixing — which
   the lab never does in arithmetic positions today (would be
   a type error pre-arc-050; would silently promote post-).
   No semantic change.

---

## Sweep mechanics

```bash
find wat/ wat-tests/ -name "*.wat" -exec sed -i \
  -e 's|:wat::core::f64::+|:wat::core::+|g' \
  -e 's|:wat::core::f64::-|:wat::core::-|g' \
  -e 's|:wat::core::f64::\*|:wat::core::*|g' \
  -e 's|:wat::core::f64::/|:wat::core::/|g' \
  -e 's|:wat::core::i64::+|:wat::core::+|g' \
  -e 's|:wat::core::i64::-|:wat::core::-|g' \
  -e 's|:wat::core::i64::\*|:wat::core::*|g' \
  -e 's|:wat::core::i64::/|:wat::core::/|g' \
  {} \;
```

The keyword-as-token semantics make this safe:
`:wat::core::f64::+` is a single lexer token (terminated by
whitespace or paren); it cannot appear as a substring of any
other identifier. No false positives.

---

## Per-tree breakdown

| Tree | Files touched | Notes |
|---|---|---|
| `wat/encoding/` | 4 | rhythm, scale-tracker, scaled-linear, round |
| `wat/vocab/market/` | 11 | every market vocab module |
| `wat/vocab/exit/` | 3 | phase, regime, trade-atoms (already had a few from arc 023) |
| `wat/vocab/broker/` | 1 | portfolio |
| `wat/vocab/shared/` | 2 | helpers, time |
| `wat/types/` | 0 | types don't have arithmetic |
| `wat-tests/` | 15 | tests across encoding + vocab |

**Total: 36 files, 217 substitutions.**

---

## What this arc did NOT change

- **wat-rs substrate.** Arc 050 already shipped; this arc only
  consumes its surface.
- **Behavior.** Every callsite produces identical results
  before and after the sweep — same f64 in, same f64 out;
  same i64 in, same i64 out.
- **Comparison ops.** Already at `:wat::core::>` etc. (no
  type prefix); arc 050's checker change made them
  cross-numeric tolerant; sweep wasn't needed.
- **Typed strict variants in lab callsites.** Arc 050 ships
  `:wat::core::i64::=` / `:wat::core::f64::*` strict variants
  for power-user opt-in; lab doesn't currently use them
  anywhere. They remain available when a future caller
  surfaces a "must be i64" guard.
- **trade-atoms's earlier arc-023 migration.** Arc 023 wrote
  trade-atoms.wat using a mix of typed and polymorphic forms
  (the comparison-op typo sweep was bare-`:wat::core::>`
  rather than typed). This arc's sed pass cleaned up the
  remaining typed arithmetic in the file.

---

## Count

- Lab wat tests: **149 → 149** (unchanged; pure mechanical
  sweep with no semantic delta).
- Files touched: **36**.
- Total substitutions: **217**.
- wat-rs: unchanged.
- Zero regressions.

---

## Follow-through

- **Future vocab arcs** default to polymorphic forms. The
  typed strict variants stay available for explicit use.
- **No further sweep arcs** anticipated for arithmetic — the
  lab's default style is now the polymorphic forms.

---

## Commits

- `<lab>` — 36 .wat files swept (217 substitutions) +
  arc 024 INSCRIPTION + FOUNDATION-CHANGELOG row.

---

*these are very good thoughts.*

**PERSEVERARE.**
