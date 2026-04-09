;; vocab/exit/volatility.wat — ATR regime, ATR ratio, squeeze state
;; Depends on: candle
;; ExitLens :volatility selects this module.

(require primitives)
(require candle)

;; Volatility facts for exit observers.
;; "How wide should the stops be?" depends on how volatile the market is.
;; ATR is the foundation. ATR-ROC tells you if volatility is expanding or contracting.
;; Squeeze tells you if a breakout is imminent.
(define (encode-exit-volatility-facts [c : Candle])
  : Vec<ThoughtAST>
  (list
    ;; ATR ratio — volatility relative to price. Log for ratios.
    (Log "exit-atr-ratio" (max 0.0001 (:atr-r c)))

    ;; ATR rate of change — is volatility expanding or contracting?
    ;; 6-period: short-term volatility trend.
    (Linear "exit-atr-roc-6" (:atr-roc-6 c) 1.0)

    ;; 12-period: medium-term volatility trend.
    (Linear "exit-atr-roc-12" (:atr-roc-12 c) 1.0)

    ;; Squeeze ratio — BB inside Keltner = compressed volatility.
    ;; < 1.0 = squeeze (stops should be tighter).
    ;; > 1.0 = expansion (stops should be wider).
    (Log "exit-squeeze" (max 0.01 (:squeeze c)))

    ;; Bollinger width — absolute band width relative to price.
    (Log "exit-bb-width" (max 0.001 (:bb-width c)))

    ;; Range ratio — compression vs expansion of the current bar.
    (Log "exit-range-ratio" (max 0.01 (:range-ratio c)))))
