# Vocab Gap Analysis

Comparison of vocab facts across three snapshots:
- **Inscription 9** (current): `wat/vocab/` — the living specification
- **Inscription 5** (archived): `archived/wat-archived-inscription-5/vocab/`
- **Pre-007 Rust** (archived): `archived/src-archived-pre007-desk/vocab/` — the last working Rust code before the wat rewrite

Only `Fact::Scalar` entries from pre-007 Rust are tracked (per instructions). `Fact::Zone`, `Fact::Bare`, and `Fact::Comparison` are excluded from the Rust comparison.

---

## Module: divergence

### In inscription 5, missing from inscription 9:
- divergence-bull (Linear) — bullish RSI divergence magnitude as linear scalar
- divergence-bear (Linear) — bearish RSI divergence magnitude as linear scalar
- divergence-spread (Linear) — bullish minus bearish divergence, signed spread

Inscription 9 changed encoding: uses conditional Log atoms (`rsi-divergence-bull`, `rsi-divergence-bear`) that only fire when magnitude > 0. The spread fact was dropped entirely.

### In pre-007 Rust (scalars only), missing from inscription 9:
No Fact::Scalar entries in pre-007 divergence.rs (it returned `Divergence` structs, not `Fact`s).

---

## Module: fibonacci

### In inscription 5, missing from inscription 9:
- fib-dist-236 (Linear) — signed distance from 48-period range pos to 0.236 level
- fib-dist-382 (Linear) — signed distance from 48-period range pos to 0.382 level
- fib-dist-500 (Linear) — signed distance from 48-period range pos to 0.500 level
- fib-dist-618 (Linear) — signed distance from 48-period range pos to 0.618 level
- fib-dist-786 (Linear) — signed distance from 48-period range pos to 0.786 level

Inscription 9 replaced the five per-level distance facts with a single nearest-level distance computed inline (`fib-distance-12`, `fib-distance-24`, `fib-distance-48`). The per-level granularity was lost.

Also, atom names changed: `fib-range-pos-12/24/48` became `range-pos-12/24/48`.

### In pre-007 Rust (scalars only), missing from inscription 9:
No Fact::Scalar entries in pre-007 fibonacci.rs (it used Fact::Comparison only: "touches", "above", "below" fib levels).

---

## Module: flow

### In inscription 5, missing from inscription 9:
- obv-slope-12 (Linear) — OBV slope as linear with scale 1.0 (inscription 9 uses `obv-slope` with scale 1.0 but different name)
- buying-pressure (Linear) — (close - low) / (high - low), computed inline
- mfi-flow (Linear) — MFI as a flow indicator normalized to [0, 1]

Inscription 9 dropped `buying-pressure` entirely. `mfi-flow` was collapsed into a simpler `mfi` fact. `obv-slope-12` was renamed to `obv-slope`.

### In pre-007 Rust (scalars only), missing from inscription 9:
- vwap (Scalar) — VWAP distance, clamped and rescaled to [0, 1]
- buy-pressure (Scalar) — buying pressure from wick ratio (close-low)/range
- sell-pressure (Scalar) — selling pressure from wick ratio (high-body_top)/range
- body-ratio (Scalar) — body size as fraction of range

---

## Module: ichimoku

### In inscription 5, missing from inscription 9:
- ichimoku-cloud-top-dist (Linear) — signed distance from close to cloud top as fraction of price
- ichimoku-cloud-bottom-dist (Linear) — signed distance from close to cloud bottom as fraction of price
- ichimoku-cloud-thickness (Log) — cloud width relative to price
- ichimoku-tk-cross-delta (Linear) — signed change in tenkan-kijun spread
- ichimoku-tenkan-dist (Linear) — signed distance from close to tenkan-sen
- ichimoku-kijun-dist (Linear) — signed distance from close to kijun-sen

Inscription 9 replaced these six facts with four differently-named facts (`cloud-position`, `cloud-thickness`, `tk-cross-delta`, `tk-spread`). Lost: separate top/bottom cloud distances (merged into single `cloud-position`), tenkan distance, kijun distance.

### In pre-007 Rust (scalars only), missing from inscription 9:
No Fact::Scalar entries in pre-007 ichimoku.rs (it used Zone and Comparison only).

---

## Module: keltner

