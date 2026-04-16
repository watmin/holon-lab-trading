;; market-observer-thought.wat — the market observer's thought.
;;
;; A movie, not a photograph. Each indicator the lens selects gets
;; its own rhythm via indicator-rhythm. The market observer bundles
;; all rhythms into one thought.
;;
;; Lens: dow-trend. ~15 indicators → 15 rhythm vectors → 1 bundle.
;; The window sampler determines how far back (12-2016 candles).
;; Each rhythm covers the last sqrt(D)+2 candles of the window.

(define (market-observer-thought window dims)
  (bundle
    ;; Trend streams — how are the moving average relations evolving?
    (indicator-rhythm window "close-sma20"
      (lambda (c) (/ (- (:close c) (:sma20 c)) (:sma20 c))) dims)
    (indicator-rhythm window "close-sma50"
      (lambda (c) (/ (- (:close c) (:sma50 c)) (:sma50 c))) dims)
    (indicator-rhythm window "sma20-sma50"
      (lambda (c) (/ (- (:sma20 c) (:sma50 c)) (:sma50 c))) dims)

    ;; Bollinger — where is price in the band, and how wide is it?
    (indicator-rhythm window "bb-pos"       (lambda (c) (:bb-pos c))       dims)
    (indicator-rhythm window "bb-width"     (lambda (c) (:bb-width c))     dims)

    ;; Momentum — RSI, MACD, stochastic over time
    (indicator-rhythm window "rsi"          (lambda (c) (:rsi c))          dims)
    (indicator-rhythm window "macd-hist"    (lambda (c) (:macd-hist c))    dims)
    (indicator-rhythm window "stoch-k"      (lambda (c) (:stoch-k c))     dims)

    ;; Directional — who's winning, and is the trend strong?
    (indicator-rhythm window "adx"          (lambda (c) (:adx c))          dims)
    (indicator-rhythm window "plus-di"      (lambda (c) (:plus-di c))      dims)
    (indicator-rhythm window "minus-di"     (lambda (c) (:minus-di c))     dims)

    ;; Volatility — how is ATR changing?
    (indicator-rhythm window "atr-ratio"    (lambda (c) (:atr-ratio c))    dims)

    ;; Volume — is participation growing or fading?
    (indicator-rhythm window "obv-slope"    (lambda (c) (:obv-slope c))    dims)
    (indicator-rhythm window "volume-accel" (lambda (c) (:volume-accel c)) dims)

    ;; Range position — where is price in its recent range?
    (indicator-rhythm window "range-pos-48" (lambda (c) (:range-pos-48 c)) dims)))

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
