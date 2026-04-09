;; vocab/market/fibonacci.wat — retracement level detection
;; Depends on: candle.wat
;; Domain: market — direction signal
;; Lens: :structure

(require primitives)
(require candle)

;; Fibonacci retracement levels: 0.236, 0.382, 0.500, 0.618, 0.786
;; The vocabulary emits the distance from the nearest fib level.

(define (encode-fibonacci-facts [c : Candle])
  : Vec<ThoughtAST>
  (let ((range-12 (:range-pos-12 c))
        (range-24 (:range-pos-24 c))
        (range-48 (:range-pos-48 c))
        ;; Fib levels in the [0, 1] range position space
        (fib-levels '(0.236 0.382 0.500 0.618 0.786))
        ;; Distance to nearest fib for each range
        (nearest-fn (lambda (pos)
          (fold (lambda (best lvl)
            (let ((dist (abs (- pos lvl))))
              (if (< dist (abs best)) (- pos lvl) best)))
            1.0 fib-levels))))
    (list
      ;; Distance to nearest fib level — signed, short window
      (Linear "fib-dist-12" (nearest-fn range-12) 1.0)

      ;; Distance to nearest fib level — medium window
      (Linear "fib-dist-24" (nearest-fn range-24) 1.0)

      ;; Distance to nearest fib level — long window
      (Linear "fib-dist-48" (nearest-fn range-48) 1.0)

      ;; Range position as a direct fact (context)
      (Linear "range-pos-12" range-12 1.0)
      (Linear "range-pos-24" range-24 1.0)
      (Linear "range-pos-48" range-48 1.0))))
