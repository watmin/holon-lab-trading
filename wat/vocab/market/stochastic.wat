;; vocab/market/stochastic.wat — %K/%D spread and crosses
;; Depends on: candle
;; MarketLens :momentum selects this module.

(require primitives)
(require candle)

(define (encode-stochastic-facts [c : Candle])
  : Vec<ThoughtAST>
  (list
    ;; %K position — [0, 100] normalized to [0, 1]
    (Linear "stoch-k" (/ (:stoch-k c) 100.0) 1.0)

    ;; %D position — [0, 100] normalized to [0, 1]
    (Linear "stoch-d" (/ (:stoch-d c) 100.0) 1.0)

    ;; K-D spread — signed, the cross signal
    (Linear "stoch-kd-spread" (/ (- (:stoch-k c) (:stoch-d c)) 100.0) 1.0)

    ;; Cross delta — change in K-D spread from previous candle
    (Linear "stoch-cross-delta" (:stoch-cross-delta c) 0.1)))
