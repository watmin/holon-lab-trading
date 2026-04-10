;; vocab/exit/volatility.wat — ATR regime, ATR ratio, squeeze state
;; Depends on: candle
;; ExitLens :volatility uses this module.

(require primitives)
(require candle)

(define (encode-exit-volatility-facts [c : Candle])
  : Vec<ThoughtAST>
  (list
    ;; ATR ratio — volatility relative to price
    (Log "atr-ratio" (max 0.0001 (:atr-r c)))
    ;; ATR rate of change — is volatility expanding or contracting?
    (Linear "atr-roc-6" (:atr-roc-6 c) 1.0)
    (Linear "atr-roc-12" (:atr-roc-12 c) 1.0)
    ;; Squeeze state — BB inside Keltner
    (Log "squeeze" (max 0.001 (:squeeze c)))
    ;; Bollinger width — how wide are the bands
    (Log "bb-width" (max 0.001 (:bb-width c)))
    ;; Range ratio — compression vs expansion
    (Log "range-ratio" (max 0.001 (:range-ratio c)))))
