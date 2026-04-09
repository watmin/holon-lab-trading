;; vocab/market/fibonacci.wat — retracement level detection
;; Depends on: candle
;; MarketLens :structure selects this module.

(require primitives)
(require candle)

;; Fibonacci retracement — where is price in the recent swing?
;; Uses range-pos at multiple timeframes as proxy for Fibonacci levels.
;; The key Fibonacci ratios (0.236, 0.382, 0.500, 0.618, 0.786) are
;; natural boundaries in price retracements. We emit the distance from
;; each level — the discriminant learns which matter.
(define (encode-fibonacci-facts [c : Candle])
  : Vec<ThoughtAST>
  (let ((pos12 (:range-pos-12 c))
        (pos24 (:range-pos-24 c))
        (pos48 (:range-pos-48 c)))
    (list
      ;; Range position at each timeframe — [0, 1]
      (Linear "fib-range-pos-12" pos12 1.0)
      (Linear "fib-range-pos-24" pos24 1.0)
      (Linear "fib-range-pos-48" pos48 1.0)

      ;; Distance from key Fibonacci levels (using 48-period range)
      ;; Signed: positive = above the level.
      (Linear "fib-dist-236" (- pos48 0.236) 1.0)
      (Linear "fib-dist-382" (- pos48 0.382) 1.0)
      (Linear "fib-dist-500" (- pos48 0.500) 1.0)
      (Linear "fib-dist-618" (- pos48 0.618) 1.0)
      (Linear "fib-dist-786" (- pos48 0.786) 1.0))))
