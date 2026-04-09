;; fibonacci.wat — retracement level detection
;;
;; Depends on: candle (reads: range-pos-12, range-pos-24, range-pos-48)
;; Market domain. Lens: :structure, :generalist.
;;
;; Range position as a proxy for Fibonacci retracement levels.
;; Where price sits in the recent range — [0, 1]. Near 0.382, 0.5, 0.618
;; the discriminant learns whether those levels matter.

(require primitives)

(define (encode-fibonacci-facts [candle : Candle]) : Vec<ThoughtAST>
  (list
    ;; Range position — [0, 1] — where in the N-period range
    (Linear "fib-range-pos-12" (:range-pos-12 candle) 1.0)
    (Linear "fib-range-pos-24" (:range-pos-24 candle) 1.0)
    (Linear "fib-range-pos-48" (:range-pos-48 candle) 1.0)))
