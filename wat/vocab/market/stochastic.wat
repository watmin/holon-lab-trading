;; vocab/market/stochastic.wat — %K/%D spread and crosses
;; Depends on: candle.wat
;; Domain: market — direction signal
;; Lens: :momentum

(require primitives)
(require candle)

(define (encode-stochastic-facts [c : Candle])
  : Vec<ThoughtAST>
  (let ((k (/ (:stoch-k c) 100.0))
        (d (/ (:stoch-d c) 100.0))
        (spread (- k d))
        (cross-delta (/ (:stoch-cross-delta c) 100.0)))
    (list
      ;; %K position — [0, 100] normalized to [0, 1]
      (Linear "stoch-k" k 1.0)

      ;; %D position — smoothed %K
      (Linear "stoch-d" d 1.0)

      ;; K-D spread — signed. Positive = %K above %D (bullish)
      (Linear "stoch-spread" spread 1.0)

      ;; Cross delta — velocity of K-D spread change
      (Linear "stoch-cross-delta" cross-delta 1.0))))
