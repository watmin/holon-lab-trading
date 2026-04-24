# Lab arc 010 — market/regime vocab — BACKLOG

**Shape:** four slices. Zero substrate gaps. Observation pass
completed ahead of BACKLOG (per Chapter 35's reflex — the
program ran before the bounds were locked).

---

## Slice 0 — Log-bounds observation (COMPLETE)

`explore-log.wat` on disk. Ran against d=1024 at three bound
settings (N=2/3/10 ReciprocalLog family). N=10 picked — full
variance-ratio financial range [0.1, 10] preserved, noise near
1.0 collapses. Full table + derivation in DESIGN.

## Slice 1 — vocab module

**Status: ready.**

New file `wat/vocab/market/regime.wat`:
- Loads candle.wat + scale-tracker.wat + scaled-linear.wat.
- Defines `:trading::vocab::market::regime::encode-regime-holons`
  with single-sub-struct signature `(r :Candle::Regime) (scales :Scales)
  -> :VocabEmission`.
- Eight atoms emission: seven scaled-linear threading scales +
  one `ReciprocalLog 10.0` (variance-ratio — no scales
  involvement, Log is stateless).
- Variance-ratio inline-floored at 0.001 via one-sided if.

Load wiring: `wat/main.wat` gains a line for
`vocab/market/regime.wat`.

**Sub-fogs:**
- **1a — ReciprocalLog inside a let\*-bind chain.** Arc 005
  demonstrated the pattern. `:wat::holon::Bind (Atom "variance-ratio")
  (ReciprocalLog 10.0 vr)` expands to the explicit Log form at
  macro time; no runtime surprise.

## Slice 2 — tests

**Status: obvious in shape** (once slice 1 lands).

New file `wat-tests/vocab/market/regime.wat`. Six tests:

1. **count** — 8 holons.
2. **kama-er shape** — fact[0] coincides with hand-built Bind +
   Thermometer (raw, no normalization).
3. **choppiness shape** — fact[1] coincides after `/100.0`
   normalization.
4. **variance-ratio shape** — fact[3] coincides with
   `Bind(Atom("variance-ratio"), ReciprocalLog 10.0 vr-rounded)`.
   The Log expansion itself has a known-at-compile-time shape;
   matching under coincident? confirms no semantic drift.
5. **variance-ratio floor** — raw input 0.0 encodes as if it
   were 0.001 (the floor). Verifies the one-sided if.
6. **different candles differ** — fact[0] (kama-er) of two
   distinct inputs across the scale-rounding boundary.

Helpers in default-prelude: `fresh-regime` constructs
`Candle::Regime` with controllable kama-er + variance-ratio
(six other fields zero — 8-arg constructor).

**Sub-fogs:**
- **2a — Candle::Regime constructor arity.** 8 positional args.
  Test helper sets kama-er + variance-ratio; zeros the rest.
- **2b — ReciprocalLog equivalence.** `(ReciprocalLog N v)`
  macro-expands to `(Log v (/ 1.0 N) N)`. Hand-built expected
  uses explicit Log to match.

## Slice 3 — INSCRIPTION + doc sweep

**Status: obvious in shape** (once slices 1 + 2 land).

- `docs/arc/2026/04/010-market-regime-vocab/INSCRIPTION.md`.
  Records the observation outcome (why N=10) so future readers
  don't re-derive.
- `docs/rewrite-backlog.md` — Phase 2 gains "2.8 shipped" row.
- `docs/proposals/.../058-ast-algebra-surface/FOUNDATION-CHANGELOG.md`
  — row documenting arc 010 + the N=10 bound + observation
  reflex applied a second time.
- Task #34 marked completed.

---

## Working notes

- Opened 2026-04-23 straight after arc 009.
- Second arc to exercise Chapter 35's observation reflex
  (arc 005 was the first). The reflex IS standing practice now;
  this arc confirms it holds outside the original ROC context.
- ReciprocalLog 10.0 IS the first non-N=2 use of the family
  (arc 034). Validates the family's generality.
