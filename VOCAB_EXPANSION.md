# Vocabulary Expansion Plan — Chapter 3

## Goal
Expand from 84 atoms (~120 facts/candle) to 200+ atoms (~300+ facts/candle).
All computable from the existing 48-candle OHLCV window. No DB changes.
Increase dims from 10k to 20k+ to maintain SNR with larger fact count.

## Priority 1: Ichimoku Cloud
Entire trading school. Computable from OHLCV.

New atoms: `tenkan-sen`, `kijun-sen`, `senkou-span-a`, `senkou-span-b`, `chikou-span`, `cloud-top`, `cloud-bottom`

New zone checks: `above-cloud`, `below-cloud`, `in-cloud`

New comparisons: `(close, tenkan-sen)`, `(close, kijun-sen)`, `(close, cloud-top)`, `(close, cloud-bottom)`, `(tenkan-sen, kijun-sen)`

New predicates: `cloud-twist` (senkou-a crosses senkou-b)

Computation (from candle highs/lows):
- tenkan = (highest_high_9 + lowest_low_9) / 2
- kijun = (highest_high_26 + lowest_low_26) / 2
- senkou_a = (tenkan + kijun) / 2  (shifted forward 26, but we use current)
- senkou_b = (highest_high_52 + lowest_low_52) / 2  (shifted forward 26)
- chikou = close (shifted back 26 — compare close[now] to close[26 ago])

Note: need 52 candles for senkou_b. Current window is 48. Either extend window or approximate with 48.

## Priority 2: Stochastic Oscillator
Complements RSI — different momentum view.

New atoms: `stoch-k`, `stoch-d`

Computation (14-period default):
- %K = (close - lowest_low_14) / (highest_high_14 - lowest_low_14) × 100
- %D = SMA(3, %K)

New zones: `stoch-overbought` (>80), `stoch-oversold` (<20)
New comparisons: `(stoch-k, stoch-d)` — crosses are key signals
Add to SEGMENT_STREAMS for PELT analysis.

## Priority 3: Fibonacci Retracement
Levels relative to recent swing high/low.

Uses swing detection (already have PELT peaks/troughs from divergence code).

New atoms: `fib-236`, `fib-382`, `fib-500`, `fib-618`, `fib-786`

Computation:
- Find most recent swing high and swing low from PELT
- fib_level = swing_low + (swing_high - swing_low) × fib_ratio
- Encode close position relative to each fib level

New predicates: `near-fib` (close within ATR of a fib level)

## Priority 4: Volume Analysis

New atoms: `obv-direction`, `volume-sma`

Computation:
- OBV: cumulative sum of ±volume based on close direction
- Volume SMA: simple average of last 20 volumes
- Volume ratio: current volume / volume SMA

New zones: `volume-spike` (ratio > 2.0), `volume-drought` (ratio < 0.5)
New predicates: `obv-diverging` (OBV direction vs price direction)
Add OBV to SEGMENT_STREAMS.

## Priority 5: Keltner Channels + Squeeze

New atoms: `keltner-upper`, `keltner-lower`

Computation:
- keltner_upper = sma20 + 2.0 × ATR
- keltner_lower = sma20 - 2.0 × ATR

Key thought: `squeeze` = BB inside Keltner (low volatility compression).
Already have `bb-upper`, `bb-lower` and can compute keltner from SMA20 + ATR.

## Priority 6: Rate of Change / CCI

New atoms: `roc`, `cci`

Computation:
- ROC = (close - close_N) / close_N × 100 (N=12 default)
- CCI = (typical_price - SMA(typical_price, 20)) / (0.015 × mean_deviation)
- typical_price = (high + low + close) / 3

New zones: `cci-overbought` (>100), `cci-oversold` (<-100)

## Priority 7: Price Action Patterns

New atoms: `consecutive-up`, `consecutive-down`, `inside-bar`, `outside-bar`, `gap-up`, `gap-down`

Computation:
- consecutive: count sequential candles in same direction
- inside bar: high < prev_high AND low > prev_low
- outside bar: high > prev_high AND low < prev_low
- gap: open vs prev_close distance

## Implementation

Each priority is one new `eval_` method in ThoughtEncoder.
Each gets its own commit.
Build and test after each.
Run q99 100k after all are in to measure impact.

Add new atoms to INDICATOR_ATOMS, ZONE_ATOMS, PREDICATE_ATOMS.
Add new comparison pairs to COMPARISON_PAIRS.
Add new streams to SEGMENT_STREAMS where applicable.
