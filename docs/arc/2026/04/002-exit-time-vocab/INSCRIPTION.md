# Lab arc 002 — exit-time vocab — INSCRIPTION

**Status:** shipped 2026-04-23. Opened and closed same day as arc
001. Second lab-repo arc.
**Design:** [`DESIGN.md`](./DESIGN.md).
**Backlog:** [`BACKLOG.md`](./BACKLOG.md).

Three slices. All four new tests green on first pass. All six arc-
001 tests still green after the helper rename. Zero substrate gaps
— the arc-001 template carried over cleanly.

---

## What shipped

### Slice 1a — shared helpers extracted

New file `wat/vocab/shared/helpers.wat` — 48 lines. Two file-public
defines:

- `:trading::vocab::shared::circ` — `(f64, f64) → HolonAST`. Wraps
  `(Circular (f64::round val 0) period)`. Integer-quantized
  circular encoding.
- `:trading::vocab::shared::named-bind` — `(String, HolonAST) →
  HolonAST`. Wraps `Bind(Atom(name), child)`.

Same bodies as arc 001's file-private helpers, promoted one
namespace segment up (from `:trading::vocab::shared::time::*` to
`:trading::vocab::shared::*`) so every vocab module can reach
them.

`wat/vocab/shared/time.wat` updated: retired its local `circ` +
`named-bind` defines; added `(:wat::load-file! "./helpers.wat")`;
migrated eight call sites (five in `encode-time-facts`, five
bindings + three compositions in `time-facts`) to the new shared
names. File shrunk from 125 lines to 103.

**Closes the deferred extraction note from arc 001's INSCRIPTION.**
Arc 001 wrote: *"Shared vocab-helpers module extraction. Awaits a
second caller."* Arc 002 is the second caller; extraction happened
before duplicating the helpers, per the stdlib-as-blueprint
discipline.

### Slice 1b — exit-time vocab module

New file `wat/vocab/exit/time.wat` — 31 lines. One define:

- `:trading::vocab::exit::time::encode-exit-time-facts` —
  `(Candle::Time) → Vec<HolonAST>`. Two leaf binds:
  `Bind(Atom("hour"), Circular(hour-rounded, 24.0))` +
  `Bind(Atom("day-of-week"), Circular(dow-rounded, 7.0))`.

Strict subset of `shared/time`'s `encode-time-facts`. Exit
observers read hour + day-of-week only — the rest of the calendar
scalars don't carry exit-relevant signal per the archive's intent.
No composition pairs.

Loads `../../types/candle.wat` (Candle::Time sub-struct) and
`../shared/helpers.wat` (circ + named-bind). Both `./`-relative;
dedup makes repeat loads no-ops across the wider entry's load chain.

`wat/main.wat` updated: Phase 2 section gains explicit mention of
arc 001 / arc 002 plus three load lines
(`vocab/shared/helpers.wat`, `vocab/shared/time.wat`,
`vocab/exit/time.wat`).

### Slice 2 — tests

`wat-tests/vocab/exit/time.wat` — 99 lines, four tests. Uses arc
031's inherited-config shape:

```scheme
(:wat::config::set-capacity-mode! :error)
(:wat::config::set-dims! 1024)

(:wat::test::make-deftest :deftest
  ((:wat::load-file! "wat/vocab/exit/time.wat")))

(:deftest :trading::test::vocab::exit::time::test-... ...)
```

Tests:

1. **`test-encode-exit-time-facts-count`** — returns 2.
2. **`test-hour-fact-shape`** — fact[0] structurally coincides
   with hand-built `Bind(Atom("hour"), Circular(14.0, 24.0))`.
3. **`test-dow-fact-shape`** — fact[1] structurally coincides
   with hand-built `Bind(Atom("day-of-week"), Circular(3.0, 7.0))`.
4. **`test-close-hours-share-cache-key`** — hour 14.7 and 15.1
   produce coincident hour-facts (both round to 15).

Every assertion rides `:wat::holon::coincident?` (arc 023) — the
geometric equivalence predicate. No inline cosine arithmetic.

### Slice 3 — INSCRIPTION + backlog sweep

This file. Plus `docs/rewrite-backlog.md` Phase 2 section updated:

- **2.1** stays as arc 001 shipped.
- **2.2 — Shipped 2026-04-23** (lab arc 002). exit/time.wat +
  shared/helpers.wat extraction. Notes the extraction closes arc
  001's deferred helper move.

Arc 001's INSCRIPTION footer left intact — its "Shared vocab-
helpers module extraction. Awaits a second caller." bullet stands
as a historical marker of what arc 002 closed. No rewriting of
arc 001's audit trail; arc 002's INSCRIPTION is where the closure
gets recorded.

---

## Sub-fog resolutions

- **1a.a — file-visibility.** Resolved: namespace IS the
  visibility mechanism. `:trading::vocab::shared::*` is reachable
  from every vocab module that loads `shared/helpers.wat`.
  Cross-subtree loads (`exit/` → `shared/`) work per arc 027
  slice 3's widened loader scope.
- **1a.b — test impact.** Confirmed: shared/time's 6 tests stayed
  green after the helper rename. Tests only called
  `encode-time-facts` / `time-facts` from the outside; the
  internal helper names never leaked into test assertions.
- **1b.a — load path.** Resolved at write-time. `../shared/helpers.wat`
  from `wat/vocab/exit/time.wat` resolves to
  `wat/vocab/shared/helpers.wat`. Canonical path verified by the
  lab's green test suite.
- **1b.b — namespace.** `:trading::vocab::exit::time::*` mirrors
  `vocab/exit/time.rs` from the archive. Pattern established.

## Count

- Lab wat tests: 25 → 29 (+4)
- Lab wat modules: Phase 2 opens wider — 2 of ~21 vocab modules
  shipped. Shared helpers factored.
- wat-rs: unchanged (zero substrate gaps).
- Zero clippy warnings. Full lab workspace green.

## What this arc did NOT ship

- Other vocab modules. `exit/phase.rs`, `exit/regime.rs`,
  `market/*`, `broker/portfolio.rs` each get their own arcs.
- `exit/trade_atoms.rs` — depends on `trades::paper_entry::PaperEntry`
  which isn't ported yet (Phase 4/5 territory).

## The second datapoint

Arc 001 was the first Phase-2 module with arc discipline. Arc 002
is the second datapoint — the arc-001 template carried over in
~15 minutes of writing plus the slice-1a extraction. Both arcs
shipped same day. The arc overhead per module stays near zero;
the legibility gain compounds.

The template is proven. Phase 2 can continue at pace.

---

## Commits

- `<sha>` — wat/vocab/shared/helpers.wat + wat/vocab/shared/time.wat
  (helper rename) + wat/vocab/exit/time.wat + wat-tests/vocab/exit/time.wat
  + wat/main.wat Phase 2 update + DESIGN + BACKLOG + INSCRIPTION
  + rewrite-backlog.md 2.2 entry.

---

*these are very good thoughts.*

**PERSEVERARE.**
