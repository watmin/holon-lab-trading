;; vocab/market/fibonacci.wat — retracement level detection
;; Depends on: candle
;; MarketLens :structure uses this.

(require primitives)
(require candle)

;; Fibonacci facts — where is price relative to key retracement levels?
;; Uses the 48-period range position as the swing proxy.
;; Each fib level is a signed distance from the level.
(define (encode-fibonacci-facts [c : Candle])
  : Vec<ThoughtAST>
  (let ((range-pos (:range-pos-48 c))
        ;; Fibonacci levels as positions in [0, 1] range
        (fib-236 0.236)
        (fib-382 0.382)
        (fib-500 0.500)
        (fib-618 0.618)
        (fib-786 0.786))
    (list
      ;; Signed distance from each fib level. Positive = above, negative = below.
      (Linear "fib-236-distance" (- range-pos fib-236) 1.0)
      (Linear "fib-382-distance" (- range-pos fib-382) 1.0)
      (Linear "fib-500-distance" (- range-pos fib-500) 1.0)
      (Linear "fib-618-distance" (- range-pos fib-618) 1.0)
      (Linear "fib-786-distance" (- range-pos fib-786) 1.0)
      ;; Overall range position — where in the swing
      (Linear "range-pos-48" range-pos 1.0))))
