;; vocab/market/fibonacci.wat — retracement level detection
;; Depends on: candle
;; MarketLens :structure uses this module.

(require primitives)
(require candle)

;; Fibonacci retracement: where is the current price relative to
;; the recent range? The range positions at different horizons
;; are the Fibonacci levels — the percentage of retracement.
;; 0.0 = at the low, 1.0 = at the high.
;; Key levels: 0.236, 0.382, 0.500, 0.618, 0.786
;; The vocabulary emits the raw position and distances to key levels.

(define (encode-fibonacci-facts [c : Candle])
  : Vec<ThoughtAST>
  (let ((pos-12 (:range-pos-12 c))
        (pos-24 (:range-pos-24 c))
        (pos-48 (:range-pos-48 c))
        ;; Distances to key Fibonacci levels (signed)
        (fib-levels '(0.236 0.382 0.500 0.618 0.786))
        (dist-to-nearest (lambda (pos)
                           (fold (lambda (best lvl)
                                   (let ((d (abs (- pos lvl))))
                                     (if (< d (abs best)) (- pos lvl) best)))
                                 1.0
                                 fib-levels))))
    (list
      ;; Range positions as raw values
      (Linear "range-pos-12" pos-12 1.0)
      (Linear "range-pos-24" pos-24 1.0)
      (Linear "range-pos-48" pos-48 1.0)
      ;; Distance to nearest Fibonacci level — signed
      (Linear "fib-distance-12" (dist-to-nearest pos-12) 1.0)
      (Linear "fib-distance-24" (dist-to-nearest pos-24) 1.0)
      (Linear "fib-distance-48" (dist-to-nearest pos-48) 1.0))))
