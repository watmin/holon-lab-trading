;; ── vocab/shared/time.wat ────────────────────────────────────────
;;
;; Temporal context. All circular scalars — the value wraps.
;; Any observer can use these. Pure function: candle in, ASTs out.
;; atoms: minute, hour, day-of-week, day-of-month, month-of-year
;; Depends on: candle.

(require candle)

(define (encode-time-facts [c : Candle])
  : Vec<ThoughtAST>
  (list
    ;; Minute: mod 60.
    '(Circular "minute" (:minute c) 60.0)

    ;; Hour: mod 24.
    '(Circular "hour" (:hour c) 24.0)

    ;; Day of week: mod 7. 0 = Monday.
    '(Circular "day-of-week" (:day-of-week c) 7.0)

    ;; Day of month: mod 31.
    '(Circular "day-of-month" (:day-of-month c) 31.0)

    ;; Month of year: mod 12. 1 = January.
    '(Circular "month-of-year" (:month-of-year c) 12.0)))
