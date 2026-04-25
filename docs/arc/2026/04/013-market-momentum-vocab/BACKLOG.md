# Lab arc 013 — market/momentum vocab — BACKLOG

**Shape:** three slices. Zero substrate gaps (round-to-4 already
shipped in arc 011; plain Log already shipped in wat-rs).

---

## Slice 1 — vocab module

**Status: ready.**

New file `wat/vocab/market/momentum.wat`:
- Loads candle.wat + ohlcv.wat + round.wat + scale-tracker.wat +
  scaled-linear.wat.
- Defines `:trading::vocab::market::momentum::encode-momentum-holons`
  with signature `(m :Candle::Momentum) (o :Ohlcv) (t :Candle::Trend)
  (v :Candle::Volatility) (scales :Scales) -> :VocabEmission`.
  Leaf-alphabetical: M < O < T < V.
- Five scaled-linear calls threading scales (close-sma20/50/200,
  macd-hist, di-spread).
- One Bind-emit-directly atom (atr-ratio) using
  `(:wat::holon::Log atr-ratio-rounded 0.001 0.5)`.

Compute pattern (recurs four times, shape-uniform):
```scheme
((close :f64) (:Ohlcv/close o))
((sma20 :f64) (:Candle::Trend/sma20 t))
((close-sma20 :f64)
  (:trading::encoding::round-to-4
    (:wat::core::f64::/
      (:wat::core::f64::- close sma20) close)))
```

Inline per stdlib-as-blueprint — the arithmetic is two ops, the
let-binding chain is the locally-honest form.

Wiring: `wat/main.wat` gains a load line for `vocab/market/momentum.wat`.

**Sub-fogs:**
- **1a — atr-ratio floor + round order.** Match arc 010 regime:
  floor first (`if v >= 0.001 then v else 0.001`), then round-to-4.
  round-to-4 of 0.001 is 0.001 (preserves the positive-input
  guarantee). round-to-2 would collapse 0.001 to 0.00 and break
  Log; arc 013 DESIGN explains the round-to-4 choice.
- **1b — Log primitive arity.** `(Log value min max)` per
  `wat-rs/wat/holon/Log.wat`. Three positional args.

## Slice 2 — tests

**Status: obvious in shape** (once slice 1 lands).

New file `wat-tests/vocab/market/momentum.wat`. Six tests:

1. **count** — 6 holons.
2. **close-sma20 shape** — fact[0], cross-sub-struct compute
   `(close - sma20) / close` round-to-4 via Thermometer.
3. **macd-hist shape** — fact[3], cross-sub-struct compute
   `macd-hist / close` round-to-4 (different cross-pair than
   close-sma*).
4. **di-spread shape** — fact[4], single-sub-struct compute via
   `(plus-di - minus-di) / 100.0` round-to-2. Verifies pure-
   Momentum atoms still work alongside cross-compute atoms.
5. **atr-ratio plain-Log shape** — fact[5], `Log` form (not
   ReciprocalLog), bounds (0.001, 0.5), value floored + round-to-4.
6. **scales accumulate 5 entries** — five scaled-linear atoms
   land; atr-ratio's plain Log doesn't touch Scales.
7. **different candles differ** — fact[0] across the scale-
   collision boundary (arc 008 footnote).

Helpers in default-prelude:
- `fresh-ohlcv` — close-controllable, other Ohlcv fields defaulted.
- `fresh-trend` — sma20-controllable, other Trend fields zeroed.
- `fresh-momentum` — macd-hist + plus-di + minus-di controllable.
- `fresh-volatility` — atr-ratio controllable.
- `empty-scales` — fresh HashMap.

Seven tests because plain-Log shape merits its own assertion (not
just a different bound on a known shape — it's the first lab Log
caller). Same coverage strategy as arc 010 regime's variance-
ratio test.

**Sub-fogs:**
- **2a — Trend constructor arity.** 7 positional args (sma20,
  sma50, sma200, tenkan-sen, kijun-sen, cloud-top, cloud-bottom)
  per candle.wat. Helper sets sma20; zeros the rest.
- **2b — Momentum constructor arity.** 12 positional args (rsi,
  macd-hist, plus-di, minus-di, adx, stoch-k, stoch-d,
  williams-r, cci, mfi, obv-slope-12, volume-accel). Helper sets
  macd-hist + plus-di + minus-di; zeros nine others.
- **2c — Volatility constructor arity.** 7 positional args
  (bb-width, bb-pos, kelt-upper, kelt-lower, kelt-pos, squeeze,
  atr-ratio). Helper sets atr-ratio; zeros six others.

## Slice 3 — INSCRIPTION + doc sweep

**Status: obvious in shape** (once slices 1 – 2 land).

- `docs/arc/2026/04/013-market-momentum-vocab/INSCRIPTION.md`.
  Records the K=4 first-ship, the plain-Log first-caller, the
  round-to-4 substrate-discipline correction, the cross-compute
  pattern recurrence (and the deferred helper-extraction question).
- `docs/rewrite-backlog.md` — Phase 2 gains "2.10 shipped" row.
  Top-of-Phase-2 rule note already accurate (leaf-name from arc 011).
- `docs/proposals/2026/04/058-ast-algebra-surface/FOUNDATION-CHANGELOG.md`
  — row documenting arc 013 + the three durables (K=4 first-ship,
  plain-Log first lab caller, round-to-4 substrate-discipline).
- Task #42 marked completed.
- Lab repo commit + push.

---

## Working notes

- Opened 2026-04-24 the morning after the wat-rs known-good marker
  ship. Lab work resumes per `docs/rewrite-backlog.md` plan;
  momentum is task #42.
- Fourth cross-sub-struct arc, highest arity yet (K=4). The
  alphabetical-by-leaf rule from arc 011 holds without
  re-derivation.
- The plain-Log decision is the arc's main design call; the rest
  is mechanical port. DESIGN explains the ReciprocalLog vs Log
  trade-off explicitly so future Log-encoded atoms have a written
  precedent to cite.
- round-to-4 for atr-ratio is a substrate-discipline correction,
  not an archive-faithful port. The archive's round-to-2 worked
  under its naked-Log primitive; wat-rs's Log requires positive
  inputs, so round-to-4 preserves the floor.
