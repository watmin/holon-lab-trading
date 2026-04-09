;; vocab/market/stochastic.wat — %K/%D spread and crosses
;; Depends on: candle
;; MarketLens :momentum uses this.

(require primitives)
(require candle)

;; Stochastic facts — momentum oscillator with cross dynamics.
(define (encode-stochastic-facts [c : Candle])
  : Vec<ThoughtAST>
  (let ((k-normalized (/ (:stoch-k c) 100.0))
        (d-normalized (/ (:stoch-d c) 100.0))
        (kd-spread (- k-normalized d-normalized)))
    (list
      ;; %K position — [0, 1]. Where in the recent range.
      (Linear "stoch-k" k-normalized 1.0)
      ;; %D position — [0, 1]. Smoothed %K.
      (Linear "stoch-d" d-normalized 1.0)
      ;; K-D spread — signed. Positive = %K above %D (bullish momentum).
      (Linear "stoch-kd-spread" kd-spread 1.0)
      ;; Stochastic cross delta — rate of change of the spread
      (Linear "stoch-cross-delta" (:stoch-cross-delta c) 1.0))))
