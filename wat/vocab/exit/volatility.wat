;; vocab/exit/volatility.wat — ATR regime, ATR ratio, squeeze state
;; Depends on: candle
;; ExitLens :volatility selects this module.

(require primitives)
(require candle)

(define (encode-exit-volatility-facts [c : Candle])
  : Vec<ThoughtAST>
  (list
    ;; ATR ratio — volatility relative to price. Log compresses.
    (Log "exit-atr-ratio" (max (:atr-r c) 0.00001))

    ;; ATR rate of change — how is volatility changing?
    (Linear "exit-atr-roc-6" (:atr-roc-6 c) 1.0)
    (Linear "exit-atr-roc-12" (:atr-roc-12 c) 1.0)

    ;; Squeeze state — BB/Keltner ratio. Compression predicts expansion.
    (Linear "exit-squeeze" (:squeeze c) 2.0)

    ;; Bollinger width — absolute spread
    (Log "exit-bb-width" (max (:bb-width c) 0.001))

    ;; Range ratio — expansion/compression
    (Log "exit-range-ratio" (max (:range-ratio c) 0.001))))
