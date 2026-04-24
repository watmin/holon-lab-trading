# Lab arc 007 — market/fibonacci vocab — BACKLOG

**Shape:** three slices. Zero substrate gaps expected.

Single sub-struct (same shape as arc 005's oscillators but simpler —
no Log, no conditional emission). Pattern is the stdlib blueprint
arcs 005 and 006 have already established.

---

## Slice 1 — vocab module

**Status: ready.**

New file `wat/vocab/market/fibonacci.wat`:
- Loads `../../types/candle.wat` + `../../encoding/scale-tracker.wat`
  + `../../encoding/scaled-linear.wat`.
- Defines `:trading::vocab::market::fibonacci::encode-fibonacci-holons`
  with signature `(RateOfChange, Scales) → VocabEmission`.
- Threads `scaled-linear` eight times — three `range-pos-*` atoms
  followed by five `fib-dist-*` atoms (each computed as
  `range_pos_48 - level`).
- Returns the 8-element `(Holons, Scales)` tuple as `VocabEmission`.

Load wiring: `wat/main.wat` gains a line for
`vocab/market/fibonacci.wat`.

**Sub-fogs:**
- **1a — `round-to-2` of a computed `f64::-`.** The fib-dist atoms
  subtract a literal Fibonacci level from `range_pos_48` before
  rounding. `round-to-2` takes an `:f64` and returns an `:f64`;
  no issue expected.

## Slice 2 — tests

**Status: obvious in shape** (once slice 1 lands).

New file `wat-tests/vocab/market/fibonacci.wat`. Five tests:

1. `test-holons-count` — 8 holons returned.
2. `test-range-pos-12-shape` — fact[0] coincides with hand-built
   `Bind(Atom("range-pos-12"), Thermometer(rounded, -scale, scale))`.
   Scale comes from a fresh tracker's first update at the rounded
   value.
3. `test-fib-dist-500-shape` — fact[5] coincides with hand-built
   `Bind(Atom("fib-dist-500"), Thermometer(round-to-2(range_pos_48
   - 0.5), -scale, scale))`. Proves the subtraction math survives
   the round trip.
4. `test-scales-accumulate-8-entries` — updated scales has 8 keys
   (range-pos-12/24/48 + fib-dist-236/382/500/618/786) after one
   call.
5. `test-different-candles-differ` — two distinct input
   `RateOfChange` values produce non-coincident holons.

Helpers in the `make-deftest` default-prelude per arc 003's
pattern: `fresh-roc` constructs a `Candle::RateOfChange` with
controllable range-pos-12/24/48 (ROC fields zero).

**Sub-fogs:**
- **2a — `Candle::RateOfChange` constructor arity.** Seven
  positional args per `wat/types/candle.wat` — roc-1/3/6/12
  followed by range-pos-12/24/48. Test helper sets the three
  range-pos values, zeros the four roc fields.

## Slice 3 — INSCRIPTION + backlog update

**Status: obvious in shape** (once slices 1 + 2 land).

- `docs/arc/2026/04/007-market-fibonacci-vocab/INSCRIPTION.md`
- `docs/rewrite-backlog.md` — Phase 2 gains "2.5 shipped" row.
- `docs/proposals/2026/04/058-ast-algebra-surface/FOUNDATION-CHANGELOG.md`
  — row documenting arc 007.

---

## Working notes

- Opened 2026-04-23 as the sixth Phase-2 arc. Third clean leaf
  after arcs 001 (shared/time), 002 (exit/time), 005 (oscillators).
  No new primitives surface; pattern is stdlib-as-blueprint.
- Fibonacci reads from `Candle::RateOfChange` rather than
  `Candle` directly — the range-pos-* fields live on that
  sub-struct per the Phase-1 split. Shares the struct with
  oscillators but reads disjoint fields (roc-* vs range-pos-*).
