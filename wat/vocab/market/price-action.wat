;; vocab/market/price-action.wat — range-ratio, gaps, consecutive runs
;; Depends on: candle.wat
;; Domain: market — direction signal
;; Lens: :structure

(require primitives)
(require candle)

(define (encode-price-action-facts [c : Candle])
  : Vec<ThoughtAST>
  (let ((range-ratio (:range-ratio c))
        (gap (:gap c))
        (consec-up (:consecutive-up c))
        (consec-down (:consecutive-down c)))
    (list
      ;; Range ratio — compression vs expansion. Log because ratio.
      (Log "range-ratio" (max range-ratio 0.001))

      ;; Gap — signed distance from prev close to open
      (Linear "gap" gap 0.05)

      ;; Consecutive runs — how long the streak is
      (Linear "consecutive-up" (min consec-up 10.0) 10.0)
      (Linear "consecutive-down" (min consec-down 10.0) 10.0)

      ;; Net streak — signed. Positive = bullish streak
      (Linear "streak-net" (- consec-up consec-down) 10.0))))