### In inscription 5, missing from inscription 9:
- kelt-upper-dist (Linear) — signed distance from close to Keltner upper band as fraction of price
- kelt-lower-dist (Linear) — signed distance from close to Keltner lower band as fraction of price
- bb-inside-pos (Linear) — BB position emitted conditionally when inside bands
- bb-breakout-upper (Log) — conditional breakout above upper BB, distance as fraction of price
- bb-breakout-lower (Log) — conditional breakout below lower BB, distance as fraction of price

Inscription 9 dropped `kelt-upper-dist` and `kelt-lower-dist` entirely. The conditional breakout/inside logic changed: inscription 5 computed distance from price as fraction of close, inscription 9 uses `(bb-pos - 1.0)` or `abs(bb-pos)`.

### In pre-007 Rust (scalars only), missing from inscription 9:
- kelt-pos (Scalar) — Keltner position clamped to [0, 1]
- bb-pos (Scalar) — Bollinger position clamped to [0, 1]

These exist in inscription 9 but the pre-007 Rust clamped them to [0, 1] while inscription 9 allows unclamped values.

---

## Module: momentum

### In inscription 5, missing from inscription 9:
- atr-ratio (Log) — ATR relative to price, as a Log scalar in the momentum module

Inscription 9 dropped `atr-ratio` from the momentum module. It only exists in the exit/volatility module now.

### In pre-007 Rust (scalars only), missing from inscription 9:
No Fact::Scalar in pre-007 momentum.rs (it used Zone only for CCI zones).

---

## Module: oscillators

### In inscription 5, missing from inscription 9:
- rsi-divergence-bull (Linear) — RSI divergence bullish magnitude (was in oscillators, moved to divergence module in inscription 9)
- rsi-divergence-bear (Linear) — RSI divergence bearish magnitude (was in oscillators, moved to divergence module)

Also encoding differences: inscription 5 used Log encoding for ROC (`roc-1` through `roc-12`) with `(+ 1.0 roc)` transformation; inscription 9 uses Linear encoding with scale 0.1.

### In pre-007 Rust (scalars only), missing from inscription 9:
- williams-r (Scalar) — Williams %R normalized to [0, 1] via `(wr + 100) / 100`
- stoch-rsi (Scalar) — Stochastic %K used as RSI-like oscillator, normalized to [0, 1]

Note: `williams-r` exists in inscription 9 but the pre-007 normalization `(wr + 100)/100` differs from inscription 9's raw `(:williams-r c)` pass-through. `stoch-rsi` was a separate fact from `stoch-k` in pre-007; inscription 9 has no `stoch-rsi` equivalent.

---

## Module: persistence

### In inscription 5, missing from inscription 9:
- trend-consistency-6 (Linear) — fraction of recent candles closing in same direction, 6-period
- trend-consistency-12 (Linear) — same, 12-period
- trend-consistency-24 (Linear) — same, 24-period

These three facts were in persistence in inscription 5 but moved to exit/structure in inscription 9. They no longer exist in any market module.

### In pre-007 Rust (scalars only), missing from inscription 9:
- hurst (Scalar) — Hurst exponent, computed from raw candles via R/S analysis (not a pre-computed field)
- autocorr (Scalar) — lag-1 autocorrelation, rescaled to [0, 1] via `v * 0.5 + 0.5`

Both exist in inscription 9 but the pre-007 Rust computed them from raw candle windows (not pre-computed fields). The `autocorr` rescaling `* 0.5 + 0.5` is not in inscription 9 (it uses raw signed values).

---

## Module: price-action

### In inscription 5, missing from inscription 9:
- pa-body-ratio (Linear) — |close - open| / (high - low), body as fraction of range
- pa-upper-wick (Linear) — (high - max(open, close)) / range, upper shadow ratio
- pa-lower-wick (Linear) — (min(open, close) - low) / range, lower shadow ratio

Inscription 9 dropped all three candlestick anatomy facts. Only `range-ratio`, `gap`, `consecutive-up`, `consecutive-down` survive.

Also, all atom names lost the `pa-` prefix: `pa-range-ratio` -> `range-ratio`, `pa-gap` -> `gap`, etc. And scale changed: `pa-consecutive-up/down` used scale 20.0 in inscription 5, inscription 9 uses 10.0.

### In pre-007 Rust (scalars only), missing from inscription 9:
No Fact::Scalar entries in pre-007 price_action.rs (it used Zone only).

---

## Module: regime

