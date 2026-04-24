# Lab arc 011 — market/timeframe vocab — BACKLOG

**Shape:** four slices. Zero substrate gaps. One helper add
(`round-to-4`), one rule clarification (leaf-name ordering).

---

## Slice 1 — round-to-4 helper

**Status: ready.**

Extend `wat/encoding/round.wat` with a sibling helper:

```scheme
(:wat::core::define
  (:trading::encoding::round-to-4
    (v :f64)
    -> :f64)
  (:wat::core::f64::round v 4))
```

Zero logic change to `round-to-2`. The file's comment mentions
"fixing the digit count at 2" — update to name both shipped
widths and the stdlib-as-blueprint reason for not generalizing
yet.

**Sub-fogs:** none expected. Arc 019 shipped the
`:wat::core::f64::round` primitive generically.

## Slice 2 — vocab module

**Status: ready** (after slice 1).

New file `wat/vocab/market/timeframe.wat`:
- Loads candle.wat + ohlcv.wat + scale-tracker.wat +
  scaled-linear.wat + round.wat.
- Defines `:trading::vocab::market::timeframe::encode-timeframe-holons`
  with signature `(o :Ohlcv) (t :Candle::Timeframe) (scales :Scales)
  -> :VocabEmission`. Leaf-name alphabetical (O < T).
- Six scaled-linear calls threading scales. Atoms 1/3/5 use
  `round-to-4`; atoms 0/2/4 use `round-to-2`.
- Atom 5 (`tf-5m-1h-align`) computes inline via signum-of-f64 +
  (close - open)/close.

Load wiring: `wat/main.wat` gains a line for
`vocab/market/timeframe.wat`.

**Sub-fogs:**
- **2a — Ohlcv struct path.** `:trading::types::Ohlcv` declared
  in `wat/types/ohlcv.wat`; auto-generates
  `:trading::types::Ohlcv/close`, `/open`, etc. First vocab use.
- **2b — Candle::Timeframe field names.** Per candle.wat the
  fields are `tf-1h-ret`, `tf-1h-body`, `tf-4h-ret`, `tf-4h-body`,
  `tf-agreement` (order matters for the 5-arg constructor).
  Note: body, not trend — the archive renames at the atom level
  (`tf-1h-trend` atom reads tf-1h-body field). Preserve atom
  names exactly.

## Slice 3 — tests

**Status: obvious in shape** (once slice 2 lands).

New file `wat-tests/vocab/market/timeframe.wat`. Six tests:

1. **count** — 6 holons.
2. **tf-1h-trend shape** — fact[0], `round-to-2(tf-1h-body)`
   via Thermometer. Timeframe-sub-struct read only.
3. **tf-1h-ret shape** — fact[1], `round-to-4(tf-1h-ret)` via
   Thermometer. Verifies round-to-4 path.
4. **tf-5m-1h-align computed** — fact[5] matches the hand-
   computed `signum(tf-1h-body) × (close - open)/close`
   rounded to 4. Exercises cross-sub-struct compute + signum.
5. **scales accumulate 6 entries** — all six atom names land.
6. **different candles differ** — fact[0] across scale boundary.

Helpers in default-prelude: `fresh-ohlcv` (controllable open +
close; other fields defaulted), `fresh-timeframe` (controllable
tf-1h-body + tf-1h-ret; other fields defaulted).

**Sub-fogs:**
- **3a — Ohlcv constructor arity.** 8 positional args per
  ohlcv.wat (source-asset, target-asset, ts, open, high, low,
  close, volume). First two are `Asset` structs; need defaults.
- **3b — Asset default.** Test helper can construct `Asset/new "BTC"`
  or similar once — pass as both source + target for simplicity.
- **3c — Candle::Timeframe constructor arity.** 5 positional
  args (see 2b above).

## Slice 4 — INSCRIPTION + doc sweep

**Status: obvious in shape** (once slices 1 – 3 land).

- `docs/arc/2026/04/011-market-timeframe-vocab/INSCRIPTION.md`.
  Records the leaf-name clarification + round-to-4 add + signum
  inline.
- `docs/rewrite-backlog.md` — Phase 2 gains "2.9 shipped" row.
  The top-of-Phase-2 rule note updates to spell "leaf name"
  explicitly.
- `docs/proposals/.../058-ast-algebra-surface/FOUNDATION-CHANGELOG.md`
  — row documenting arc 011.
- Task #41 marked completed.

---

## Working notes

- Opened 2026-04-23 straight after arc 010.
- Third cross-sub-struct arc. First Ohlcv read. First non-
  round-to-2 rounding in a vocab.
- The leaf-name clarification is a non-substantive rule refinement,
  not a new rule. Arc 008's spirit held; arc 011 just spells out
  the ambiguity arc 008's prose didn't have to resolve.
