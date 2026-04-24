# Lab arc 006 — market/divergence vocab — BACKLOG

**Shape:** three slices. Zero substrate gaps expected.

---

## Slice 1 — module + helper

**Status: ready.**

New file `wat/vocab/market/divergence.wat`:
- Loads `../../types/candle.wat` + `../../encoding/scaled-linear.wat`
  + `../../encoding/round.wat`.
- File-private helper
  `:trading::vocab::market::divergence::maybe-scaled-linear` —
  threads one conditional-emission step through (holons, scales).
- Public define
  `:trading::vocab::market::divergence::encode-divergence-holons`
  — three sequential `maybe-scaled-linear` calls; emits 0-3 holons.

Load wiring: `wat/main.wat` gains a line for
`vocab/market/divergence.wat`.

**Sub-fogs:**
- **1a — `:bool` in if.** Arc 031's sandbox-inheritance confirmed
  `:wat::core::if` works with `:bool` discriminator. No issue
  expected.
- **1b — conj on empty Vec.** `:wat::core::conj` on an empty
  Vec returns a 1-element Vec. Tested in arc 025's container
  surface; no issue.

## Slice 2 — tests

**Status: obvious in shape** (once slice 1 lands).

New file `wat-tests/vocab/market/divergence.wat`. Six tests
covering the conditional-emission truth table:

1. **no-emit** — bull=0.0, bear=0.0 → Holons empty (length 0).
2. **bull-only** — bull>0, bear=0 → 2 holons (bull + spread).
3. **bear-only** — bull=0, bear>0 → 2 holons (bear + spread).
4. **both** — bull>0, bear>0 → 3 holons.
5. **bull shape** — fact[0] with bull-only coincides with
   hand-built `Bind(Atom("rsi-divergence-bull"), Thermometer(...))`.
6. **no-emit preserves scales** — when no atom fires, the returned
   `Scales` equals the input (no updates propagated). Verify
   via `:wat::core::contains?` returning false for every atom
   name after an empty-emission call.

Helpers in the `make-deftest` default-prelude per arc 003's
pattern: `fresh-divergence` constructs a `Candle::Divergence`
with controllable bull/bear values (other fields zero).

**Sub-fogs:**
- **2a — `Candle::Divergence` field count.** 4 fields
  (rsi-divergence-bull, rsi-divergence-bear, tk-cross-delta,
  stoch-cross-delta). Constructor takes positional args; test
  helper sets bull/bear explicitly, rest to 0.0.

## Slice 3 — INSCRIPTION + backlog update

**Status: obvious in shape** (once slices 1 + 2 land).

- `docs/arc/2026/04/006-market-divergence-vocab/INSCRIPTION.md`
- `docs/rewrite-backlog.md` — Phase 2 gains "2.4 shipped" row.
- `docs/proposals/2026/04/058-ast-algebra-surface/FOUNDATION-CHANGELOG.md`
  — row documenting arc 006 + the conditional-emission idiom.

---

## Working notes

- Opened 2026-04-23 as the fifth arc of the naming-reflex session
  (after Chapter 35's close proposed continuing). First
  conditional-emission vocab; pattern resolved here for
  downstream modules (trade_atoms likely next).
