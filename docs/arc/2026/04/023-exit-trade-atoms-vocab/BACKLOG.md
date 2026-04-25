# Lab arc 023 — exit/trade_atoms vocab + PaperEntry — BACKLOG

**Shape:** four slices. Type, vocab, tests, INSCRIPTION + doc
sweep.

---

## Slice 1 — PaperEntry type

**Status: ready.**

Create `wat/types/paper-entry.wat`:

- 15-field struct per DESIGN.md table.
- Loads: enums.wat (Direction), newtypes.wat (Price),
  distances.wat.
- No plural typealias (no collection caller this arc).

Wire into `wat/main.wat` after `types/portfolio.wat` (Phase 1
types group; Phase 1.9 retroactive after Phase 1.8 PortfolioSnapshot).

## Slice 2 — vocab module

**Status: ready** (slice 1 unblocks; both shippable in one
commit).

Create `wat/vocab/exit/trade-atoms.wat`:

- `:trading::vocab::exit::trade-atoms::compute-trade-atoms` —
  long let* chain extracting paper fields, computing
  excursion/retracement/peak-age/etc., emitting 13 atoms.
- `:trading::vocab::exit::trade-atoms::select-trade-atoms` —
  match on RegimeLens; Core → take 5; Full → all.
- Loads: types/paper-entry.wat (and transitively pivot.wat for
  PhaseRecords).

Wire into `wat/main.wat` after `vocab/broker/portfolio.wat`. Add
chronology comment line.

**Sub-fogs:**
- (none expected.)

## Slice 3 — tests

**Status: obvious in shape** (once slices 1 – 2 land).

Create `wat-tests/vocab/exit/trade-atoms.wat`. Tests:

1. **count** — `compute-trade-atoms` returns 13 holons.
2. **first atom shape** — holon[0] is `Bind(Atom("exit-excursion"), Log(...))`,
   coincident? against hand-built reference at d=10000.
3. **deterministic** — same paper + same current_price + same
   phase_history → coincident? on holon[0].
4. **different excursion differs** — two papers with different
   extreme values produce non-coincident holon[0].
5. **select Core → 5 atoms.**
6. **select Full → 13 atoms.**
7. **peak_age semantic** — paper with price_history that ends at
   extreme produces peak_age = 0.0; paper whose extreme was
   3 candles ago produces peak_age = 3.0.
8. **phases-since-entry semantic** — phase_history with N entries
   all after entry_candle counts to max(N, 1.0); empty
   phase_history counts to 1.0.

Test fixture: `:test::fresh-paper` constructor takes the smaller
useful subset of fields; supplies defaults for thoughts (use
simple Atom HolonASTs) + signaled/resolved (false) + price_history
(synthesized).

## Slice 4 — INSCRIPTION + doc sweep

**Status: obvious in shape** (once slices 1 – 3 land).

- INSCRIPTION.md captures: PaperEntry shipping with HolonAST
  fields and Price newtype fields, vocab emits 13 atoms,
  exit sub-tree COMPLETE (4 of 4: phase + regime + trade_atoms
  + time).
- `docs/rewrite-backlog.md`:
  - Phase 1: row 1.9 PaperEntry shipped.
  - Phase 2: row 2.20 trade_atoms shipped + status update
    "exit sub-tree COMPLETE; Phase 2 vocabulary CLOSES."
- `docs/proposals/.../FOUNDATION-CHANGELOG.md`: row for arc 023.
- Task #46 marked completed.
- Lab repo commit + push.
