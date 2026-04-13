# Market Atoms: Pring

The question is momentum/price relationship. Momentum LEADS price
into moves and DIVERGES from price as moves end. Of 80+ atoms,
these detect the beginning and end of swings.

## Momentum leading price (accumulation forming)

```scheme
;; Rate of change across timeframes — momentum turns BEFORE price
(Log "roc-1" (+ 1.0 roc-1))          ; immediate impulse
(Log "roc-6" (+ 1.0 roc-6))          ; intermediate momentum
(Log "roc-12" (+ 1.0 roc-12))        ; swing momentum

;; MACD histogram — momentum's derivative. Shrinking = deceleration
(Linear "macd-hist" (/ macd-hist close) scale:adaptive)

;; Directional spread — trend conviction emerging
(Linear "di-spread" (/ (- plus-di minus-di) 100) scale:1.0)

;; ADX — trend strength building. Rising ADX + price flat = coiling
(Linear "adx" (/ adx 100) scale:1.0)
```

## Volume confirming momentum

```scheme
;; OBV slope — smart money accumulates before price moves
(Log "obv-slope" (exp obv-slope-12))

;; Volume ratio — volume expanding into the move
(Log "volume-ratio" (exp volume-accel))

;; MFI — money flow confirms or denies. Divergence = lie
(Linear "mfi" (/ mfi 100) scale:1.0)
```

## Divergence (distribution forming)

```scheme
;; RSI divergence — THE classic momentum/price divergence signal
(Linear "rsi-divergence-bull" bull scale:1.0)  ; conditional
(Linear "rsi-divergence-bear" bear scale:1.0)  ; conditional

;; RSI level — not for direction, for exhaustion zones
(Linear "rsi" rsi scale:1.0)

;; Time since RSI extreme — how long since last exhaustion
(Log "since-rsi-extreme" since-rsi-extreme)
```

## Regime context (trending or choppy)

```scheme
;; Efficiency ratio — near 1.0 = trending, near 0.0 = noise
(Linear "kama-er" kama-er scale:1.0)

;; Hurst exponent — >0.5 persistent, <0.5 mean-reverting
(Linear "hurst" hurst scale:1.0)

;; Variance ratio — >1.0 trending, <1.0 mean-reverting
(Log "variance-ratio" variance-ratio)
```

## Multi-timeframe confirmation

```scheme
;; Higher timeframes must agree for a HOLD entry
(Linear "tf-agreement" tf-agreement scale:1.0)
(Linear "tf-4h-trend" tf-4h-body scale:1.0)
```

## What I would cut

Fibonacci, Keltner, Ichimoku cloud details, stochastic %K/%D,
Williams %R, CCI, price action wicks, consecutive counts, fractal
dimension, choppiness, entropy rate, DFA alpha, Aroon. These are
either redundant with the above or answer questions about WHERE
price is, not whether momentum is leading or lagging price.

**20 atoms. Not 80.** The reckoner learns which matter. Give it
the momentum/price relationship and let the noise subspace strip
the rest.
