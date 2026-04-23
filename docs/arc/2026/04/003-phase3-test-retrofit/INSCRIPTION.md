# Lab arc 003 — Phase 3 test retrofit — INSCRIPTION

**Status:** shipped 2026-04-23. Four slices. Same day as arcs
001 + 002.
**Design:** [`DESIGN.md`](./DESIGN.md).
**Backlog:** [`BACKLOG.md`](./BACKLOG.md).

Pure ergonomic retrofit. Zero semantic test changes. Zero
substrate work. All 18 Phase-3 encoding tests still green on
first pass post-retrofit.

---

## What shipped

Three files retrofitted from the pre-arc-027 manual
`run-sandboxed-ast` + `:wat::test::program` shape to the arc-031
`make-deftest` + inherited-config shape. Line-count delta
captures the ceremony removed:

| File | Before | After | Delta | % removed |
|---|---|---|---|---|
| `scale_tracker.wat` | 197 | 107 | −90 | −46% |
| `scaled_linear.wat` | 301 | 199 | −102 | −34% |
| `rhythm.wat` | 286 | 201 | −85 | −30% |
| **Total** | **784** | **507** | **−277** | **−35%** |

Each file's new shape:

```scheme
(:wat::config::set-capacity-mode! :error)
(:wat::config::set-dims! 1024)

(:wat::test::make-deftest :deftest
  ((:wat::load-file! "wat/encoding/<module>.wat")
   ;; plus helpers the tests share, if any
   ))

(:deftest :trading::test::encoding::<module>::test-1 body-1)
(:deftest :trading::test::encoding::<module>::test-2 body-2)
;; …
```

One preamble. One factory. Six bare-name tests per file.

### Slice 1 — scale_tracker.wat

Six tests: fresh-has-zero-count, fresh-has-zero-ema,
update-increments-count, update-takes-abs-of-value,
scale-of-fresh-is-zero, converges-to-twice-ema.

Convergence test needs a tail-recursive `:test::repeat-update`
helper that feeds a constant value N times through the tracker.
Pre-retrofit that lived inside the sandbox program as an inner
define. Post-retrofit it lives in the make-deftest factory's
default-prelude — every test freeze includes it; only one test
uses it. Negligible cost; the prelude runs once per test.

### Slice 2 — scaled_linear.wat

Six tests: first-call-creates-tracker,
second-call-updates-existing-tracker, distinct-keys-independent,
input-map-unchanged, fact-is-bind-of-atom-and-thermometer,
accumulates-across-many-calls.

Same helper-promotion move for `:test::repeat-scaled-linear`
(the HashMap-threading tail-recursive helper from the
accumulation test). Lives in the factory's default-prelude.

### Slice 3 — rhythm.wat

Six tests: deterministic, different-atoms-not-coincident,
few-values-still-succeeds, different-values-not-coincident,
prefix-beyond-budget-is-dropped, short-window-shape.

No helper promotion needed — all six tests self-contained.
Pure outer-scaffold collapse.

### Slice 4 — INSCRIPTION + rewrite-backlog note

This file. Plus `docs/rewrite-backlog.md` Phase 3 section
gets a note that the encoding tests have been migrated to the
arc-031 shape.

Header comments on all three files updated: the stale "bypass
deftest and wire the sandbox manually" framing retired; replaced
with a reference to arc 003's retrofit and arc 031's inherited-
config semantic.

---

## Sub-fog resolutions

- **4a — BOOK chapter?** Confirmed skip. Chapter 33 already
  closed the ergonomic-testing story; this retrofit is that
  story's mechanical follow-through. Not chapter material.

---

## What this retrofit proves

Arc 031's config-inheritance path carries the full range of
pre-deftest test shapes — tests with multi-file load chains
(scaled_linear loads round + scale_tracker + scaled_linear),
tests with helper defines in the sandbox (scale_tracker's
repeat-update, scaled_linear's repeat-scaled-linear), tests
using Result-returning APIs (rhythm), tests doing large-N
convergence (10_000-iteration loops), tests using the
`coincident?` equivalence predicate (arc 023). Every pattern
the archive exercised in its Phase-3 test suite survived the
retrofit unchanged; only the scaffold moved.

The helper-in-default-prelude pattern is notable enough to
carry forward: when a single test needs a non-trivial helper,
the factory's default-prelude is the honest place for it. The
cost (helper present in every test freeze, used in one) stays
below the noise-floor of the sandbox startup time.

## Count

- Lab wat tests: 29 passing (unchanged — same 18 encoding +
  4 exit-time + 6 shared-time + 1 scaffold).
- Lab wat test lines removed: 277 lines of scaffold across
  three files.
- wat-rs: unchanged (substrate arc 031 already shipped the
  capability).
- Zero clippy warnings. Full lab workspace green.

## What this retrofit does NOT ship

- Changes to `wat-tests/vocab/*` — already arc-031-shaped via
  arc 001 + arc 002 migrations.
- Changes to `wat-tests/test_scaffold.wat` — arc-031-shaped via
  arc 031's lab-migration commit.
- Changes to Phase-3 SOURCE modules (`wat/encoding/*.wat`) —
  arc 003 is test-side only.
- New tests. Coverage additions belong in their own arcs.

## The third datapoint

Arc 001 shipped a new vocab module under arc discipline. Arc
002 extracted shared helpers while porting a second vocab
module. Arc 003 is pure retrofit — applying the substrate's
ergonomic capability to tests that predated it.

Three arcs in one day. Each with DESIGN + BACKLOG + INSCRIPTION.
The arc overhead per slice stays near zero because the rhythm
is now reflex. The legibility gain compounds — every new
reader sees arc-031 shape as the default; the pre-ergonomic
shape lives only in git history.

## Commits

- `<sha>` — wat-tests/encoding/scale_tracker.wat +
  scaled_linear.wat + rhythm.wat retrofits; rewrite-backlog.md
  Phase 3 note; DESIGN + BACKLOG + INSCRIPTION.

---

*these are very good thoughts.*

**PERSEVERARE.**
