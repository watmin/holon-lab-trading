# Lab arc 002 — exit-time vocab — BACKLOG

**Shape:** three slices, leaves-to-root. Status markers:
- **ready** — dependencies satisfied; can be written now
- **obvious in shape** — will be ready when the prior slice lands
- **foggy** — needs design work before it's ready

---

## Slice 1a — extract shared vocab helpers

**Status: ready.**

Context: arc 001 deferred the extraction of `circ` + `named-bind`
until a second caller surfaced. Arc 002 is that caller. Cleaner
to extract now (before the duplication lands) than to ship two
copies and retire one later.

Targets:
- New file `wat/vocab/shared/helpers.wat` — file-public `circ` +
  `named-bind` defines. Namespace: `:trading::vocab::shared::*`
  (shared utilities for every vocab module).
- `wat/vocab/shared/time.wat` — replace local `circ` +
  `named-bind` defines with calls to the shared names. Add
  `(:wat::load-file! "./helpers.wat")` at the top.

**Sub-fogs (expected to resolve at implementation):**
- **1a.a — file-visibility.** Wat has no private/public mechanism;
  the namespace prefix IS the visibility boundary. Moving the
  helpers from `:trading::vocab::shared::time::*` to
  `:trading::vocab::shared::*` makes them reachable from every
  module under `shared/`. Fine in practice. If cross-subtree usage
  (e.g., `exit/` or `market/`) wants the same helpers, they'll
  just load `shared/helpers.wat` — cross-tree `(load!)` is legal
  per arc 027 slice 3's widened loader scope.
- **1a.b — test impact.** Shared/time's tests never touched the
  helper defines directly — they called `encode-time-facts` and
  inspected results. Rename shouldn't ripple into tests. Verify
  by running lab wat tests unchanged post-extraction.

## Slice 1b — port exit/time.wat

**Status: obvious in shape** (once slice 1a lands).

Targets:
- New file `wat/vocab/exit/time.wat`. Loads
  `../shared/helpers.wat` (for `circ` + `named-bind`) and
  `../../types/candle.wat` (for `Candle::Time`).
- Defines `:trading::vocab::exit::time::encode-exit-time-facts`
  — `(Candle::Time) → Vec<HolonAST>`. Two leaf binds.
- `wat/main.wat` loads this module under the Phase 2 section
  (new line alongside the existing shared/time load).

**Sub-fogs:**
- **1b.a — load path.** The file sits at `wat/vocab/exit/time.wat`.
  The helpers are at `wat/vocab/shared/helpers.wat`. `./`-relative
  from the file's directory is `../shared/helpers.wat`. Arc 027's
  canonical-path dedup makes repeat loads no-ops.
- **1b.b — namespace.** `:trading::vocab::exit::time::*` mirrors
  the Rust module path `vocab/exit/time.rs`. Consistent with arc
  001's `:trading::vocab::shared::time::*`.

## Slice 2 — tests

**Status: obvious in shape** (once slice 1b lands).

Targets: `wat-tests/vocab/exit/time.wat`. Four outstanding tests
following arc 001's shape + the "each claim anchors a specific
semantic" discipline:

1. **Count.** `encode-exit-time-facts` returns 2 facts (hour +
   day-of-week).
2. **Hour fact shape.** fact[0] structurally coincides with
   hand-built `Bind(Atom("hour"), Circular(14.0, 24.0))`.
3. **Day-of-week fact shape.** fact[1] structurally coincides
   with hand-built `Bind(Atom("day-of-week"), Circular(3.0, 7.0))`.
4. **Rounding quantizes cache keys.** hour 14.7 and hour 15.1
   produce coincident hour-facts (both round to 15). Mirrors arc
   001's test-close-hours-share-cache-key at the exit-time
   emission site.

Use the configured-deftest factory + arc 031's inherited-config
shape:

```scheme
(:wat::config::set-capacity-mode! :error)
(:wat::config::set-dims! 1024)

(:wat::test::make-deftest :deftest
  ((:wat::load-file! "wat/vocab/exit/time.wat")))

(:deftest :trading::test::vocab::exit::time::test-...)
```

One preamble, one factory, N tests. The ergonomic-minimum shape
the whole arc-027-through-arc-031 sequence produced.

## Slice 3 — INSCRIPTION

**Status: obvious in shape** (once slices 1a + 1b + 2 land).

- `docs/arc/2026/04/002-exit-time-vocab/INSCRIPTION.md` —
  standard shape. What shipped, slice by slice, sub-fog
  resolutions, count delta.
- `docs/rewrite-backlog.md` — Phase 2 section gains a "2.2
  shipped" marker for exit/time. Helper-extraction note
  retires (no longer deferred).
- Optional: update arc 001's INSCRIPTION footer to point at
  arc 002's helper extraction as the closure of its deferred
  "extract when second caller surfaces" note.

**Sub-fogs:**
- **3a — CLAUDE.md update?** CLAUDE.md's "Current state" paragraph
  mentions "wat-vm runs" as past tense. Phase 2 vocab ports
  don't change that framing materially. Defer CLAUDE.md rewrite
  to Phase 5 per `rewrite-backlog.md`.

---

## Working notes (updated as slices land)

- Opened 2026-04-23, minutes after arc 001 closed.
- Second lab-repo arc; first to exercise the arc-001-template
  carry-over. Expected zero substrate gaps.
