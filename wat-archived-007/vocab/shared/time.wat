;; time.wat — circular time facts from enriched candles.
;;
;; Depends on: candle
;; Domain: shared (any observer can use these)
;;
;; Time is circular. 23:59 is one minute from 00:00, not 1439 apart.
;; encode-circular wraps the value at the period boundary.
;;
;; The parse-* functions live in indicator-bank.wat — parsing timestamps
;; from raw candles is indicator-bank's concern. This file uses the
;; already-parsed Candle fields.

(require primitives)
(require enums)       ; ThoughtAST constructors
(require candle)

;; ── Encoding — candle in, ThoughtASTs out. Pure function. No state. ──

(define (encode-time-facts [candle : Candle])
  : Vec<ThoughtAST>
  (list
    (Circular "minute"       (:minute candle)       60.0)
    (Circular "hour"         (:hour candle)          24.0)
    (Circular "day-of-week"  (:day-of-week candle)    7.0)
    (Circular "day-of-month" (:day-of-month candle)  31.0)
    (Circular "month-of-year" (:month-of-year candle) 12.0)))
