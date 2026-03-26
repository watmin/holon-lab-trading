# Next Moves — Holon BTC Trader

## Current Architecture (2026-03-26)

**Active binary: trader3** (`rust/src/bin/trader3.rs`)
Two named journals — `visual` and `thought` — each independently predict market direction.
Orchestration layer (`meta-boost` default) combines their signals.

Visual journal: encodes the 48-candle OHLCV raster grid.
Thought journal: encodes the PELT segment narrative.
Both use `journal::Journal` — the same struct, different input vectors.

### How prediction works

Each journal maintains two accumulators (`buy`, `sell`). Every 500 observations it computes a *discriminant*: `normalize(buy_proto − sell_proto)`. Prediction is one cosine against the discriminant. Positive = Buy, negative = Sell, magnitude = conviction.

**Input stripping (S1, live):** at recalibration, `mean_proto = (buy_f + sell_f) / 2` is cached. At prediction time, `mean_proto` is subtracted from the input in float space before computing the cosine. This strips ~90% shared candle structure, leaving only directional deviation.

**Conviction flip (live):** the system identifies trend extremes at high conviction — these empirically precede reversals, not continuations. When `meta_conviction >= flip_threshold`, the prediction direction is flipped (contrarian). `flip_threshold` is the 85th percentile of recent meta_conviction values, computed from a 50k-candle rolling window (≈100 discriminant recalibrations). No magic number.

**Flip-zone-only trading (live):** trades are only taken when `meta_conviction >= flip_threshold`. Below that threshold, accuracy is ~49–50% (noise). Only the reliable reversal signal zone is traded.

**Conviction-scaled sizing (live):** position size scales as `base × (conviction / flip_threshold)`, capped at 5%. Stronger reversal signal = larger bet.

### What the DB tells you

```sql
-- Accuracy vs conviction (should be positive in the flip zone)
SELECT ROUND(meta_conviction, 2) AS conv, COUNT(*) AS n,
       ROUND(AVG(CASE WHEN meta_pred = actual THEN 1.0 ELSE 0.0 END) * 100, 1) AS acc
FROM candle_log WHERE actual != 'Noise' AND meta_pred IS NOT NULL AND traded = 1
GROUP BY conv ORDER BY conv DESC;

-- Epoch-by-epoch P&L
SELECT ROUND(step / 10000.0) * 10000 AS epoch, SUM(traded) AS trades,
       ROUND(AVG(CASE WHEN meta_pred = actual AND traded=1 THEN 1.0
                      WHEN traded=1 THEN 0.0 ELSE NULL END) * 100, 1) AS win_pct,
       ROUND(MAX(equity), 2) AS equity
FROM candle_log WHERE actual != 'Noise' AND meta_pred IS NOT NULL
GROUP BY epoch ORDER BY epoch;

-- Flip threshold stability (from log)
-- grep "flip@" orchestration_results/<name>.log

-- Journal health
SELECT step, journal, ROUND(cos_raw, 4), ROUND(disc_strength, 4), buy_count, sell_count
FROM recalib_log ORDER BY step;
```

---

## Run History (trader3)

| Date | Candles | Name | Equity | Win | Trades | Notes |
|------|---------|------|--------|-----|--------|-------|
| 2026-03-26 | 2k | smoke | +1.15% | — | — | Smoke test. Confirmed 300+/s. |
| 2026-03-26 | 100k | fix-100k | -6.92% | 49.1% | 66,575 | P&L bug fixed baseline. No flip. |
| 2026-03-26 | 100k | flip-07 | -0.11% | 50.4% | 66,575 | Fixed flip threshold 0.07. |
| 2026-03-26 | 100k | stable-q85 | +0.97% | 50.3% | 66,575 | 50k-window quantile flip. Still trading noise. |
| 2026-03-26 | 100k | flipzone-only | +5.49% | 53.6% | 10,539 | Flip zone only + conviction sizing. meta-boost. |
| 2026-03-26 | 100k | t3-visual-only | -0.39% | 50.5% | 9,571 | visual-only. flip@0.051. |
| 2026-03-26 | 100k | t3-thought-only | +7.85% | **53.9%** | 11,019 | thought-only q85. flip@0.133. Best P&L. |
| 2026-03-26 | 100k | agree-only-100k | +5.49% | 53.4% | 10,448 | agree-only q85. Matched meta-boost, not better. |
| 2026-03-26 | 100k | thought-q95-100k | +3.32% | **56.5%** | 3,844 | thought-only q95. Best win rate so far. |

---

## What was learned this session

**P&L bug (fixed):** `record_trade` was using `peak_abs_pct` (always positive) with the prediction direction — every Buy prediction was a win, every Sell a loss. Fixed to use `outcome_pct` (signed price return at first threshold crossing).

**Conviction inversion (understood):** The visual and thought encodings capture the *current state* of the market trend — what the recent price history looks like. High conviction = the model sees a very strong established trend. At the 36-candle horizon, strong trends are exhausted and reversal follows. The discriminant learned to recognize trend extremes; the fix is to predict the opposite direction at high conviction.

