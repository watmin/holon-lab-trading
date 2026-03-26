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

Current best: **56.5% win** (thought-only q95, 3,844 trades, 100k candles Jan–Dec 2019)

---

## Open problems / next experiments

1. **Self-deterministic move_threshold**: hardcoded 0.5% is BTC-specific. For cross-asset use (SPY, Gold, Silver), the label threshold should be derived from observed price action — e.g., `K × ATR` at entry time. ATR is already in the Candle struct. This is how we generalize without tuning.

2. **Self-deterministic flip threshold via calibration curve**: maintain rolling histogram of (conviction bucket → empirical win rate). The flip threshold is wherever win rate first exceeds noise (~51.5%). Removes `flip_quantile` as a hyperparameter. Requires ~500+ resolved trades per recalib to estimate reliably.

3. **Thought vocab: RSI divergence**: `(diverging close rsi)` — price higher high while RSI lower high (bearish), or price lower low while RSI higher low (bullish). The most classic reversal signal, completely absent from current vocab. PELT segment co-occurrence partially captures this but without peak/trough precision.

4. **Thought vocab: candlestick patterns**: pin bars (long wick relative to body), engulfing candles, doji. A trader looks at these immediately. Currently absent — only wick/body ratio comparisons exist, not named pattern predicates.

5. **Thought vocab: volume behavior**: is volume spiking or fading on the current move? "High volume breakout" vs "low volume exhaustion move" are distinct thoughts a trader has. Need to check if volume is in SEGMENT_STREAMS.

6. **Thought vocab: 48-candle high/low as S/R**: "price approaching the recent range high" is a core trader thought. `prev-high`/`prev-low` cover single-candle lookback; we have no fact for "near the 48-candle high/low".

7. **Full dataset run**: validate thought-only q85 (+7.85%, 53.9%) over 652k candles (Jan 2019–Mar 2025).

---

## Archived: trader/trader2 history

See git history and `orchestration_results/` logs. Best result was trader v9 raw cosine: +12.0% peak at 50k candles, +1.9% final at 100k.

trader2 was an abandoned experiment. Left in place, not deleted.
