# Market Lenses: Dow

Three observers and a generalist. Four lenses total.

The market asks three questions. Each lens answers one. The generalist holds all 24 atoms — it is the observer that refuses to specialize, and that refusal is itself a perspective.

## Lens 1: Trend (10 atoms)

```scheme
(define (market-lens-trend)
  (list
    (close-sma20) (close-sma50) (close-sma200)
    (di-spread) (adx) (macd-hist)
    (hurst) (kama-er)
    (tf-agreement) (choppiness)))
```

Is the trend established? How strong? How efficient? Does the higher timeframe agree? Trend atoms plus the confirmation atoms that validate them.

## Lens 2: Volume (6 atoms)

```scheme
(define (market-lens-volume)
  (list
    (volume-ratio) (obv-slope)
    (buying-pressure) (selling-pressure)
    (since-vol-spike) (squeeze)))
```

Does volume confirm? Who controls the candle? Is energy building or spent? Squeeze belongs here — compression is a volume phenomenon before it is a price one.

## Lens 3: Cycle (8 atoms)

```scheme
(define (market-lens-cycle)
  (list
    (rsi) (bb-width) (atr-ratio)
    (dist-from-high) (dist-from-low)
    (since-large-move)
    (tf-4h-trend) (tf-5m-1h-align)))
```

Where in the cycle? Overbought, compressed, extended? Distance from extremes. Time since disruption. The 4h trend and 5m/1h alignment tell you which phase of the cycle the timeframes see.

## Lens 4: Generalist (24 atoms)

All atoms. No filter. The observer that sees everything pays the cost of seeing everything — its thoughts are noisier, but it catches what specialization misses.

## Grid

3 specialists + 1 generalist = 4 market observers x 2 exit observers = 8 brokers per post. Enough diversity. Enough data per broker.
