;; time.wat — time parsing utilities and circular time facts
;;
;; Depends on: candle
;; Domain: shared (any observer can use these)
;;
;; Time is circular. 23:59 is one minute from 00:00, not 1439 apart.
;; encode-circular wraps the value at the period boundary.
;;
;; The parse-* functions extract temporal components from timestamp
;; strings ("YYYY-MM-DD HH:MM:SS"). Used by indicator-bank.wat to
;; populate Candle fields, and by encode-time-facts to produce ASTs.

(require primitives)
(require enums)       ; ThoughtAST constructors
(require candle)

;; ── Time parsing — extract temporal components from timestamp string ──

(define (parse-minute [ts : String])
  : f64
  ; Extract minute from "YYYY-MM-DD HH:MM:SS" → float.
  (+ (substring ts 14 16) 0.0))

(define (parse-hour [ts : String])
  : f64
  ; Extract hour from "YYYY-MM-DD HH:MM:SS" → float.
  (+ (substring ts 11 13) 0.0))

(define (parse-day-of-week [ts : String])
  : f64
  ; Tomohiko Sakamoto's algorithm. 0 = Sunday.
  (let* ((y (+ (substring ts 0 4) 0))
         (m (+ (substring ts 5 7) 0))
         (d (+ (substring ts 8 10) 0))
         (t (list 0 3 2 5 0 3 5 1 4 6 2 4))
         (y2 (if (< m 3) (- y 1) y)))
    (+ (mod (+ y2 (/ y2 4) (- (/ y2 100)) (/ y2 400)
               (nth t (- m 1)) d)
            7)
       0.0)))

(define (parse-day-of-month [ts : String])
  : f64
  (+ (substring ts 8 10) 0.0))

(define (parse-month [ts : String])
  : f64
  (+ (substring ts 5 7) 0.0))

;; ── Encoding — candle in, ThoughtASTs out. Pure function. No state. ──

(define (encode-time-facts [candle : Candle])
  : Vec<ThoughtAST>
  (list
    (Circular "minute"       (:minute candle)       60.0)
    (Circular "hour"         (:hour candle)          24.0)
    (Circular "day-of-week"  (:day-of-week candle)    7.0)
    (Circular "day-of-month" (:day-of-month candle)  31.0)
    (Circular "month-of-year" (:month-of-year candle) 12.0)))
