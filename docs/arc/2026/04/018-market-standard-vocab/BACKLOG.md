# Lab arc 018 — market/standard vocab — BACKLOG

**Shape:** three slices. Substrate-direct port consuming arc 046
+ arc 047's full set of new primitives. First window-based
vocab; first lab consumer of all four arc-047 primitives.

---

## Slice 1 — vocab module

**Status: ready** (arc 046 + 047 substrate landed).

New file `wat/vocab/market/standard.wat`:
- Loads candle.wat + ohlcv.wat + round.wat + scale-tracker.wat +
  scaled-linear.wat. (No shared/helpers.wat.)
- Defines `:trading::vocab::market::standard::encode-standard-holons`
  with signature `(window :Vec<Candle>) (scales :Scales) -> :VocabEmission`.
  **First window-based vocab signature** — Vec<Candle> input,
  not sub-struct slices. Departs from arc 008's K-sub-struct rule
  by necessity (window aggregates need full candles).
- Empty-window guard at the top via `:wat::core::empty?` →
  return `(tuple empty-vec scales)`.

Non-empty branch:
- `current = (last window)` — match-extract from Option.
- Window aggregates via `f64::max-of` + `f64::min-of` over
  `(map window high)` and `(map window low)`.
- Three find-last-index calls — RSI extreme (rsi > 80 or < 20),
  vol spike (volume-accel > 2), large move (|roc-1| > 0.02).
  Each returns `Option<i64>`; convert to `since-X = n - i` (or
  `n` for None case = no match in window).
- Four distance atoms — `(price - X) / price` for X in
  {window-high, window-low, window-mid, sma200}, round-to-4 →
  scaled-linear.
- Four Log atoms — three since-X + session-depth, all in the
  count-starting-at-1 family with bounds `(1.0, 100.0)`.

Wiring: `wat/main.wat` gains a load line.

**Sub-fogs:**
- **1a — i64 arithmetic for indices.** Substrate has `i64::+/-`
  per existing arith primitives. `n - i` is straightforward.
- **1b — i64::to-f64 for Log input.** `since-X` is i64, Log
  takes f64. Use `:wat::core::i64::to-f64` for the conversion.
- **1c — Roc-1 access.** `roc-1` lives in `Candle::RateOfChange`
  per candle.wat. `(:Candle::RateOfChange/roc-1 (:Candle/roc c))`.

## Slice 2 — tests

**Status: obvious in shape** (once slice 1 lands).

New file `wat-tests/vocab/market/standard.wat`. Eight tests:

1. **count for non-empty window** — 8 holons.
2. **empty window emits zero holons** — empty-window guard.
3. **since-rsi-extreme finds extreme** — 2-candle window, first
   has RSI=85 (extreme), second normal. `since = n - 0 = 2`.
4. **since-rsi-extreme defaults when no extreme** — window with
   all normal RSI values. None case → `since = n`.
5. **window-high computed** — multi-candle window with varying
   highs; assert `window-high = max(highs)`.
6. **dist-from-high shape** — fact at known position, value
   `(price - window-high) / price` round-to-4.
7. **session-depth Log shape** — fact, count family bounds.
8. **scales accumulate 4 entries** — four scaled-linear; four
   Log atoms don't touch.

Helpers in default-prelude:
- `fresh-candle` — full Candle constructor with controllable
  ohlcv (open/high/low/close), trend (sma200), momentum (rsi,
  volume-accel), and roc (roc-1) fields. Other sub-structs zeroed.
- `empty-scales`.

**Sub-fogs:**
- **2a — Candle constructor arity.** 12-arg per candle.wat
  (ohlcv, trend, volatility, momentum, divergence, roc,
  persistence, regime, price-action, timeframe, time, phase).
  Helper takes the relevant fields, defaults the rest.
- **2b — Phase field default.** Candle::Phase has `label`,
  `direction`, `duration`, `history` (Vec<PhaseRecord>). Default
  to enum-zero values.

## Slice 3 — INSCRIPTION + doc sweep

**Status: obvious in shape** (once slices 1 – 2 land).

- `docs/arc/2026/04/018-market-standard-vocab/INSCRIPTION.md`.
  Records: window-vocab signature departure from K-sub-struct
  rule; consumes all four arc-047 primitives; closes
  `compute-atom` helper question; market sub-tree completes
  (13 of 13 vocabs!).
- `docs/rewrite-backlog.md` — Phase 2 gains "2.15 shipped" row.
  **Market sub-tree complete** — annotation update.
- `docs/proposals/2026/04/058-ast-algebra-surface/FOUNDATION-CHANGELOG.md`
  — row documenting arc 018.
- Task #43 marked completed.
- Lab repo commit + push.

---

## Working notes

- Opened 2026-04-24 after arcs 046 + 047 (the substrate uplifts
  this arc surfaced and consumes).
- Triple-nested arc dependency: arc 047 surfaced from arc 018
  sketch → arc 047 ships → arc 018 can write naturally → arc
  018 ships using arc 047. The natural-form-then-promote rhythm
  in action.
- Last market vocab. After this arc, the trading-lab market
  sub-tree is complete; only exit/* (#44, #45) and
  BLOCKED-on-PaperEntry (#46, #47) remain.
