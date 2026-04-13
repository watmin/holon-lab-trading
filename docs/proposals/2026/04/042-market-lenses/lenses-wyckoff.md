# Market Lenses: Wyckoff

I organized my 25 atoms by phase because that is how I taught them.
But an observer does not know what phase the market is in. That is
what it is trying to learn. Grouping by phase would be circular.

Group by the question the observer asks of every candle.

## Three observers

### 1. Effort (volume + price action)

Is the effort producing result, or is it wasted?

```scheme
(define (effort-lens)
  (list
    (Log    "volume-ratio"      volume_ratio)
    (Log    "obv-slope"         obv_slope)
    (Linear "buying-pressure"   buying_pressure 1.0)
    (Linear "selling-pressure"  selling_pressure 1.0)
    (Linear "body-ratio-pa"     body_ratio_pa 1.0)
    (Linear "upper-wick"        upper_wick 1.0)
    (Linear "lower-wick"        lower_wick 1.0)
    (Linear "mfi"               mfi 1.0)
    (Log    "since-vol-spike"   since_vol_spike)))
```

Nine atoms. The core of my method. Volume is the lie detector.
Wicks are the confession. Effort without result is distribution.
Result without effort is markup about to fail.

### 2. Persistence (trend + regime)

Is the current condition persisting or decaying?

```scheme
(define (persistence-lens)
  (list
    (Linear "adx"               adx 1.0)
    (Linear "di-spread"         di_spread 1.0)
    (Linear "hurst"             hurst 1.0)
    (Linear "kama-er"           kama_er 1.0)
    (Linear "choppiness"        choppiness 1.0)
    (Log    "atr-ratio"         atr_ratio)
    (Log    "consecutive-down"  consecutive_down)
    (Log    "roc-12"            roc_12)))
```

Eight atoms. ADX tells you strength. Hurst tells you memory.
Choppiness tells you disorder. Together they answer: will this
condition survive the next candle?

### 3. Position (where is price relative to structure?)

```scheme
(define (position-lens)
  (list
    (Linear "close-sma20"       close_sma20 0.1)
    (Linear "close-sma50"       close_sma50 0.1)
    (Linear "close-sma200"      close_sma200 0.1)
    (Linear "dist-from-high"    dist_from_high 0.1)
    (Linear "dist-from-low"     dist_from_low 0.1)
    (Linear "aroon-up"          aroon_up 1.0)
    (Linear "aroon-down"        aroon_down 1.0)
    (Linear "rsi-divergence-bull" rsi_div_bull 1.0)
    (Linear "rsi-divergence-bear" rsi_div_bear 1.0)
    (Log    "since-rsi-extreme" since_rsi_extreme)))
```

Ten atoms. Where price sits relative to its history, and
whether momentum agrees with that position. Divergence lives
here because it is a positional statement: momentum is NOT
where price says it is.

## Why three, not four

Regime is not a lens. It is an emergent property. When the
effort lens sees volume drying up and the persistence lens
sees ADX falling, the noise subspace learns "accumulation"
without anyone naming it. That is the point. The observer
asks its question. The subspace discovers the phase.

## The grid

3 market x 2 exit = 6 brokers per post. Down from 6 x M.
Enough diversity. Enough data per broker to learn.

No generalist. Twenty atoms is already lean. A generalist
seeing 25 would overlap too much with each specialist.
Let the three lenses triangulate.
