;; ── vocab/market/fibonacci.wat ───────────────────────────────────
;;
;; Retracement level distances. Pure function: candle in, ASTs out.
;; atoms: range-pos-12, range-pos-24, range-pos-48,
;;        fib-dist-236, fib-dist-382, fib-dist-500, fib-dist-618, fib-dist-786
;; Depends on: candle.
;; MarketLens :structure selects this module.

(require candle)

(define (encode-fibonacci-facts [c : Candle])
  : Vec<ThoughtAST>
  (let ((pos12 (:range-pos-12 c))
        (pos24 (:range-pos-24 c))
        (pos48 (:range-pos-48 c)))
    (list
      ;; Range position at each timeframe — Linear [0, 1]
      '(Linear "range-pos-12" pos12 1.0)
      '(Linear "range-pos-24" pos24 1.0)
      '(Linear "range-pos-48" pos48 1.0)

      ;; Distance from key Fibonacci levels (using 48-period range)
      ;; Signed: positive = above the level, negative = below.
      '(Linear "fib-dist-236" (- pos48 0.236) 1.0)
      '(Linear "fib-dist-382" (- pos48 0.382) 1.0)
      '(Linear "fib-dist-500" (- pos48 0.500) 1.0)
      '(Linear "fib-dist-618" (- pos48 0.618) 1.0)
      '(Linear "fib-dist-786" (- pos48 0.786) 1.0))))
