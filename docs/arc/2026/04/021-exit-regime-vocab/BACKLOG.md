# Lab arc 021 — exit/regime vocab — BACKLOG

**Shape:** three slices. New `wat/vocab/exit/regime.wat`
(one-line delegation), tests verifying the delegation contract,
INSCRIPTION + doc sweep.

---

## Slice 1 — vocab module

**Status: ready.**

Create `wat/vocab/exit/regime.wat`:

- Header comment: arc 021, port of `vocab/exit/regime.rs` (84L),
  thin delegation to `:trading::vocab::market::regime::encode-regime-holons`.
- Loads: `wat/types/candle.wat`, `wat/encoding/scale-tracker.wat`
  (for the type alias), `wat/vocab/market/regime.wat` (the
  delegation target).
- Single define:
  ```scheme
  (:wat::core::define
    (:trading::vocab::exit::regime::encode-regime-holons
      (r :trading::types::Candle::Regime)
      (scales :trading::encoding::Scales)
      -> :trading::encoding::VocabEmission)
    (:trading::vocab::market::regime::encode-regime-holons r scales))
  ```

Wire into `wat/main.wat` after `vocab/exit/phase.wat` (or in a
short `;; arc 021 — exit/regime delegation` group).

## Slice 2 — tests

**Status: obvious in shape** (once slice 1 lands).

New `wat-tests/vocab/exit/regime.wat`. Three tests cover the
delegation contract:

1. **count** — `(:trading::vocab::exit::regime::encode-regime-holons r scales)`
   emits 8 holons.
2. **coincident with market/regime** — same input candle +
   fresh scales fed to both `:trading::vocab::exit::regime::*`
   and `:trading::vocab::market::regime::*` produces holon[0]
   that's coincident? at d=10000. Single-holon coincidence is
   a sufficient delegation witness; if any of the 8 atoms
   diverged, the function bodies would differ and at least one
   would surface.
3. **scales accumulate 7 entries** — same as arc 010's count
   (variance-ratio uses ReciprocalLog, bypasses scales). Direct
   structural check on the second tuple element.

Three is enough. The full 8-atom truth-table tests live in
`wat-tests/vocab/market/regime.wat` (arc 010); arc 021 verifies
the delegation, not the encoding.

**Sub-fogs:**
- (none).

## Slice 3 — INSCRIPTION + doc sweep

**Status: obvious in shape** (once slices 1 – 2 land).

- `docs/arc/2026/04/021-exit-regime-vocab/INSCRIPTION.md`.
  Records: thin-delegation pattern named, exit sub-tree 2 of 4
  shipped, no substrate gaps, contract-only test scope.
- `docs/rewrite-backlog.md` — Phase 2 gains "2.18 shipped" row.
- `docs/proposals/2026/04/058-ast-algebra-surface/FOUNDATION-CHANGELOG.md`
  — row documenting arc 021.
- Task #45 marked completed.
- Lab repo commit + push.
