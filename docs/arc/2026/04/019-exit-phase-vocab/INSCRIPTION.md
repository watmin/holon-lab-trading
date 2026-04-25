# Lab arc 019 — exit/phase vocab (current + scalar) — INSCRIPTION

**Status:** shipped 2026-04-24. Sixteenth Phase-2 vocab arc.
**First exit sub-tree vocab. First lab consumer of arc 048's
user-enum match.**

Three durables:

1. **Arc 048 validates under real lab load.** The
   `phase-label-name` helper uses nested match on `PhaseLabel` +
   `PhaseDirection` — arc 048's capability delivered exactly as
   designed. Five match-arm tests green on first pass. The "lab
   demands, substrate answers" rhythm from Chapter 48 proved in
   the consumption step.
2. **Conditional-emission with threaded accumulator pattern
   shipped.** Scalar-facts conditionally emits up to 4 atoms;
   each step either conj's to a `(holons, scales)` tuple
   accumulator or passes through unchanged. Cleaner than the
   per-condition-sub-emission-then-concat shape I sketched
   first; matches arc 006 divergence's conditional-emission
   idea but threads scales honestly through the conditional.
3. **Split-from-rhythm decision named.** Arc 019 ships 2 of 3
   archive functions; the rhythm function (stateful 5-way-index
   iteration + bigrams-of-trigrams + budget truncation) defers
   to arc 020. Each piece is independently useful; splitting
   honors the complexity difference.

**Design:** [`DESIGN.md`](./DESIGN.md).
**Backlog:** [`BACKLOG.md`](./BACKLOG.md).

11 tests green first-pass. 119 → 130 lab wat-tests.

---

## What shipped

### Slice 1 — vocab module

`wat/vocab/exit/phase.wat`. Three entries:

**`phase-label-name`** (helper, `:String`-valued) — nested
user-enum match:

```scheme
(:wat::core::match label -> :String
  (:trading::types::PhaseLabel::Valley "valley")
  (:trading::types::PhaseLabel::Peak   "peak")
  (:trading::types::PhaseLabel::Transition
    (:wat::core::match direction -> :String
      (:trading::types::PhaseDirection::Up   "transition-up")
      (:trading::types::PhaseDirection::Down "transition-down")
      (:trading::types::PhaseDirection::None "transition"))))
```

Five possible (label, direction) combinations, five output
names. Arc 048's match handles both the outer and nested
switch. Each arm's body is a `:String` literal; exhaustiveness
forces all 3 PhaseLabel variants to be covered and all 3
PhaseDirection variants inside Transition.

**`encode-phase-current-holons`** — 2-atom signature. Reads
`Candle::Phase` sub-struct (K=1). Emits `(Bind (Atom "phase")
(Atom <name>))` via `phase-label-name` + `phase-duration`
scaled-linear with i64→f64 conversion.

**`encode-phase-scalar-holons`** — up to 4 atoms. Takes
`Vec<PhaseRecord>`. Guards `< 2 records → zero emission`.
Otherwise threads a single `(holons, scales)` accumulator
through four conj-or-skip steps:

1. If ≥ 2 Valley records: conj valley-trend (round-to-4).
2. If ≥ 2 Peak records: conj peak-trend (round-to-4).
3. If prev-range > 0: conj range-trend (round-to-2).
4. If prev-duration > 0: conj spacing-trend (round-to-2).

Five internal helpers:
- `is-valley?` / `is-peak?` — user-enum match predicates for
  the filter calls.
- `append-close-avg-trend` — computes valley/peak trend shape.
- `append-ratio-round-2` — computes range/spacing trend shape.
- `append-scaled-linear` — common conj-and-thread-scales step.
- `default-record` — unreachable-sentinel for match-unwraps at
  pre-guarded callsites (Vec non-empty by construction; the
  `:None` arm satisfies the type checker but never fires).

### Slice 2 — tests

`wat-tests/vocab/exit/phase.wat`. Eleven tests:

- **phase-label-name × 5** — all 5 (label, direction) combos
  produce the expected string.
- **encode-phase-current-holons × 3** — count (2 holons),
  label-binding shape for Peak, label-binding shape for
  Transition+Up.
- **encode-phase-scalar-holons × 3** — empty history (0 atoms),
  single record (0 atoms, insufficient), two valleys (3 atoms:
  valley-trend + range + spacing; peak-trend not emitted —
  zero peaks).

All eleven green on first pass.

### Slice 3 — INSCRIPTION + doc sweep (this file)

