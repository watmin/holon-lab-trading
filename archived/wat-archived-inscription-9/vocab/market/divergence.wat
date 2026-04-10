;; vocab/market/divergence.wat — RSI divergence via PELT structural peaks
;; Depends on: candle
;; MarketLens :narrative uses this module.

(require primitives)
(require candle)

(define (encode-divergence-facts [c : Candle])
  : Vec<ThoughtAST>
  (let ((bull-mag (:rsi-divergence-bull c))
        (bear-mag (:rsi-divergence-bear c)))
    (append
      ;; Bullish divergence: price lower low, RSI higher low
      (if (> bull-mag 0.0)
        (list (Log "rsi-divergence-bull" (+ 1.0 bull-mag)))
        '())
      ;; Bearish divergence: price higher high, RSI lower high
      (if (> bear-mag 0.0)
        (list (Log "rsi-divergence-bear" (+ 1.0 bear-mag)))
        '()))))
