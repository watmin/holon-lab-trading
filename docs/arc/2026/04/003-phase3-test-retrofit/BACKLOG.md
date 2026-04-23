# Lab arc 003 — Phase 3 test retrofit — BACKLOG

**Shape:** four slices, one per file + closing INSCRIPTION.
Status markers:
- **ready** — can ship now
- **obvious in shape** — will be ready when the prior slice lands

---

## Slice 1 — scale_tracker.wat retrofit

**Status: ready.** Smallest file (197L → ~80L expected).

Steps:
1. Read the six test bodies out of the existing file.
2. Rewrite as arc-031 shape: outer preamble + make-deftest factory +
   six `(:deftest ...)` calls with bare bodies.
3. Update header comment: remove stale "bypass deftest" note; add
   arc-031 reference.
4. Verify all six tests still pass via `cargo test -- --nocapture`.

## Slice 2 — scaled_linear.wat retrofit

**Status: obvious in shape** (once slice 1 lands).

Same pattern as slice 1. 301L → ~120L expected (scaled_linear has
longer per-test bodies because of HashMap threading + trading
module state).

## Slice 3 — rhythm.wat retrofit

**Status: obvious in shape** (once slice 1 + 2 land).

Same pattern. 286L → ~110L expected. Rhythm tests use
`coincident?` (arc 023) for algebra-native equivalence — the
body shapes are already clean; the retrofit is purely about the
outer scaffold.

## Slice 4 — INSCRIPTION

**Status: obvious in shape** (once all three files retrofitted
and tests green).

Targets:
- `docs/arc/2026/04/003-phase3-test-retrofit/INSCRIPTION.md` —
  standard shape. Record line-count deltas per file, confirm
  zero regressions.
- `docs/rewrite-backlog.md` — Phase 3 section gains a note that
  the encoding tests have been migrated to arc-031 shape.

**Sub-fogs:**
- **4a — BOOK chapter?** No — this is a housekeeping retrofit,
  not chapter material. The Chapter 33 closed on the ergonomic-
  testing story; this retrofit is that story applied to the
  pre-ergonomic tests. Not worth its own chapter.

---

## Working notes (updated as slices land)

- Opened 2026-04-23 after user observed the Phase 3 tests hadn't
  been migrated. Retrofit is pure win — the substrate that makes
  it possible shipped across arcs 027 + 029 + 031.
