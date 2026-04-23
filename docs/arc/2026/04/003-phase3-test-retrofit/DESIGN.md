# Lab arc 003 — Phase 3 test retrofit

**Status:** opened 2026-04-23. Pure ergonomic retrofit.

**Motivation.** Phase 3 encoding tests (`scale_tracker.wat`,
`scaled_linear.wat`, `rhythm.wat`) predate arc 027/029/031's
test-ergonomic sequence. Each file uses the manual
`run-sandboxed-ast` + `:wat::test::program` shape from arc 010,
with explicit `(Some "wat/encoding")` scope and per-test
`(:wat::config::set-*!)` preambles.

The total footprint today:

```
wat-tests/encoding/rhythm.wat        286 lines,  6 tests
wat-tests/encoding/scaled_linear.wat 301 lines,  6 tests
wat-tests/encoding/scale_tracker.wat 197 lines,  6 tests
                                     ----
                                     784 lines, 18 tests
```

~43 lines per test on average, mostly ceremony:
- Outer `:trading::test::...::test-name` define wrapper.
- Inner `run-sandboxed-ast` + `:wat::test::program` scaffolding.
- Per-test config setters (2 lines).
- Per-test `(:wat::load-file! "scale_tracker.wat")`.
- Per-test `:user::main` wrapper.
- `(Some "wat/encoding")` scope argument.

Post-retrofit — arc 031's inherited-config + make-deftest shape —
each file's header becomes:

```scheme
(:wat::config::set-capacity-mode! :error)
(:wat::config::set-dims! 1024)

(:wat::test::make-deftest :deftest
  ((:wat::load-file! "wat/encoding/scale_tracker.wat")))

(:deftest :trading::test::encoding::scale-tracker::test-fresh-has-zero-count
  (:wat::core::let*
    (((t :trading::encoding::ScaleTracker)
      (:trading::encoding::ScaleTracker::fresh)))
    (:wat::test::assert-eq
      (:trading::encoding::ScaleTracker/count t)
      0)))

;; … five more deftests, each ~5-10 lines
```

Expected per-test footprint: ~8-12 lines. Expected file shrinkage:
~60-70% per file, ~500 lines removed in total across the three
files. Pure ergonomic win.

The file-header comment on each current file notes *"bypass
deftest and wire the sandbox manually"* — that claim was accurate
pre-arc-027 (sandbox had no loader inheritance) but is stale
today. Retrofit includes rewriting those header comments.

---

## Why this is its own arc

Arc 002 shipped exit-time vocab + shared helpers extraction. That
arc's scope was vocab. This retrofit touches Phase 3 encoding
tests — orthogonal concern. Keeping each arc's scope sharp makes
the audit trail legible.

Also: arc 002 INSCRIPTION already shipped. Expanding it now would
violate the "arc is closed" discipline. Retrofit lives in arc 003.

---

## Scope

Three files, 18 tests total. All tests currently pass; retrofit
must preserve test behavior — same assertions, same inputs, same
expected shapes. Only the surrounding scaffold changes.

**Per-file structure after retrofit:**

```scheme
;; file header comment — updated to reference arc 031's shape

(:wat::config::set-capacity-mode! :error)
(:wat::config::set-dims! 1024)

(:wat::test::make-deftest :deftest
  ((:wat::load-file! "wat/encoding/<module>.wat")))

(:deftest :name-1 body-1)
(:deftest :name-2 body-2)
;; …
(:deftest :name-6 body-6)
```

**Scope change.** Current files use `(Some "wat/encoding")` scope
so inner `(load!)` resolves `"scale_tracker.wat"` to
`CARGO_MANIFEST_DIR/wat/encoding/scale_tracker.wat`. Post-retrofit,
`:None` scope (deftest's default) inherits the test binary's
loader — arc 027 slice 3 widened this to `CARGO_MANIFEST_DIR`.
The load path in the factory's default-prelude becomes
`"wat/encoding/<module>.wat"` — relative to the crate root, not
to a sub-scope.

## Non-goals

- **No semantic test changes.** Every assertion stays exactly as
  written. The retrofit is purely about the outer scaffold.
- **No new tests.** Adding coverage belongs in separate arcs per
  the "outstanding tests" discipline — write them when a specific
  claim needs a named anchor.
- **No cross-file helpers.** Each encoding test file loads its
  own module. No test-helper extraction across files (there's
  no natural commonality; each module has different types +
  different shapes).
- **No change to `wat-tests/vocab/shared/time.wat` or
  `wat-tests/test_scaffold.wat`.** Those already use deftest /
  make-deftest correctly (time.wat via arc 001 + arc 031
  migrations; test_scaffold.wat via arc 031's migration).
- **No change to `wat/encoding/*.wat`** source modules. This arc
  is test-side only.

---

## Why this is inscription-class

Pure ergonomic win. No substrate, no new primitives, no new tests.
Just the test ergonomics the substrate has been building toward
finally applied to the tests that predated it. Leaves-to-root:
the substrate is the leaf; the test shape is the root; the
retrofit is the path between them.

Every future test author reading these three files sees arc 031's
shape as the default, not the pre-arc-027 ceremonial shape that
was the best available at the time the tests were written.