### In inscription 5, missing from inscription 9:
No facts lost between inscription 5 and inscription 9 for regime. Same eight facts with minor name changes:
- `regime-kama-er` -> `kama-er`
- `regime-choppiness` -> `choppiness`
- `regime-dfa-alpha` -> `dfa-alpha`
- `regime-variance-ratio` -> `variance-ratio` (also changed from Log to Linear encoding)
- `regime-entropy-rate` -> `entropy-rate` (scale changed from 3.0 to 2.0)
- `regime-aroon-up` -> `aroon-up`
- `regime-aroon-down` -> `aroon-down`
- `regime-fractal-dim` -> `fractal-dim`

### In pre-007 Rust (scalars only), missing from inscription 9:
- trend-consistency-6 (Scalar) — fraction of recent candles in same direction
- trend-consistency-12 (Scalar) — same, 12-period
- trend-consistency-24 (Scalar) — same, 24-period
- atr-roc-6 (Scalar) — ATR rate of change, 6-period, rescaled to [0, 1]
- atr-roc-12 (Scalar) — ATR rate of change, 12-period, rescaled to [0, 1]
- range-pos-12 (Scalar) — price position in 12-period range [0, 1]
- range-pos-24 (Scalar) — price position in 24-period range [0, 1]
- range-pos-48 (Scalar) — price position in 48-period range [0, 1]

Note: `trend-consistency` facts moved to exit/structure in inscription 9. `atr-roc` facts moved to exit/volatility. `range-pos` facts moved to fibonacci. All exist somewhere in inscription 9 but were removed from the regime module.

---

## Module: stochastic

### In inscription 5, missing from inscription 9:
No facts lost. Same four facts with minor encoding differences (inscription 5 normalized by 100, inscription 9 assumes pre-normalized values).

### In pre-007 Rust (scalars only), missing from inscription 9:
No Fact::Scalar entries in pre-007 stochastic.rs (it used Comparison and Zone only).

---

## Module: timeframe

### In inscription 5, missing from inscription 9:
- tf-5m-1h-align (Linear) — signed product of 5m direction and 1h direction, inter-timeframe alignment signal

Inscription 9 dropped this computed alignment fact. The `tf-agreement` fact remains but it's a different thing (pre-computed field, not a directional product).

Also, scale differences: inscription 5 used `tf-1h-ret` scale 0.1, inscription 9 uses 0.05; inscription 5 used `tf-4h-ret` scale 0.1, inscription 9 uses 0.05.

### In pre-007 Rust (scalars only), missing from inscription 9:
- tf-1h-body (Scalar) — 1h body ratio, clamped [0, 1]
- tf-4h-body (Scalar) — 4h body ratio, clamped [0, 1]
- tf-1h-range-pos (Scalar) — close position in 1h range, clamped [0, 1]
- tf-4h-range-pos (Scalar) — close position in 4h range, clamped [0, 1]
- tf-1h-ret (Scalar) — 1h return, clamped and rescaled to [0, 1]
- tf-4h-ret (Scalar) — 4h return, clamped and rescaled to [0, 1]

These all exist in inscription 9, but the pre-007 Rust clamped and rescaled everything to [0, 1] which inscription 9 does not.

---

## Module: exit/structure

### In inscription 5, missing from inscription 9:
- exit-kama-er (Linear) — KAMA efficiency ratio for exit context

Inscription 9 dropped this fact from exit/structure. All other exit-structure facts survive with name changes (dropped `exit-` prefix).

### In pre-007 Rust (scalars only), missing from inscription 9:
No pre-007 Rust equivalent (exit modules did not exist pre-007).

---

## Module: exit/timing

### In inscription 5, missing from inscription 9:
- exit-stoch-k (Linear) — stochastic %K position for exit timing

Inscription 9 replaced `exit-stoch-k` with `stoch-kd-spread` (the spread, not the raw position). Also dropped `exit-` prefix from all names.

### In pre-007 Rust (scalars only), missing from inscription 9:
No pre-007 Rust equivalent (exit modules did not exist pre-007).

---

## Module: exit/volatility

### In inscription 5, missing from inscription 9:
No facts lost. Same six facts with `exit-` prefix dropped.

### In pre-007 Rust (scalars only), missing from inscription 9:
No pre-007 Rust equivalent.

---

## Module: shared/time

### In inscription 5, missing from inscription 9:
No facts lost. Inscription 5 used `month`, inscription 9 uses `month-of-year` (same fact, different name).

### In pre-007 Rust (scalars only), missing from inscription 9:
No pre-007 Rust equivalent for time (calendar was handled in ThoughtEncoder::eval_calendar, not in vocab modules).

---

## Dissolved modules (pre-007, no equivalent in inscription 9)

