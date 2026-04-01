;; ── vocab/momentum.wat — CCI zone detection ─────────────────────
;;
;; The simplest vocab module. Reads pre-computed CCI from Candle.
;; One indicator, two zones. That's it.
;;
;; Profile: momentum

(require facts)

(define (eval-momentum candles)
  "CCI zone facts."
  (let ((now (last candles))
        (cci (:cci now)))
    (cond
      ((> cci 100.0)  (list (fact/zone "cci" "cci-overbought")))
      ((< cci -100.0) (list (fact/zone "cci" "cci-oversold")))
      (else (list)))))

;; ── What momentum does NOT do ──────────────────────────────────
;; - Does NOT compute CCI (pre-computed on Candle)
;; - Does NOT emit scalars (just zones — the value is binary signal)
;; - Does NOT check ROC (that's oscillators.wat)
;; - Pure function. Candles in, facts out.