**The fix that worked:**
1. Flip prediction direction when `meta_conviction >= flip_threshold`
2. Only trade in the flip zone (skip low-conviction noise entirely)
3. Scale position by conviction relative to flip_threshold
4. Derive flip_threshold from the 85th percentile of a 50k-candle rolling conviction window — no magic number

---

## Primary goal: win rate > 60%

**P&L returns are secondary.** The current paper trading P&L calc is a rough proxy — position sizing is simplistic and not the focus. We are chasing **prediction accuracy** (win rate). >60% sustained over 100k candles would exceed published ML trading benchmarks.

Current best: **57.1% win** (thought-only q95, vocab v3, 3,857 trades, 100k candles Jan–Dec 2019)

---

## Run History — Session 2 (2026-03-26)

| Candles | Name | Win | Equity | Trades | Notes |
|---------|------|-----|--------|--------|-------|
| 100k | thought-vocab-v2-100k | 53.8% | +8.17% | 11,203 | vocab v2, q85. Best P&L balanced. |
| 100k | thought-vocab-v2-q95-100k | 56.9% | +4.17% | 3,853 | vocab v2, q95. |
| 100k | thought-vocab-v3-q95-100k | **57.1%** | +4.39% | 3,857 | PELT divergence, q95. Best win rate. |
| 100k | auto-flip-v4-100k | 51.5% | **+17.61%** | 19,159 | auto flip min_edge=0.55. Best P&L. |
| 100k | thought-vocab-v4-q95-100k | 56.7% | +4.18% | 3,877 | + wick PELT streams, q95. |

---

## Open problems / next experiments

### Implemented, needs isolated testing

1. **ATR-based move_threshold** (`--atr-multiplier K`): Implemented. Replaces fixed 0.5% with `K × atr_r` per candle. Asset-independent. K≈3.0 approximates current 0.5% for BTC. **Not yet tested in isolation** — combined run (ATR + auto flip) regressed because both changed at once. Next step: ATR-only with proven q95 quantile.

2. **Kelly position sizing** (`--sizing kelly`): Implemented. Half-Kelly from calibration curve. Self-gates (no trade when Kelly ≤ 0). Not yet tested — P&L metric is secondary for now.

3. **thought-visual-amp orchestration**: Implemented. Visual conviction magnitude amplifies thought conviction: `meta_conviction = tht × (1 + vis)`. Visual strength confirms trend clarity regardless of direction. DB simulation showed 67.7% at amp≥0.20 (319 trades from 30k candles). q95 run showed no improvement (quantile adapts to shifted distribution). **Testing with auto flip mode** (edge-based threshold should benefit from amplification).

### Self-derived min_edge — needs rework

The `0.50 + 2σ(window_win_rates)` approach to self-derive min_edge has three issues:

**Cold start contamination**: Trades taken before flip activates but resolved after were polluting the window. Partially fixed with `was_flipped` flag on Pending struct — only trades that were actually flipped at entry time get tracked. **Status: flag implemented, not yet validated.**

**Small sample variance**: 20 trades per window is too few. Win rate of 20 trades has ±20pp noise → inflated stddev → derived min_edge of 0.75-0.93 (absurd). **Fix: require ≥100 trades per window.**

**Insufficient windows**: 5 windows of noisy data → unstable stddev. **Fix: require ≥10 windows (1000+ flipped trades) before self-derivation kicks in. Until then, use seeded min_edge.**

The overall fix: `if flipped_trade_count < 1000 { use args.min_edge } else { self-derive }`. The system needs enough flip-zone trading history before it can measure its own prediction stability. **Currently disabled in code** — using fixed `args.min_edge` until these fixes are validated.

### Thought vocab

4. **Candlestick patterns**: designed as emergent (comparison predicate co-occurrence). Doji, hammer, engulfing, pin bar facts all co-occur from existing comparisons. The discriminant should discover these without named atoms. **Status: believed to be working via emergence, not validated.**

5. **Momentum deceleration**: price still rising but rate slowing. PELT captures direction but not second derivative. Could add a `momentum` SEGMENT_STREAM: rate of change of close over rolling window.

6. **Candle compression**: recent candles getting smaller. PELT on `body` and `range` streams captures this (added). PELT on `upper-wick` and `lower-wick` streams also added (vocab v4). Not yet showing clear win rate improvement.

### Validation

7. **Full dataset run**: validate best result over 652k candles (Jan 2019–Mar 2025).
8. **Cross-asset**: test on Gold/Silver with `--atr-multiplier`. Calendar facts may need session-aware adjustments for equity markets.

---

## Archived: trader/trader2 history

See git history and `orchestration_results/` logs. Best result was trader v9 raw cosine: +12.0% peak at 50k candles, +1.9% final at 100k.

trader2 was an abandoned experiment. Left in place, not deleted.
