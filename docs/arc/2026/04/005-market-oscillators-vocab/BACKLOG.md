# Lab arc 005 — market/oscillators vocab — BACKLOG

**Shape:** three slices. Cave-quested wat-rs arc 034
(ReciprocalLog) mid-arc; resumed here.

---

## Slice 1 — vocab module

**Status: ready** (now that arc 034 shipped).

New file `wat/vocab/market/oscillators.wat`:
- Loads `../../types/candle.wat` + `../../encoding/scale-tracker.wat`
  + `../../encoding/scaled-linear.wat`.
- Defines `:trading::vocab::market::oscillators::encode-oscillators-holons`
  with signature `(Momentum, RateOfChange, Scales) → (Holons, Scales)`.
- Threads `scaled-linear` four times for RSI/CCI/MFI/WilliamsR.
- Emits four `ReciprocalLog 2.0` calls for ROC-1/3/6/12.
- Returns tuple of 8-element Holons and final Scales.

Load wiring: `wat/main.wat` gains a line for
`vocab/market/oscillators.wat`.

**Sub-fogs:**
- **1a — return-tuple naming.** The `(Holons, Scales)` tuple IS a
  new shape. First caller (this module). Defer naming; if a
  second vocab module produces the same shape, extract an alias
  then.

## Slice 2 — tests

**Status: obvious in shape** (once slice 1 lands).

New file `wat-tests/vocab/market/oscillators.wat`. Five tests:

1. `test-holons-count` — 8 holons returned.
2. `test-rsi-holon-shape` — fact[0] coincides with hand-built
   Bind(Atom("rsi"), Thermometer(...)).
3. `test-roc-1-holon-shape` — fact[4] coincides with hand-built
   Bind(Atom("roc-1"), Log(...)) (ReciprocalLog 2.0 expansion).
4. `test-scales-accumulate-4-entries` — updated scales has 4
   keys (rsi, cci, mfi, williams-r) after one call.
5. `test-different-candles-differ` — two distinct input candles
   produce non-coincident holons in their scaled-linear portions
   (ROCs may coincide if values saturate; testing scaled-linear
   variation is the cleaner claim).

Uses arc 031's `make-deftest` + inherited-config shape.

**Sub-fogs:**
- **2a — constructing Candle::Momentum and Candle::RateOfChange
  in tests.** Both are structs auto-generated from their wat
  struct decls (arc 019). Constructor syntax:
  `(:trading::types::Candle::Momentum/new rsi macd-hist ... volume-accel)`
  — positional, matches field order. Verify by inspection of
  `wat/types/candle.wat`.

## Slice 3 — INSCRIPTION + backlog update

**Status: obvious in shape** (once slices 1 + 2 land).

- `docs/arc/2026/04/005-market-oscillators-vocab/INSCRIPTION.md`
- `docs/rewrite-backlog.md` — Phase 2 gains "2.3 shipped" row;
  market sub-tree opens.
- `docs/proposals/2026/04/058-ast-algebra-surface/FOUNDATION-CHANGELOG.md`
  — row documenting arc 005.

**Sub-fogs:**
- **3a — BOOK chapter?** No — arc 005 is phase-work not moment-
  work. The Chapter 34 opening already captured the naming
  reflex; subsequent vocab ports inherit the reflex without
  needing new narrative.

---

## Working notes

- Opened 2026-04-23, paused for wat-rs arc 034 (ReciprocalLog
  macro), resumed same session.
- Exploration program (`explore-log.wat`) shipped alongside this
  DESIGN; stays on disk as the empirical record of why bounds
  (0.5, 2.0) were chosen.
