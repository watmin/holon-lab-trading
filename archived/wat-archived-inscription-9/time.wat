;; vocab/shared/time.wat — universal time context
;; Depends on: candle
;; Any observer can use these. Circular scalars that wrap.

(require primitives)
(require candle)

;; Encode time facts from a candle.
;; minute (mod 60), hour (mod 24), day-of-week (mod 7),
;; day-of-month (mod 31), month-of-year (mod 12).
(define (encode-time-facts [c : Candle])
  : Vec<ThoughtAST>
  (list
    (Circular "minute" (:minute c) 60.0)
    (Circular "hour" (:hour c) 24.0)
    (Circular "day-of-week" (:day-of-week c) 7.0)
    (Circular "day-of-month" (:day-of-month c) 31.0)
    (Circular "month-of-year" (:month-of-year c) 12.0)))
