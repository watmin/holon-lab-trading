;; fibonacci.wat — retracement level detection
;;
;; Depends on: candle
;; Domain: market (MarketLens :structure)
;;
;; Fibonacci retracement: where is price relative to the recent range?
;; Range position at multiple scales is pre-computed on the Candle.
;; The discriminant learns which scale matters.

(require primitives)
(require candle)

;; Range position at 12, 24, 48 periods — pre-computed on Candle.
;; Where is price in [low, high]? Range [0, 1].
;; Fibonacci levels are fixed fractions of range: 0.236, 0.382, 0.500,
;; 0.618, 0.786. The distance from range-pos to each level is a signed
;; scalar. The discriminant learns which levels matter.

(define (encode-fibonacci-facts [candle : Candle])
  : Vec<ThoughtAST>
  (let* ((pos (:range-pos-48 candle))
         ;; Distance from range position to each fib level
         (fib-levels (list
           (list "fib-236" 0.236)
           (list "fib-382" 0.382)
           (list "fib-500" 0.500)
           (list "fib-618" 0.618)
           (list "fib-786" 0.786)))
         (level-facts (map (lambda (fl)
           (let* ((name  (first fl))
                  (ratio (second fl))
                  (dist  (- pos ratio)))
             (Linear name dist 1.0)))
           fib-levels)))
    ;; Overall retracement position
    (append level-facts
      (list (Linear "fib-retrace-pos" pos 1.0)))))
