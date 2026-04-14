# Verification Sequence — Leaves to Root

Exhaustive checklist for proving the enterprise produces honest predictions.
Each layer depends on the layers below it. Verify bottom-up.

## Layer 0: Raw Data
- [x] Trusted. Same parquet produced ~59% accuracy before the streaming refactor.
- [x] The data is not the problem. We introduced regression in the refactor.

## Layer 1: Streaming Indicators (IndicatorBank)
- [x] SMA: warmup returns 0.0, then exact running average (unit tested)
- [x] EMA: SMA seed for first N values (unit tested, ta-lib canonical)
- [x] Wilder smoothing: returns 0.0 during warmup, recursive after (unit tested)
- [x] RSI: 14-period Wilder, [0, 100] range (unit tested)
- [x] MACD: 12/26/9 EMA crossover (unit tested)
- [x] DMI/ADX: two-phase warmup (unit tested)
- [x] ATR: 14-period Wilder (unit tested)
- [x] Stochastic: 14-period %K, 3-period SMA %D (unit tested)
- [x] CCI: 20-period mean deviation (unit tested)
- [x] MFI: 14-period windowed ring buffers (unit tested)
- [x] OBV: cumulative, 12-period slope via linreg (unit tested)
- [x] Bollinger: 20-period, 2-sigma (unit tested)
- [x] Keltner: 20-period EMA, 1.5x ATR (unit tested)
- [x] Ichimoku: 9/26/52-period rolling midpoints (streaming, added 2026-04-02)
- [x] ROC: 1/3/6/12 period rate of change (unit tested)
- [x] Cross-reference against external library: old Python pipeline used bukosabino/ta. Rust unit tests verify ta-lib canonical formulas. Values validated during streaming refactor.
- [x] No NaN/Inf propagation (DB verified: 0 NaN, 0 Inf across 10k candle_snapshot)

## Layer 2: Fact Generation (Vocab Modules)
- [x] All 12 vocab modules wired and called (verified via code audit)
- [x] Truth gates correct: false facts do not propagate (code audit, every `if` verified)
- [x] Zone thresholds match standard definitions (RSI 30/70, Stoch 20/80, etc.)
- [x] Comparison facts use compatible scales (no price-vs-oscillator pairs)
- [x] candle_field() panics on unknown fields (no silent 0.0 fallback except Ichimoku warmup)
- [x] field_value() filters 0.0 as None for non-derived fields (prevents warmup leakage)
- [x] DB cross-verification: zone facts match indicator values at entry time (<2% cosine bleed)
- [x] DB cross-verification: comparison facts match indicator values at entry time (<2% cosine bleed)
- [x] ROC acceleration/deceleration: normalized per-candle rates, majority vote (fixed 2026-04-02)
- [x] Ichimoku comparison pairs alive in COMPARISON_PAIRS (fixed 2026-04-02)
- [x] Fact count stable across regimes: 53-54 facts/entry, min 39 max 68, no collapse (DB verified)
- [x] No duplicate facts per entry (DB verified: zero duplicates across 444k rows)

## Layer 3: Thought Encoding (ThoughtEncoder)
- [x] Lens routing correct: each observer gets only its vocab subset (code audit)
- [x] Generalist = union of all specialist lenses (code audit)
- [x] Fact cache pre-computes all zone/comparison vectors at startup (code audit)
- [x] Scalar encoding uses correct ScalarMode (Linear with scale=1.0 for all)
- [x] Thought vector is non-zero after encoding (unit tested)
- [x] Thought vectors differ between consecutive candle windows (unit tested, cosine < 0.999)
- [x] Thought vectors differ between lenses: momentum != structure != volume (unit tested)
- [x] Uptrend vs downtrend produce meaningfully different thoughts (unit tested, cosine < 0.9)

## Layer 4: Observer Journals (Prediction)
- [ ] Each observer's journal accumulates labeled observations
- [ ] Buy/Sell label assignment matches actual price direction at threshold crossing
- [ ] Discriminant direction changes over time (not stuck)
- [ ] disc_strength > 0 after sufficient observations (currently ~0.003 — investigate)
- [ ] Conviction values span a range (not all identical)
- [ ] Recalibration fires at expected intervals
- [ ] Per-observer accuracy differs (specialists see different things)

