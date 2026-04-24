# Lab arc 008 — market/persistence vocab — BACKLOG

**Shape:** three slices. Zero substrate gaps. Rule being
codified; no code-level fog.

---

## Slice 1 — vocab module

**Status: ready.**

New file `wat/vocab/market/persistence.wat`:
- Loads `../../types/candle.wat` + `../../encoding/scale-tracker.wat`
  + `../../encoding/scaled-linear.wat`.
- Defines `:trading::vocab::market::persistence::encode-persistence-holons`
  with alphabetical sub-struct signature: `(m :Momentum) (p :Persistence) (scales :Scales) -> :VocabEmission`.
- Three scaled-linear calls threading scales values-up.
- Emission order matches archive: hurst, autocorrelation, adx.

Load wiring: `wat/main.wat` gains a line for
`vocab/market/persistence.wat`.

**Sub-fogs:**
- **1a — adx field access.** `adx` lives on `Candle::Momentum`
  per `candle.wat`. Access via `:Candle::Momentum/adx m`.
- **1b — adx normalization.** Archive divides by 100. Same
  pattern oscillators' cci/mfi/williams-r use — no new surface.

## Slice 2 — tests

**Status: obvious in shape** (once slice 1 lands).

New file `wat-tests/vocab/market/persistence.wat`. Five tests:

1. **count** — 3 holons returned.
2. **hurst shape** — fact[0] coincides with hand-built
   `Bind(Atom("hurst"), Thermometer(rounded, -scale, scale))`.
3. **adx shape** — fact[2] verifies the `/ 100.0` normalization
   survives: `round-to-2(50.0 / 100.0) = 0.5` round-trips.
4. **scales accumulate 3 entries** — updated Scales has 3 keys.
5. **different candles differ** — distinct inputs produce
   non-coincident holons in fact[0].

Helpers in `make-deftest` default-prelude: `fresh-momentum`
constructs `Candle::Momentum` with a controllable adx (all
other fields zero — 12-arg constructor per candle.wat);
`fresh-persistence` constructs `Candle::Persistence` with
controllable hurst + autocorrelation (vwap-distance zero).

**Sub-fogs:**
- **2a — Candle::Momentum constructor arity.** 12 positional
  args per `wat/types/candle.wat`. Test helper lets the test
  body care only about adx.
- **2b — Candle::Persistence constructor arity.** 3 positional
  args (hurst, autocorrelation, vwap-distance).

## Slice 3 — INSCRIPTION + backlog update

**Status: obvious in shape** (once slices 1 + 2 land).

- `docs/arc/2026/04/008-market-persistence-vocab/INSCRIPTION.md`
  — the arc record + the rule explicitly recorded for future
  cross-sub-struct arcs to cite.
- `docs/rewrite-backlog.md` — Phase 2 gains "2.6 shipped" row
  **plus a top-of-Phase-2 note naming the cross-sub-struct
  signature rule** (so the rule is visible to future arcs
  without having to open arc 008's INSCRIPTION).
- `docs/proposals/.../058-ast-algebra-surface/FOUNDATION-CHANGELOG.md`
  — row documenting arc 008 + the rule resolution.
- Task #49 marked completed.

---

## Working notes

- Opened 2026-04-23 straight after the naming-sweep session
  closed. First cross-sub-struct exercise of task #49's rule.
- Simplest possible shape by design — every piece of variance
  is either already shipped (scaled-linear, VocabEmission,
  alphabetical-by-type ordering) or locked by the rule.
- After ship: remaining cross-sub-struct arcs inherit the rule
  and can ship in parallel; the only remaining per-module fog
  is Log bound observation (for modules with Log atoms).
