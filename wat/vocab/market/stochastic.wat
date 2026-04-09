;; vocab/market/stochastic.wat — %K/%D spread and crosses
;; Depends on: candle
;; MarketLens :momentum selects this module.

(require primitives)
(require candle)

;; Stochastic facts — %K, %D, their spread and cross dynamics.
;; %K: [0, 100] → [0, 1]. The raw oscillator.
;; %D: [0, 100] → [0, 1]. The smoothed signal.
;; The cross delta is the rate of change of the spread — momentum of momentum.
(define (encode-stochastic-facts [c : Candle])
  : Vec<ThoughtAST>
  (list
    ;; %K position — [0, 1]
    (Linear "stoch-k" (/ (:stoch-k c) 100.0) 1.0)

    ;; %D position — [0, 1]
    (Linear "stoch-d" (/ (:stoch-d c) 100.0) 1.0)

    ;; K-D spread — signed. Positive = %K above %D.
    (Linear "stoch-kd-spread"
      (/ (- (:stoch-k c) (:stoch-d c)) 100.0)
      1.0)

    ;; Cross delta — signed change in (K - D) from prev candle.
    ;; Positive = spread widening (bullish), negative = narrowing.
    (Linear "stoch-cross-delta" (:stoch-cross-delta c) 0.1)))
