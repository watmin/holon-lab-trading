;; ── vocab/market/price-action.wat ────────────────────────────────
;;
;; Candlestick anatomy, range, gaps. Pure function: candle in, ASTs out.
;; atoms: range-ratio, gap, consecutive-up, consecutive-down,
;;        body-ratio-pa, upper-wick, lower-wick
;; Depends on: candle.

(require candle)

(define (encode-price-action-facts [c : Candle])
  : Vec<ThoughtAST>
  (let ((range (- (:high c) (:low c)))
        (body  (abs (- (:close c) (:open c))))
        (upper-wick (- (:high c) (max (:open c) (:close c))))
        (lower-wick (- (min (:open c) (:close c)) (:low c))))
    (list
      ;; Range ratio: current range / previous range. Unbounded positive.
      ;; Compression vs expansion. Log-encoded.
      '(Log "range-ratio" (max 0.001 (:range-ratio c)))

      ;; Gap: open vs previous close as percentage of price. Signed.
      ;; Typically small. Linear with scale 0.05 (5%).
      '(Linear "gap" (clamp (/ (:gap c) 0.05) -1.0 1.0) 1.0)

      ;; Consecutive up candles: count. Log-encoded (unbounded positive integer).
      '(Log "consecutive-up" (max 1.0 (+ 1.0 (:consecutive-up c))))

      ;; Consecutive down candles: count. Log-encoded.
      '(Log "consecutive-down" (max 1.0 (+ 1.0 (:consecutive-down c))))

      ;; Body ratio (price-action): |body| / range. [0, 1].
      '(Linear "body-ratio-pa"
               (if (> range 0.0)
                   (/ body range)
                   0.0)
               1.0)

      ;; Upper wick: upper-wick / range. [0, 1]. Rejection from highs.
      '(Linear "upper-wick"
               (if (> range 0.0)
                   (/ upper-wick range)
                   0.0)
               1.0)

      ;; Lower wick: lower-wick / range. [0, 1]. Rejection from lows.
      '(Linear "lower-wick"
               (if (> range 0.0)
                   (/ lower-wick range)
                   0.0)
               1.0))))
