;; time.wat — circular time facts
;;
;; Depends on: candle
;; Domain: shared (any observer can use these)
;;
;; Time is circular. 23:59 is one minute from 00:00, not 1439 apart.
;; encode-circular wraps the value at the period boundary.

(require primitives)
(require candle)

;; Interface: candle in, ThoughtASTs out. Pure function. No state.

(define (encode-time-facts [candle : Candle])
  : Vec<ThoughtAST>
  (list
    (Circular "minute"       (:minute candle)       60.0)
    (Circular "hour"         (:hour candle)          24.0)
    (Circular "day-of-week"  (:day-of-week candle)    7.0)
    (Circular "day-of-month" (:day-of-month candle)  31.0)
    (Circular "month-of-year" (:month-of-year candle) 12.0)))
