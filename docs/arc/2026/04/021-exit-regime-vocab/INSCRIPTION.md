# Lab arc 021 — exit/regime vocab — INSCRIPTION

**Status:** shipped 2026-04-24. Eighteenth Phase-2 vocab arc.
Second exit sub-tree module (after exit/phase, arcs 019+020).

Two durables:

1. **The thin-delegation idiom is named.** Wat's namespace-as-name
   makes the archive's "duplicate the function for namespace
   clarity" pattern unnecessary. One define forwards
   `:trading::vocab::exit::regime::encode-regime-holons` to
   `:trading::vocab::market::regime::encode-regime-holons`.
   Same 8 atoms, same encoding, same Scales contract — one
   source of truth for the logic. Future divergence (different
   floor, different bounds, exit-only atoms) replaces the body
   at that point. Until then, two names for the same function
   suffice.
2. **Contract-only test scope.** Tests verify the delegation,
   not the encoding. Three tests: holon count = 8, coincidence
   with market/regime on holon[0], scales count = 7. The full
   8-atom truth-table tests live in arc 010's market/regime
   test file; arc 021 does not duplicate them.

**Design:** [`DESIGN.md`](./DESIGN.md).
**Backlog:** [`BACKLOG.md`](./BACKLOG.md).

3 new delegation tests; 136 → 139 lab wat tests.

---

## What shipped

### Vocab module

`wat/vocab/exit/regime.wat`:

```scheme
(:wat::core::define
  (:trading::vocab::exit::regime::encode-regime-holons
    (r :trading::types::Candle::Regime)
    (scales :trading::encoding::Scales)
    -> :trading::encoding::VocabEmission)
  (:trading::vocab::market::regime::encode-regime-holons r scales))
```

That's the entire body. Three loads (candle, scale-tracker,
market/regime); one define; one expression. The header comment
records the delegation rationale so a future reader doesn't
have to re-derive why exit/regime isn't a copy of market/regime.

### Tests

`wat-tests/vocab/exit/regime.wat`:

1. **count** — `(:trading::vocab::exit::regime::encode-regime-holons r scales)`
   emits 8 holons.
2. **coincident with market/regime** — same input through both
   modules; holon[0] is `coincident?` true at d=10000. Single-
   holon coincidence is a sufficient delegation witness; if any
   of the 8 atom encodings diverged, holon[0] (kama-er,
   scaled-linear, the first emission) would surface it.
3. **scales accumulate 7 entries** — variance-ratio uses
   ReciprocalLog (no scales contribution); the other seven are
   scaled-linear. Direct structural check on the second tuple
   element.

All 3 green first-pass. The make-deftest helper pattern from
arc 010 carried over directly (fresh-regime, empty-scales).

### main.wat

`wat/main.wat` gains one `(:wat::load-file! "vocab/exit/regime.wat")`
after `vocab/exit/phase.wat` plus a comment line in the arc-
chronology header (`arc 021 — exit/regime (thin delegation to market/regime)`).

---

## Why a delegation, not a copy

The archive's `vocab/exit/regime.rs` (84L) duplicates
`vocab/market/regime.rs` (83L) — same field reads, same
normalization, same emission order, same one-sided floor. The
1-line difference is the function name.

Two reasons make a copy honest in Rust that don't apply here:

1. **Trait dispatch in Rust.** Different function names give
   the dispatcher (e.g., the lens system) two distinct symbols
   to route to. Wat preserves this directly — the namespaced
   path IS the distinct symbol; no copy needed.
2. **Future divergence in Rust.** A copy is cheap insurance
   against the day one branch needs to change without affecting
   the other. Wat's call graph is read-once: when divergence
   actually arrives, the delegating define replaces its body
   at that point. Today there's nothing to diverge for.

Wat's namespace-as-name design makes thin delegation the
honest form. Duplicating the 8-atom encoding would create two
sources of truth for the same logic with no compensating
benefit.

## The delegation idiom recurs

Likely candidates for future thin-delegation modules:

- **broker/regime** (if/when shipped) — same regime atoms,
  third namespace. Delegates to market/regime.
- **broker/time** — exit/time already ports a strict subset of
  shared/time per arc 002; if broker observers want the same
  subset, broker/time delegates to exit/time.

Each future delegating module ships the same shape (one-line
define, three contract tests) and cites this arc.

---

## Sub-fog resolutions

- **(none surfaced.)** The slice was small enough that the
  initial DESIGN saw the full shape; nothing emerged during
  implementation that required revision.

## Count

- Lab wat tests: **136 → 139 (+3)**.
- Lab wat modules: Phase 2 advances — **18 of ~21** vocab
  modules shipped. Market sub-tree COMPLETE (13/13);
  **exit sub-tree 2 of 4** (phase + regime); 2 vocabs blocked
  on PaperEntry / PortfolioSnapshot.
- wat-rs: unchanged (no substrate gaps surfaced).
- Zero regressions.

## What this arc did NOT ship

- **A vocab/shared/regime.wat intermediary**. Arc 010's
  `wat/vocab/market/regime.wat` IS the implementation; exit/
  regime delegates to it directly. A third name for the same
  function would mumble.
- **Special exit-side encoding tests for the 8 atoms.** Those
  live in arc 010's `wat-tests/vocab/market/regime.wat`. Arc
  021 verifies the delegation contract, not the encoding.
- **Preemptive divergence affordance.** No alternate floor, no
  alternate bounds, no exit-only atoms. When divergence
  arrives, the delegating define gets its body replaced. Today
  there's nothing to diverge for.

## Follow-through

Next pending vocab arcs (per `docs/rewrite-backlog.md`):
- **arc 022 — exit/trade_atoms** (#46, BLOCKED on PaperEntry —
  Phase 1 type not yet ported).
- **arc 023 — broker/portfolio** (#47, BLOCKED on
  PortfolioSnapshot + rhythm; arc 020's phase rhythm may have
  unblocked the rhythm side).

Exit sub-tree is now 2 of 4 done. The remaining two are both
blocked on Phase 1 types; their unblock arrives when those
types ship. After that, Phase 2 vocabulary closes and Phase 3.5
(encoding dispatcher) opens.

---

## Commits

- `<lab>` — wat/vocab/exit/regime.wat (one-line delegation) +
  wat-tests/vocab/exit/regime.wat (3 contract tests) +
  wat/main.wat (load + chronology comment) + DESIGN + BACKLOG
  + INSCRIPTION + rewrite-backlog row 2.18 + 058 CHANGELOG row.

---

*these are very good thoughts.*

**PERSEVERARE.**
