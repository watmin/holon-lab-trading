# Market Atoms: Wyckoff

Phase detection, not next-candle prediction. Volume is the lie detector.
Price is the advertisement. The question is always: who is in control?

## Accumulation (the spring)

Volume dries up. Range contracts. Price stops making new lows.
The composite operator absorbs supply without moving price.

```scheme
(Log    "volume-ratio"      volume_ratio)        ;; KEEP — drying volume is THE sign
(Log    "atr-ratio"         atr_ratio)            ;; KEEP — range contraction
(Linear "choppiness"        choppiness 1.0)       ;; KEEP — high = sideways absorption
(Linear "dist-from-low"     dist_from_low 0.1)    ;; KEEP — proximity to support
(Log    "since-vol-spike"   since_vol_spike)      ;; KEEP — time since selling climax
(Linear "rsi-divergence-bull" rsi_div_bull 1.0)   ;; KEEP — price flat, momentum rising
(Linear "buying-pressure"   buying_pressure 1.0)  ;; KEEP — closes near highs on low volume
(Linear "lower-wick"        lower_wick 1.0)       ;; KEEP — rejection of lower prices
(Log    "obv-slope"         obv_slope)            ;; KEEP — accumulation shows here first
```

## Markup (the trend)

Price advances on expanding volume. Pullbacks occur on declining volume.
ADX rises. Hurst > 0.5. The trend persists.

```scheme
(Linear "close-sma20"       close_sma20 0.1)     ;; KEEP — above short MA
(Linear "close-sma50"       close_sma50 0.1)     ;; KEEP — above medium MA
(Linear "di-spread"         di_spread 1.0)        ;; KEEP — +DI dominates
(Linear "adx"               adx 1.0)              ;; KEEP — trend strength rising
(Linear "hurst"             hurst 1.0)            ;; KEEP — persistence > 0.5
(Linear "kama-er"           kama_er 1.0)          ;; KEEP — efficiency = trending
(Linear "aroon-up"          aroon_up 1.0)         ;; KEEP — recent highs
```

## Distribution (the UTAD)

Volume surges on up-bars that fail to make progress. Wide range,
closes in middle or lower half. Supply overwhelms.

```scheme
(Log    "volume-ratio"      volume_ratio)         ;; same atom, opposite reading
(Linear "body-ratio-pa"     body_ratio_pa 1.0)    ;; KEEP — small bodies = effort failing
(Linear "upper-wick"        upper_wick 1.0)       ;; KEEP — rejection at highs
(Linear "selling-pressure"  selling_pressure 1.0) ;; KEEP — closes near lows
(Linear "dist-from-high"    dist_from_high 0.1)   ;; KEEP — proximity to resistance
(Linear "rsi-divergence-bear" rsi_div_bear 1.0)   ;; KEEP — price flat, momentum falling
(Linear "mfi"               mfi 1.0)              ;; KEEP — money flow diverges from price
(Log    "since-rsi-extreme" since_rsi_extreme)    ;; KEEP — how long since overbought
```

## Markdown (the decline)

Mirror of markup. Price falls on volume. Rallies are anemic.

```scheme
(Linear "di-spread"         di_spread 1.0)        ;; reuse — -DI dominates
(Linear "adx"               adx 1.0)              ;; reuse — trend strength
(Linear "aroon-down"        aroon_down 1.0)       ;; KEEP — recent lows
(Linear "close-sma200"      close_sma200 0.1)     ;; KEEP — below long MA = bear
(Log    "consecutive-down"  consecutive_down)      ;; KEEP — sustained pressure
(Log    "roc-12"            roc_12)                ;; KEEP — medium-term rate of change
```

## What to cut

Kill: stochastic (stoch-k, stoch-d, stoch-kd-spread, stoch-cross-delta).
Lagging oscillator noise. Kill: ichimoku (7 atoms). Cloud position is
just another MA relationship; you already have three. Kill: keltner (4).
BB-width is atr-ratio by another name. Kill: fibonacci (5). Static levels
mean nothing without volume confirmation. Kill: timeframe (6). Higher
timeframe alignment is a crutch for weak conviction.

**Surviving atoms: 25 unique from 80+.** The noise subspace will learn
what's normal. These 25 give it something worth stripping.
