;; vocab/market/price-action.wat — range-ratio, gaps, consecutive runs.
;;
;; Depends on: Candle, ThoughtAST.
;;
;; Pure: candle in, ASTs out. No state.
;; pa-body-ratio — the price-action body ratio atom.
;; No candle-dir signum — direction is carried by ROC and other signed scalars.

(require primitives)
(require candle)
(require enums)     ; ThoughtAST

;; ── encode-price-action-facts ───────────────────────────────────────────

(define (encode-price-action-facts [c : Candle])
  : Vec<ThoughtAST>
  (let* ((bar-range (- (:high c) (:low c)))
         (body (abs (- (:close c) (:open c))))
         (facts
           (list
             ;; Range ratio — current range / prev range. Log scale.
             ;; < 1 = compression, > 1 = expansion.
             (Log "range-ratio" (:range-ratio c))

             ;; Gap — signed, (open - prev close) / prev close
             (Linear "gap" (:gap c) 0.05)

             ;; Consecutive runs — how many candles in a row
             (Linear "consecutive-up" (:consecutive-up c) 10.0)
             (Linear "consecutive-down" (:consecutive-down c) 10.0)

             ;; Body ratio — body / range. [0, 1]. Thin body = indecision.
             (Linear "pa-body-ratio"
                     (if (> bar-range 0.0) (/ body bar-range) 0.0)
                     1.0))))
    facts))