### harmonics
Full XABCD harmonic pattern detection: Gartley, Bat, Butterfly, Crab, Deep Crab, Cypher patterns. Contained:
- Swing detection (local highs/lows with configurable radius)
- Zigzag alternation (enforced high-low alternation)
- Six harmonic templates with Fibonacci ratio constraints (AB/XA, BC/AB, CD/AB, D/XA ranges)
- Pattern matching with match quality scoring (center-weighted ratio fit)
- **Scalar facts lost:**
  - harmonic-quality (Scalar) — match quality [0, 1], center-weighted ratio fit across four legs
- **Zone facts (not tracked but notable):** gartley-bullish, gartley-bearish, bat-bullish, bat-bearish, butterfly-bullish, butterfly-bearish, crab-bullish, crab-bearish, deep-crab-bullish, deep-crab-bearish, cypher-bullish, cypher-bearish
- 476 lines of Rust including 6 cross-verified harmonic templates, swing detection, zigzag, comprehensive test suite

### standard
Universal context facts that every observer received. Contained:
- **Recency scalars (Fact::Scalar):**
  - since-rsi-extreme — log-scaled candles since last RSI > 70 or RSI < 30
  - since-vol-spike — log-scaled candles since last volume acceleration > 2.0
  - since-large-move — log-scaled candles since last ROC exceeding 2x ATR
- **Distance scalars (Fact::Scalar):**
  - dist-from-high — percentage distance from window high, rescaled to [0, 1]
  - dist-from-low — percentage distance from window low, rescaled to [0, 1]
  - dist-from-midpoint — percentage distance from window midpoint, rescaled to [0, 1]
  - dist-from-sma200 — percentage distance from SMA200, rescaled to [0, 1]
- **Participation scalar (Fact::Scalar):**
  - volume-ratio — current volume / SMA20 volume, clamped and rescaled to [0, 1]
- **Session scalar (Fact::Scalar):**
  - session-depth — hour / 24.0, fractional position in the trading day
- 222 lines of Rust, comprehensive test suite

---

## Summary of losses

### Facts completely absent from inscription 9 (no equivalent anywhere):

**From inscription 5 wat:**
1. divergence-spread — net divergence pressure (bull minus bear)
2. buying-pressure — close-relative-to-low wick ratio
3. ichimoku-tenkan-dist — distance from close to tenkan-sen
4. ichimoku-kijun-dist — distance from close to kijun-sen
5. ichimoku-cloud-top-dist — separate distance from cloud top
6. ichimoku-cloud-bottom-dist — separate distance from cloud bottom
7. kelt-upper-dist — distance from close to Keltner upper band
8. kelt-lower-dist — distance from close to Keltner lower band
9. pa-body-ratio — candlestick body as fraction of range
10. pa-upper-wick — upper shadow as fraction of range
11. pa-lower-wick — lower shadow as fraction of range
12. fib-dist-236 — distance to 0.236 Fibonacci level
13. fib-dist-382 — distance to 0.382 Fibonacci level
14. fib-dist-500 — distance to 0.500 Fibonacci level
15. fib-dist-618 — distance to 0.618 Fibonacci level
16. fib-dist-786 — distance to 0.786 Fibonacci level
17. tf-5m-1h-align — directional alignment between 5m and 1h
18. exit-kama-er — KAMA efficiency ratio in exit context
19. exit-stoch-k — stochastic %K in exit context
20. atr-ratio (from market/momentum) — ATR ratio removed from market module

**From pre-007 Rust (Scalar only, no equivalent anywhere):**
1. sell-pressure — upper wick selling pressure ratio
2. buy-pressure — lower wick buying pressure ratio
3. body-ratio — body as fraction of range (in flow module)
4. stoch-rsi — stochastic %K as RSI-like oscillator (distinct from stoch-k)
5. harmonic-quality — XABCD pattern match quality
6. since-rsi-extreme — recency of RSI extreme
7. since-vol-spike — recency of volume spike
8. since-large-move — recency of large price move
9. dist-from-high — distance from window high
10. dist-from-low — distance from window low
11. dist-from-midpoint — distance from window midpoint
12. dist-from-sma200 — distance from SMA200
13. volume-ratio — relative volume participation
14. session-depth — fractional position in trading day

### Modules dissolved entirely:
- **harmonics** — 476 lines, 6 XABCD patterns, swing detection + zigzag + template matching
- **standard** — 222 lines, recency/distance/participation/session-depth context for all observers
