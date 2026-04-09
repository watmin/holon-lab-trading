;; stochastic.wat — %K/%D position and cross dynamics
;;
;; Depends on: candle (reads: stoch-k, stoch-d, stoch-cross-delta)
;; Market domain. Lens: :momentum, :generalist.
;;
;; Position and cross — all continuous scalars.

(require primitives)

(define (encode-stochastic-facts [candle : Candle]) : Vec<ThoughtAST>
  (list
    ;; %K - %D spread — signed, indicates cross direction
    (Linear "stoch-kd-spread"
      (- (:stoch-k candle) (:stoch-d candle)) 1.0)

    ;; Stochastic cross delta — change in (%K - %D) from previous candle
    (Linear "stoch-cross-delta" (:stoch-cross-delta candle) 1.0)))
