# Lab arc 019 — exit/phase vocab (current + scalar) — BACKLOG

**Shape:** three slices. First exit sub-tree vocab. First lab
consumer of arc 048's user-enum match.

---

## Slice 1 — vocab module

**Status: ready.**

New file `wat/vocab/exit/phase.wat`:
- Loads candle.wat + pivot.wat + round.wat + scale-tracker.wat +
  scaled-linear.wat. (No shared/helpers.wat needed.)
- Defines the helper `:trading::vocab::exit::phase::phase-label-name`
  (nested match on PhaseLabel + PhaseDirection → String).
- Defines `:trading::vocab::exit::phase::encode-phase-current-holons`:
  - 2 atoms — phase-label binding + phase-duration scaled-linear.
  - Signature `(p :Candle::Phase) (scales :Scales) -> VocabEmission`.
- Defines `:trading::vocab::exit::phase::encode-phase-scalar-holons`:
  - Up to 4 atoms — valley-trend, peak-trend, range-trend,
    spacing-trend, each conditionally emitted based on history
    composition.
  - Signature `(history :Vec<PhaseRecord>) (scales :Scales) ->
    VocabEmission`.
  - Uses filter + last + get (len - 2) for the subset-last-two
    pattern.

Wiring: `wat/main.wat` gains load line for `vocab/exit/phase.wat`.

**Sub-fogs:**
- **1a — `phase-label-name` match arms.** Nested match with both
  `PhaseLabel` and `PhaseDirection` scrutinees. Arc 048 should
  handle this; first lab exercise of the capability.
- **1b — phase-duration i64→f64.** `(:Candle::Phase/duration p)`
  returns i64; scaled-linear wants f64. Use `:wat::core::i64::to-f64`.
- **1c — Conditional emission pattern.** Scalar-facts builds the
  Holons vec incrementally. Compute each trend value; if
  precondition holds, conj onto holons; else skip. Threading
  scales through each conj'd atom; the initial scales flow
  through unchanged if all conditions fail.

## Slice 2 — tests

**Status: obvious in shape** (once slice 1 lands).

New file `wat-tests/vocab/exit/phase.wat`. Tests to cover:

1. **phase-label-name: Valley** — returns "valley" for
   PhaseLabel::Valley + PhaseDirection::None.
2. **phase-label-name: Peak** — returns "peak".
3. **phase-label-name: Transition + Up** — returns "transition-up".
4. **phase-label-name: Transition + Down** — returns "transition-down".
5. **phase-label-name: Transition + None** — returns "transition".
6. **encode-phase-current-holons: 2 holons** — basic count.
7. **encode-phase-current-holons: phase-label shape** — fact[0]
   matches (Bind (Atom "phase") (Atom "valley")) for a Valley/None
   phase.
8. **encode-phase-current-holons: phase-duration shape** — fact[1]
   scaled-linear of duration.
9. **encode-phase-scalar-holons: empty history** — 0 atoms.
10. **encode-phase-scalar-holons: single-record history** — 0 atoms
    (conditions require ≥ 2).
11. **encode-phase-scalar-holons: two valleys** — emits valley-trend.
12. **encode-phase-scalar-holons: range + spacing** — last-two
    records emit both range and spacing trends when their
    preconditions hold.

Helpers in default-prelude:
- `fresh-phase` — PhaseLabel + PhaseDirection + duration controllable.
- `fresh-record` — PhaseLabel + duration + close values controllable.
- `empty-scales`.

**Sub-fogs:**
- **2a — PhaseRecord constructor arity.** 11-arg per pivot.wat;
  helper parametrizes the relevant fields, defaults the rest.
- **2b — Phase constructor arity.** 4-arg (label, direction,
  duration, history).

## Slice 3 — INSCRIPTION + doc sweep

**Status: obvious in shape** (once slices 1 – 2 land).

- `docs/arc/2026/04/019-exit-phase-vocab/INSCRIPTION.md`. Records:
  first exit vocab, first lab user-enum match consumer (validates
  arc 048), the split-from-rhythm decision, scalar-facts'
  conditional-emission shape.
- `docs/rewrite-backlog.md` — Phase 2 gains "2.16 shipped" row.
- `docs/proposals/2026/04/058-ast-algebra-surface/FOUNDATION-CHANGELOG.md`
  — row documenting arc 019.
- Task #44 marked completed.
- Lab repo commit + push.

---

## Working notes

- Opened 2026-04-24 after market sub-tree completed (arc 018 +
  wat-rs arcs 047 + 048 + BOOK Chapter 48 shipped).
- First vocab in the exit sub-tree; the regime observer's
  downstream reader.
- The phase-label-name helper is the first lab code to exercise
  arc 048's user-enum match in a non-test context. Works here =
  real-world validation of arc 048.
