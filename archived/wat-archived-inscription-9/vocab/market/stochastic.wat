;; vocab/market/stochastic.wat — %K/%D spread and crosses
;; Depends on: candle
;; MarketLens :momentum uses this module.

(require primitives)
(require candle)

(define (encode-stochastic-facts [c : Candle])
  : Vec<ThoughtAST>
  (list
    ;; %K value — [0, 1]
    (Linear "stoch-k" (:stoch-k c) 1.0)
    ;; %D value — [0, 1]
    (Linear "stoch-d" (:stoch-d c) 1.0)
    ;; K-D spread — signed, positive = K above D (bullish)
    (Linear "stoch-kd-spread" (- (:stoch-k c) (:stoch-d c)) 1.0)
    ;; Cross delta — change in K-D spread from previous candle
    (Linear "stoch-cross-delta" (:stoch-cross-delta c) 1.0)))
