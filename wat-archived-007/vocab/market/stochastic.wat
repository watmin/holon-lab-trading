;; stochastic.wat — %K/%D zones and crosses
;;
;; Depends on: candle
;; Domain: market (MarketLens :momentum)
;;
;; Stochastic oscillator: where is price relative to its recent range?
;; %K = raw position. %D = smoothed. All pre-computed on Candle.

(require primitives)
(require enums)       ; ThoughtAST constructors
(require candle)

;; %K and %D — pre-computed on Candle. Range [0, 100].
;; Normalized to [0, 1].
;;
;; K-D spread: (stoch-k - stoch-d) / 100. Signed.
;; Positive = %K above %D (bullish momentum). Negative = bearish.
;;
;; Stoch cross delta — pre-computed on Candle. Signed.
;; Change in (%K - %D) from previous candle.
;; Positive = K-D spread widening bullishly. Negative = narrowing or bearish.

(define (encode-stochastic-facts [candle : Candle])
  : Vec<ThoughtAST>
  (let* ((sk (/ (:stoch-k candle) 100.0))
         (sd (/ (:stoch-d candle) 100.0))
         (kd-spread (- sk sd))
         (cross-delta (:stoch-cross-delta candle)))
    (list
      (Linear "stoch-k" sk 1.0)
      (Linear "stoch-d" sd 1.0)
      (Linear "stoch-kd-spread" kd-spread 1.0)
      (Linear "stoch-cross-delta" cross-delta 1.0))))
