# Proposal 041 — Market Vocabulary Challenge

**Scope:** userland

**Context:** Proposals 038-040 shifted the exit observer from
market-facing atoms to trade-state atoms. The exit observers now
think about the TRADE. The market observers still think about
the CHART with ~80 atoms from 16 vocabulary modules.

## How the market observer works

```scheme
(define (market-observer-on-candle candle window)
  (let* ((facts (market-lens-facts lens candle window scales))
         (thought (encode (Bundle facts)))
         (anomaly (strip-noise thought))
         (prediction (predict reckoner anomaly)))
    (MarketChain candle thought anomaly prediction edge)))
```

The market observer encodes candle data through a lens. Each lens
selects vocabulary modules. The reckoner predicts direction (Up/Down).
The noise subspace strips what's normal. The anomaly IS the signal.

## The current vocabulary (~80 atoms across 16 modules)

```scheme
;; Momentum (6): rsi, macd-hist, cci, williams-r, mfi, roc-1
;; Oscillators (6): stoch-k, stoch-d, stoch-kd-spread, stoch-cross-delta, rsi, cci
;; Flow (5): volume-ratio, obv-slope, buying-pressure, selling-pressure, mfi
;; Persistence (5): hurst, autocorrelation, dfa-alpha, vwap-distance, since-large-move
;; Regime (8): kama-er, choppiness, entropy-rate, fractal-dim, variance-ratio, aroon-up, aroon-down, dfa-alpha
;; Structure (8): range-pos-12, range-pos-24, range-pos-48, range-ratio, gap, consecutive-up, consecutive-down, close-sma20
;; Price action (7): body-ratio-pa, upper-wick, lower-wick, dist-from-high, dist-from-low, dist-from-midpoint, dist-from-sma200
;; Ichimoku (7): cloud-position, cloud-thickness, tenkan-dist, kijun-dist, tk-cross-delta, tk-spread, senkou-spread
;; Keltner (4): kelt-pos, kelt-upper-dist, kelt-lower-dist, squeeze
;; Fibonacci (5): fib-dist-236, fib-dist-382, fib-dist-500, fib-dist-618, fib-dist-786
;; Divergence (3): rsi-divergence-bull, rsi-divergence-bear, divergence-spread
;; Stochastic (5): stoch-k, stoch-d, stoch-kd-spread, stoch-cross-delta, since-rsi-extreme
;; Standard (8): close-sma20, close-sma50, close-sma200, bb-pos, bb-width, atr-ratio, roc-6, roc-12
;; Timeframe (6): tf-1h-ret, tf-1h-trend, tf-4h-ret, tf-4h-trend, tf-5m-1h-align, tf-agreement
;; Time (4): session-depth + circular hour/day/month
```

80+ atoms. Duplication: rsi appears in momentum AND oscillators.
stoch-k appears in oscillators AND stochastic. close-sma20 appears
in structure AND standard.

## The question the market observer answers

The hold architecture (038) changed the question from:
  "will the next 36 candles go up 0.5%?"
to:
  "is something forming? should we be ready?"

Readiness is not direction prediction on short horizons. Readiness
is STATE DETECTION:
  - Is this an accumulation zone?
  - Is the trend establishing or exhausting?
  - Is volume confirming or diverging?
  - Is the regime trending or choppy?

## The paper's state at entry

The market observer's prediction feeds the broker. The broker
registers a paper. The paper's LIFETIME depends on the market
observer's accuracy. A readiness signal that fires at accumulation
produces papers that HOLD for days and capture 5%. A readiness
signal that fires randomly produces papers that die quickly.

## For the designers

Given this system:
1. The reckoner learns which atoms predict direction
2. The noise subspace strips what's normal
3. The anomaly (what survives stripping) IS the signal
4. 80+ atoms, many duplicated, from textbook indicators

**What atoms actually matter for READINESS?** Not for predicting
the next candle — for detecting that the market is in a state
where entry is favorable for a HOLD.

Express your answer as ThoughtAST. Each atom must be computable
from the Candle struct (OHLCV + indicators). Group them by what
question they answer.

```scheme
(Linear "atom-name" value scale)
(Log "atom-name" value)
(Circular "atom-name" value period)
```
