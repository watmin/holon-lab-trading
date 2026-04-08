;; fibonacci.wat — retracement level detection
;;
;; Depends on: candle
;; Domain: market (MarketLens :structure)
;;
;; Fibonacci retracement: where is price relative to the swing high/low?
;; The distance to each level is a signed scalar. The discriminant
;; learns which levels matter.

(require primitives)
(require candle)

;; Five retracement levels: 0.236, 0.382, 0.500, 0.618, 0.786.
;; For each level, emit the signed distance from close to that level,
;; normalized by the swing range. Positive = above level. Negative = below.
;; Also emit the overall retracement position: where is close in [swing-low, swing-high]?

(define (encode-fibonacci-facts [candles : Vec<Candle>])
  : Vec<ThoughtAST>
  (if (< (len candles) 10)
    (list)
    (let* ((swing-high (fold-left max -1e308
                         (map (lambda (c) (:high c)) candles)))
           (swing-low  (fold-left min  1e308
                         (map (lambda (c) (:low c)) candles)))
           (range      (- swing-high swing-low)))

      (if (< range 1e-10)
        (list)
        (let* ((close    (:close (last candles)))
               (retrace  (/ (- close swing-low) range))

               ;; Distance to each fib level, normalized by range
               (fib-levels (list
                 (list "fib-236" 0.236)
                 (list "fib-382" 0.382)
                 (list "fib-500" 0.500)
                 (list "fib-618" 0.618)
                 (list "fib-786" 0.786)))

               (level-facts (map (lambda (fl)
                 (let* ((name  (first fl))
                        (ratio (second fl))
                        (level (+ swing-low (* range ratio)))
                        (dist  (/ (- close level) range)))
                   (Linear name dist 1.0)))
                 fib-levels)))

          ;; Overall retracement position [0, 1]
          (append level-facts
            (list (Linear "fib-retrace-pos" retrace 1.0))))))))
