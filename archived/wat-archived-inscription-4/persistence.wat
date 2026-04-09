;; persistence.wat — memory and trending character of the series
;;
;; Depends on: candle (reads: hurst, autocorrelation, adx)
;; Market domain. Lens: :regime, :generalist.
;;
;; Hurst exponent, autocorrelation, ADX strength — all continuous.

(require primitives)

(define (encode-persistence-facts [candle : Candle]) : Vec<ThoughtAST>
  (list
    ;; Hurst exponent — [0, 1]. 0.5 = random walk, >0.5 = trending, <0.5 = mean-reverting
    (Linear "hurst" (:hurst candle) 1.0)

    ;; Autocorrelation — [-1, 1]. Lag-1 signed.
    (Linear "autocorrelation" (:autocorrelation candle) 1.0)

    ;; ADX — [0, 100]. Trend strength regardless of direction.
    (Linear "adx" (:adx candle) 100.0)))
