;; vocab/exit/volatility.wat — ATR regime, ATR ratio, squeeze state
;; Depends on: candle.wat
;; Domain: exit — distance signal
;; Lens: :volatility

(require primitives)
(require candle)

(define (encode-exit-volatility-facts [c : Candle])
  : Vec<ThoughtAST>
  (let ((atr (:atr c))
        (atr-r (:atr-r c))
        (squeeze (:squeeze c))
        (bb-width (:bb-width c))
        (atr-roc-6 (:atr-roc-6 c))
        (atr-roc-12 (:atr-roc-12 c)))
    (list
      ;; ATR ratio — volatility relative to price. Log because ratio.
      (Log "exit-atr-ratio" (max atr-r 0.0001))

      ;; ATR rate of change — is volatility expanding or contracting?
      (Linear "exit-atr-roc-6" atr-roc-6 1.0)
      (Linear "exit-atr-roc-12" atr-roc-12 1.0)

      ;; Squeeze state — BB inside Keltner means compression
      (Linear "exit-squeeze" squeeze 2.0)

      ;; BB width — absolute volatility breadth
      (Log "exit-bb-width" (+ 1.0 bb-width))

      ;; Raw ATR for context
      (Log "exit-atr" (max atr 0.01)))))
