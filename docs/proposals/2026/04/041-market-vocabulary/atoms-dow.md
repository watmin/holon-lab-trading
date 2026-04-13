# Market Atoms: Dow

The market discounts everything. Readiness is not prediction — it is recognition that conditions favor entry. Three questions matter: Is a trend present? Does volume confirm it? Where are we in the cycle?

## CUT (55 atoms)

All of fibonacci (8), ichimoku (6), keltner except squeeze (5), oscillators except rsi (7), stochastic (4), divergence (3), price-action except body-ratio-pa (6), momentum duplicates close-sma20/50 (moved to trend), most regime atoms that measure the same thing differently (4), timeframe returns and sub-atoms (4), session-depth, since-rsi-extreme, gap, consecutive-up, consecutive-down, range-ratio.

These are noise. Fibonacci levels are superstition. Ichimoku is a redundant trend system. Multiple oscillators saying the same thing corrupt the bundle.

## KEEP: Is the trend established? (8 atoms)

```scheme
(Linear "close-sma20"  (/ (- close sma20) close)  0.1)   ;; short-term trend
(Linear "close-sma50"  (/ (- close sma50) close)  0.1)   ;; intermediate trend
(Linear "close-sma200" (/ (- close sma200) close) 0.1)   ;; primary trend
(Linear "di-spread"    (/ (- plus-di minus-di) 100) 1.0)  ;; directional conviction
(Linear "adx"          (/ adx 100.0)              1.0)    ;; trend strength
(Linear "macd-hist"    (/ macd-hist close)         0.01)  ;; trend acceleration
(Linear "hurst"        hurst                       1.0)   ;; persistence of trend
(Linear "kama-er"      kama-er                     1.0)   ;; efficiency: signal vs noise
```

## KEEP: Does volume confirm? (4 atoms)

```scheme
(Log    "volume-ratio"     (max 0.001 volume-ratio))       ;; expansion or contraction
(Log    "obv-slope"        (exp obv-slope-12))             ;; cumulative flow direction
(Linear "buying-pressure"  buying-pressure           1.0)  ;; who controls the candle
(Linear "selling-pressure" selling-pressure          1.0)  ;; rejection or acceptance
```

## KEEP: Where in the cycle? (7 atoms)

```scheme
(Linear "rsi"              rsi                       1.0)  ;; oversold = accumulation
(Linear "squeeze"          squeeze                   1.0)  ;; compression before expansion
(Log    "bb-width"         (max 0.001 bb-width))           ;; volatility regime
(Log    "atr-ratio"        (max 0.001 atr-r))              ;; normalized volatility
(Linear "dist-from-high"   (/ (- price high) price)  0.1)  ;; distance from ceiling
(Linear "dist-from-low"    (/ (- price low) price)   0.1)  ;; distance from floor
(Log    "since-large-move" (max 1.0 candles-since))        ;; time since disruption
```

## KEEP: Do timeframes agree? (3 atoms)

```scheme
(Linear "tf-agreement"    tf-agreement               1.0)  ;; alignment across scales
(Linear "tf-4h-trend"     tf-4h-body                 1.0)  ;; primary timeframe direction
(Linear "tf-5m-1h-align"  alignment                  0.1)  ;; minor confirms secondary
```

## NEW: Trend confirmation (2 atoms)

```scheme
(Log    "since-vol-spike"  (max 1.0 candles-since))        ;; recency of volume event
(Linear "choppiness"       (/ choppiness 100.0)      1.0)  ;; trending vs ranging
```

## Total: 24 atoms

80 to 24. A trend persists until reversed. Volume confirms or denies. The cycle tells you where you stand. Everything else is decoration.
