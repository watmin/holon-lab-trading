;; price-action.wat — candle structure and patterns
;;
;; Depends on: candle (reads: open, high, low, close, atr,
;;                            range-ratio, gap, consecutive-up, consecutive-down)
;; Market domain. Lens: :structure, :generalist.
;;
;; pa- prefix for price-action atoms. Body ratio, wicks, range compression.

(require primitives)

(define (encode-price-action-facts [candle : Candle]) : Vec<ThoughtAST>
  (let ((open  (:open candle))
        (high  (:high candle))
        (low   (:low candle))
        (close (:close candle))
        (range (- high low))
        (body  (abs (- close open))))
    (list
      ;; Body ratio — body / range. 1.0 = no wicks, 0.0 = all wick (doji)
      (Linear "pa-body-ratio"
        (if (> range 0.0) (/ body range) 0.0) 1.0)

      ;; Upper wick ratio — upper wick / range
      (Linear "pa-upper-wick"
        (if (> range 0.0) (/ (- high (max open close)) range) 0.0) 1.0)

      ;; Lower wick ratio — lower wick / range
      (Linear "pa-lower-wick"
        (if (> range 0.0) (/ (- (min open close) low) range) 0.0) 1.0)

      ;; Range ratio — current range / prev range. Unbounded positive.
      (Log "pa-range-ratio" (:range-ratio candle))

      ;; Gap — signed, (open - prev close) / prev close
      (Linear "pa-gap" (:gap candle) 0.05)

      ;; Consecutive runs — how many in a row
      (Linear "pa-consecutive-up"   (:consecutive-up candle)   20.0)
      (Linear "pa-consecutive-down" (:consecutive-down candle) 20.0))))
