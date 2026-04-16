;; market-observer-thought.wat — the market observer's thought.
;;
;; A movie, not a photograph. Each indicator gets its own rhythm.
;; The atom wraps the whole rhythm, not each candle's fact.
;; Continuous indicators use thermometer + delta.
;; Periodic indicators use circular, no delta.
;;
;; Lens: dow-trend. ~15 indicators → 15 rhythm vectors → 1 bundle.

(define (market-observer-thought window dims)
  (bundle
    ;; Trend streams — thermometer, natural bounds
    (indicator-rhythm window "close-sma20"
      (lambda (c) (/ (- (:close c) (:sma20 c)) (:sma20 c)))
      -0.1 0.1 0.05 dims)
    (indicator-rhythm window "close-sma50"
      (lambda (c) (/ (- (:close c) (:sma50 c)) (:sma50 c)))
      -0.2 0.2 0.1 dims)
    (indicator-rhythm window "sma20-sma50"
      (lambda (c) (/ (- (:sma20 c) (:sma50 c)) (:sma50 c)))
      -0.1 0.1 0.05 dims)

    ;; Bollinger
    (indicator-rhythm window "bb-pos"       (lambda (c) (:bb-pos c))       0.0 1.0 0.2 dims)
    (indicator-rhythm window "bb-width"     (lambda (c) (:bb-width c))     0.0 0.2 0.05 dims)

    ;; Momentum — thermometer, natural bounds
    (indicator-rhythm window "rsi"          (lambda (c) (:rsi c))          0.0 100.0 10.0 dims)
    (indicator-rhythm window "macd-hist"    (lambda (c) (:macd-hist c))    -50.0 50.0 20.0 dims)
    (indicator-rhythm window "stoch-k"      (lambda (c) (:stoch-k c))     0.0 100.0 10.0 dims)

    ;; Directional
    (indicator-rhythm window "adx"          (lambda (c) (:adx c))          0.0 100.0 10.0 dims)
    (indicator-rhythm window "plus-di"      (lambda (c) (:plus-di c))      0.0 100.0 10.0 dims)
    (indicator-rhythm window "minus-di"     (lambda (c) (:minus-di c))     0.0 100.0 10.0 dims)

    ;; Volatility
    (indicator-rhythm window "atr-ratio"    (lambda (c) (:atr-ratio c))    0.0 0.05 0.01 dims)

    ;; Volume
    (indicator-rhythm window "obv-slope"    (lambda (c) (:obv-slope c))    -2.0 2.0 1.0 dims)
    (indicator-rhythm window "volume-accel" (lambda (c) (:volume-accel c)) 0.0 3.0 1.0 dims)

    ;; Range position
    (indicator-rhythm window "range-pos-48" (lambda (c) (:range-pos-48 c)) 0.0 1.0 0.2 dims)))

;; 15 rhythm vectors. Each one: (bind (atom name) raw-rhythm).
;; The atom appears ONCE per rhythm. The raw rhythm is the progression.
;; Different indicators are orthogonal because the atoms are different.
;;
;; Bounds are from the indicator's nature:
;;   RSI: [0, 100] by Wilder's definition
;;   Bollinger position: [0, 1] by construction
;;   ATR ratio: [0, 0.05] typical range
;;   MACD histogram: [-50, 50] typical range
;;   Delta ranges: per-candle change, typically 10-20% of value range
