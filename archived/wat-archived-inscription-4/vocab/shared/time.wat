;; time.wat — circular temporal scalars
;;
;; Depends on: candle (reads: minute, hour, day-of-week, day-of-month, month-of-year)
;; Shared — any observer can use these.

(require primitives)

(define (encode-time-facts [candle : Candle]) : Vec<ThoughtAST>
  (list
    (Circular "minute"       (:minute candle)       60.0)
    (Circular "hour"         (:hour candle)         24.0)
    (Circular "day-of-week"  (:day-of-week candle)   7.0)
    (Circular "day-of-month" (:day-of-month candle) 31.0)
    (Circular "month"        (:month-of-year candle) 12.0)))
