;; ── vocab/fibonacci.wat — Fibonacci retracement levels ──────────
;;
;; Computes proximity to fib levels using the viewport swing high/low.
;; Window-dependent — swing range is the observer's window,
;; not pre-computed on Candle.
;;
;; Lens: structure

(require facts)

(define (eval-fibonacci candles)
  "Fibonacci proximity facts. Returns None if < 10 candles or degenerate range."
  (when (>= (len candles) 10)
    (let ((swing-high (fold max (first (map :high candles)) (rest (map :high candles))))
          (swing-low  (fold min (first (map :low candles))  (rest (map :low candles))))
          (range      (- swing-high swing-low)))
      (when (> range 1e-10)
        (let ((now   (last candles))
              (close (:close now))
              (atr   (* (:atr-r now) close)))
          (fold-left
            (lambda (facts pair)
              (let ((name  (first pair))
                    (ratio (second pair))
                    (level (+ swing-low (* range ratio))))
                (append facts
                  ;; Proximity — touches when within half an ATR
                  (if (< (abs (- close level)) (* atr 0.5))
                      (list (fact/comparison "touches" "close" name))
                      (list))
                  ;; Position — above or below
                  (list (fact/comparison (if (> close level) "above" "below")
                                        "close" name)))))
            (list)
            [("fib-236" 0.236) ("fib-382" 0.382) ("fib-500" 0.500)
             ("fib-618" 0.618) ("fib-786" 0.786)]))))))

;; ── What fibonacci does NOT do ─────────────────────────────────
;; - Does NOT pre-compute levels (they depend on the observer's window)
;; - Does NOT detect swings explicitly (uses window min/max)
;; - Does NOT emit scalars (proximity is binary: touches or positional)
;; - Pure function. Candles in, facts out.
