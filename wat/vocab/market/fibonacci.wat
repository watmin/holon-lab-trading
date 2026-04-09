;; vocab/market/fibonacci.wat — retracement level detection
;; Depends on: candle
;; MarketLens :structure selects this module.

(require primitives)
(require candle)

;; Fibonacci levels as distance from close to key range positions.
;; The range-pos fields give us [0, 1] position within various windows.
;; Fibonacci levels: 0.236, 0.382, 0.500, 0.618, 0.786
;; Emit signed distance from each level — how far from the retracement.
(define (encode-fibonacci-facts [c : Candle])
  : Vec<ThoughtAST>
  (let ((pos (:range-pos-48 c))  ; use 48-period range as the swing
        ;; Distances from Fibonacci levels (signed: positive = above, negative = below)
        (d-236 (- pos 0.236))
        (d-382 (- pos 0.382))
        (d-500 (- pos 0.500))
        (d-618 (- pos 0.618))
        (d-786 (- pos 0.786)))
    (list
      (Linear "fib-236-distance" d-236 1.0)
      (Linear "fib-382-distance" d-382 1.0)
      (Linear "fib-500-distance" d-500 1.0)
      (Linear "fib-618-distance" d-618 1.0)
      (Linear "fib-786-distance" d-786 1.0)

      ;; Range position itself — where in the swing
      (Linear "range-pos-48" pos 1.0))))
