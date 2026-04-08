;; stochastic.wat — %K/%D zones and crosses
;;
;; Depends on: candle
;; Domain: market (MarketLens :momentum)
;;
;; Stochastic oscillator: where is price relative to its recent range?
;; %K = raw position. %D = smoothed. Cross = momentum shift.

(require primitives)
(require candle)

;; %K and %D — pre-computed on Candle. Range [0, 100].
;; Normalized to [0, 1].
;;
;; K-D spread: (stoch-k - stoch-d) / 100. Signed.
;; Positive = %K above %D (bullish momentum). Negative = bearish.
;;
;; K-D cross: delta of spread from previous candle.

(define (encode-stochastic-facts [candle : Candle]
                                 [candles : Vec<Candle>])
  : Vec<ThoughtAST>
  (let* ((sk (/ (:stoch-k candle) 100.0))
         (sd (/ (:stoch-d candle) 100.0))
         (kd-spread (- sk sd))

         (facts (list
                  (Linear "stoch-k" sk 1.0)
                  (Linear "stoch-d" sd 1.0)
                  (Linear "stoch-kd-spread" kd-spread 1.0))))

    ;; Cross detection — requires previous candle
    (if (>= (len candles) 2)
      (let* ((prev      (nth candles (- (len candles) 2)))
             (prev-k    (/ (:stoch-k prev) 100.0))
             (prev-d    (/ (:stoch-d prev) 100.0))
             (prev-spread (- prev-k prev-d))
             (cross-delta (- kd-spread prev-spread)))
        (append facts (list (Linear "stoch-cross" cross-delta 1.0))))
      facts)))