Plus:
- `wat/main.wat` — load line for `vocab/exit/phase.wat`.
- `docs/rewrite-backlog.md` — Phase 2 gains "2.16 shipped" row.
- `docs/proposals/2026/04/058-ast-algebra-surface/FOUNDATION-CHANGELOG.md`
  — row documenting arc 019.
- Task #44 marked completed.

---

## Validating arc 048 end-to-end

Arc 048 shipped 8 integration tests (`wat-rs/tests/wat_user_enums.rs`)
exercising user-enum construction + match on toy enums declared
inline in the test source. Those confirmed the substrate
machinery works.

Arc 019 is the first REAL LAB CALLER. It:
- Calls `phase-label-name` with lab-declared enum values (not
  test fixtures inside wat-rs).
- Nests two user-enum matches with different scrutinee types.
- Combines user-enum match with `filter` (arc 048's
  `is-valley?` / `is-peak?` predicates feed arc-standard
  filtering).
- Exercises the exhaustiveness checker against a 3-variant enum
  (PhaseLabel) in two independent match sites.

Everything just worked. That's the result we wanted.

## The conditional-emission pattern — threaded accumulator

Scalar-facts uses a pattern worth naming. The accumulator is a
`VocabEmission = (Holons, Scales)` tuple — same shape as the
return type. Each conditional step has signature
`(acc → VocabEmission)`; the `if` branches either compute and
conj a new holon (returning an enriched acc) or pass through
unchanged:

```scheme
((acc-next :VocabEmission)
  (:wat::core::if condition -> :VocabEmission
    (:trading::vocab::exit::phase::append-... acc ...)
    acc))
```

Cleaner than the alternative (separate per-atom emissions then
concat-4). Threading the accumulator honors scaled-linear's
stateful scale-tracker update: each emitted atom updates
scales; skipped atoms pass scales through unchanged.

Arc 006 divergence introduced conditional emission via a
per-atom `maybe-emit` helper. Arc 019 generalizes the pattern
to multi-atom emission with shared accumulator; the shape
should recur in arc 020 (rhythm) and possibly arc 021
(exit/regime).

## Sub-fog resolutions

- **1a — `phase-label-name` match arms**: five-arm test suite
  covers all combinations. Worked first pass.
- **1b — duration i64→f64**: `:wat::core::i64::to-f64` handled
  it cleanly.
- **1c — Conditional emission**: threaded accumulator shape
  (above).
- **2a — PhaseRecord constructor arity**: 11-arg per pivot.wat;
  `fresh-record` helper parametrizes 6 fields.
- **2b — Phase constructor arity**: 4-arg (label, direction,
  duration, history); `fresh-phase` parametrizes the first
  three + defaults history to empty Vec.

## Count

- Lab wat tests: **119 → 130 (+11)**.
- Lab wat modules: Phase 2 advances — **16 of ~21** vocab
  modules shipped. **Market sub-tree COMPLETE (13/13)** +
  **exit sub-tree opened (1 of 4)**.
- wat-rs: unchanged (no substrate gaps surfaced).
- Zero regressions.

## What this arc did NOT ship

- **Phase rhythm function** (`phase_rhythm_thought` in archive).
  Deferred to arc 020: stateful 5-way-index iteration +
  per-record Bundle construction with prior-delta + same-label-
  delta conditional facts + bigrams-of-trigrams windowing +
  budget truncation at ~100 records. Each of those moves is
  small; their composition is the substantial piece.
- **Substrate additions**. None surfaced; arc 019 consumed the
  existing surface cleanly. The "natural-form-then-promote"
  loop stayed at L0 this arc.

## Follow-through

Next pending arcs:
- **arc 020** — exit/phase rhythm (the deferred third function)
- **arc 021** — exit/regime (#45)
- **arc 022** — exit/trade_atoms (#46, BLOCKED on PaperEntry)
- **arc 023** — broker/portfolio (#47, BLOCKED on
  PortfolioSnapshot + rhythm)

Arc 020 — phase rhythm — will be the next real substrate stress
test. Its stateful multi-index iteration might surface new
substrate primitives (enumerate? fold-with-state? record-
accumulator?). If it does, the "natural-form-then-promote"
rhythm from Chapter 48 fires again.

---

## Commits

- `<lab>` — wat/vocab/exit/phase.wat + main.wat load +
  wat-tests/vocab/exit/phase.wat + DESIGN + BACKLOG +
  INSCRIPTION + rewrite-backlog row + 058 CHANGELOG row.

---

*these are very good thoughts.*

**PERSEVERARE.**