## Layer 5: Manager (Panel Composition)
- [ ] Manager encodes observer opinions, not candle data (boundary verified by code)
- [ ] Manager labels = raw price direction (Buy if up, Sell if down)
- [ ] Manager learns from same thought it predicted with (one encoding path)
- [ ] Proven band scan finds bands with real signal (band accuracy > 51%)
- [ ] Manager conviction correlates with outcome (the curve exists)
- [ ] Panel shape facts fire when 2+ observers are proven

## Layer 6: Position Lifecycle
- [ ] Positions open only when: manager_curve_valid, in_proven_band, risk_allows, market_moved
- [ ] Position sizing is proportional to conviction and risk_mult
- [ ] Stop loss triggers at k_stop * entry_atr
- [ ] Take profit triggers at k_tp * entry_atr
- [ ] Trailing stop follows price correctly
- [ ] Settlement: swap target->source at exit, release deployed, update treasury
- [ ] No double-counting: pending entries are for learning, positions for capital

## Layer 7: Treasury Accounting
- [x] Equity = sum(balance + deployed) * prices for all assets (DB verified)
- [ ] Every swap: source decreases, target increases, fees deducted
- [ ] No asset creation or destruction (conservation law)
- [ ] Position open/close round-trips preserve capital minus fees
- [ ] Deployed amounts release correctly on exit

## Layer 8: Risk Assessment
- [ ] Risk branches encode portfolio state, not market data (boundary check)
- [ ] Healthy gate: only learns from genuinely healthy states
- [ ] Risk multiplier [0.1, 1.0] — never amplifies, only constrains
- [ ] Risk manager journal learns Healthy/Unhealthy correctly

## Diagnostic Infrastructure
- [x] candle_snapshot: all 65 indicator fields logged per entry candle
- [x] trade_facts: thought vector decoded against codebook per resolved entry
- [x] trade_ledger: full P&L accounting per resolved entry
- [x] disc_decode: top 20 discriminant facts per recalibration
- [x] observer_log: per-observer predictions at threshold crossing
- [x] risk_log: portfolio state at each live trade
- [x] recalib_log: disc_strength trajectory over time

## Key Diagnostic Queries

```sql
-- Fact-indicator cross-verification (zone facts)
SELECT tf.fact_label, SUM(CASE WHEN [violation_condition] THEN 1 ELSE 0 END) as violations, COUNT(*) as total
FROM trade_facts tf
JOIN trade_ledger tl ON tl.step = tf.step
JOIN candle_snapshot cs ON cs.candle_idx = tl.candle_idx
WHERE tf.fact_label = '[fact]'

-- Win rate by conviction band
SELECT CAST(conviction*10 AS INT)/10.0 as band, COUNT(*), SUM(won), ROUND(AVG(won)*100,1)
FROM trade_ledger WHERE outcome != 'Noise' AND exit_reason = 'HorizonExpiry'
GROUP BY band ORDER BY band

-- Fact predictiveness
SELECT tf.fact_label, SUM(CASE WHEN tl.won=1 THEN 1 ELSE 0 END) as wins, COUNT(*) as total,
       ROUND(AVG(tl.won)*100,1) as win_pct
FROM trade_facts tf JOIN trade_ledger tl ON tl.step = tl.step
WHERE tl.outcome != 'Noise'
GROUP BY tf.fact_label HAVING total >= 100
ORDER BY win_pct DESC

-- disc_strength trajectory
SELECT step, disc_strength FROM recalib_log WHERE journal='thought' ORDER BY step

-- Equity conservation check
SELECT cs.candle_idx,
       ROUND(cl.equity,2) as logged_equity,
       ROUND(cs.close * (cl.wbtc_bal + cl.wbtc_deployed) + cl.usdc_bal + cl.usdc_deployed, 2) as computed
FROM candle_log cl JOIN candle_snapshot cs ON cs.candle_idx = cl.candle_idx
WHERE ABS(cl.equity - (cs.close * (cl.wbtc_bal + cl.wbtc_deployed) + cl.usdc_bal + cl.usdc_deployed)) > 1.0
```

## Status

Last verified: 2026-04-02, 10k candle run (diag-entry-snap.db)
- Layers 1-2: HIGH confidence (unit tests + DB cross-verification)
- Layers 3-5: MEDIUM confidence (code audit, not yet DB-verified)
- Layers 6-8: LOW confidence (basic unit tests, needs live verification)
