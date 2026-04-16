;; market-observer-thought.wat — the market observer's thought.
;;
;; NOT a single candle snapshot. A movie. Each indicator the lens
;; selects gets its own rhythm via indicator-rhythm. The market
;; observer bundles all rhythms into one thought.
;;
;; Lens: dow-trend. ~15 indicators → 15 rhythm vectors → 1 bundle.
;; The window sampler determines how far back (12-2016 candles).
;; Each rhythm covers the last sqrt(D)+2 candles of the window.

(define (market-observer-thought window dims)
  (bundle
    ;; Trend streams — how are the moving average relations evolving?
    (indicator-rhythm window "close-sma20"  (lambda (c) (/ (- c.close c.sma20) c.sma20))  dims)
    (indicator-rhythm window "close-sma50"  (lambda (c) (/ (- c.close c.sma50) c.sma50))  dims)
    (indicator-rhythm window "sma20-sma50"  (lambda (c) (/ (- c.sma20 c.sma50) c.sma50))  dims)

    ;; Bollinger — where is price in the band, and how wide is it?
    (indicator-rhythm window "bb-pos"       (lambda (c) c.bb-pos)       dims)
    (indicator-rhythm window "bb-width"     (lambda (c) c.bb-width)     dims)

    ;; Momentum — RSI, MACD, stochastic over time
    (indicator-rhythm window "rsi"          (lambda (c) c.rsi)          dims)
    (indicator-rhythm window "macd-hist"    (lambda (c) c.macd-hist)    dims)
    (indicator-rhythm window "stoch-k"      (lambda (c) c.stoch-k)     dims)

    ;; Directional — who's winning, and is the trend strong?
    (indicator-rhythm window "adx"          (lambda (c) c.adx)          dims)
    (indicator-rhythm window "plus-di"      (lambda (c) c.plus-di)      dims)
    (indicator-rhythm window "minus-di"     (lambda (c) c.minus-di)     dims)

    ;; Volatility — how is ATR changing?
    (indicator-rhythm window "atr-ratio"    (lambda (c) c.atr-ratio)    dims)

    ;; Volume — is participation growing or fading?
    (indicator-rhythm window "obv-slope"    (lambda (c) c.obv-slope)    dims)
    (indicator-rhythm window "volume-accel" (lambda (c) c.volume-accel) dims)

    ;; Range position — where is price in its recent range?
    (indicator-rhythm window "range-pos-48" (lambda (c) c.range-pos-48) dims)))

;; 15 rhythm vectors. 15 items in the bundle. Each rhythm is one
;; vector — one indicator's evolution across the window.
;;
;; What the reckoner sees (examples):
;;
;; "RSI rhythm rising while volume rhythm falling"
;;   → momentum without conviction. The reckoner learns: Violence.
;;
;; "ADX rhythm rising + plus-di rhythm above minus-di rhythm"
;;   → strengthening uptrend. The reckoner learns: Up.
;;
;; "bb-width rhythm expanding + range-pos rhythm at extremes"
;;   → volatility breakout. The reckoner learns: strong directional move.
;;
;; We don't name these combinations. The discriminant discovers them.
;; The noise subspace strips the rhythms that don't vary with outcomes.
;;
;; Capacity at D=10,000:
;;   Inner: each rhythm bundles up to 100 pairs (sqrt(D))
;;   Outer: 15 rhythms in the market observer's thought bundle
;;   The market observer's thought goes to the position observer
;;   and then to the broker, where it joins other thoughts.
