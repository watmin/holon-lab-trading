;; vocab/shared/time.wat — universal time context.
;;
;; Depends on: Candle, ThoughtAST.
;;
;; Circular scalars that wrap. Any observer can use these.
;; minute (mod 60), hour (mod 24), day-of-week (mod 7),
;; day-of-month (mod 31), month-of-year (mod 12).

(require primitives)
(require candle)
(require enums)     ; ThoughtAST

;; ── encode-time-facts — circular time scalars ───────────────────────────
;;
;; Every lens gets time facts. The reckoner learns which hours,
;; which days matter. The circular encoding wraps — 23:00 is close
;; to 00:00 in vector space.

(define (encode-time-facts [c : Candle])
  : Vec<ThoughtAST>
  (list
    (Circular "minute"       (:minute c)       60.0)
    (Circular "hour"         (:hour c)         24.0)
    (Circular "day-of-week"  (:day-of-week c)   7.0)
    (Circular "day-of-month" (:day-of-month c) 31.0)
    (Circular "month"        (:month-of-year c) 12.0)))
