;; vocab/market/keltner.wat — channel position, BB position, squeeze
;; Depends on: candle
;; MarketLens :structure selects this module.

(require primitives)
(require candle)

(define (encode-keltner-facts [c : Candle])
  : Vec<ThoughtAST>
  (let ((kp (:kelt-pos c))
        (bp (:bb-pos c))
        (sq (:squeeze c)))
    (append
      ;; Keltner channel position — [0, 1] when inside, beyond when outside
      (if (and (>= kp 0.0) (<= kp 1.0))
        ;; Inside Keltner channel
        (list (Linear "kelt-position" kp 1.0))
        ;; Outside Keltner channel — how far beyond
        (if (> kp 1.0)
          (list (Log "kelt-breakout-upper" (max (- kp 1.0) 0.001)))
          (list (Log "kelt-breakout-lower" (max (- 0.0 kp) 0.001)))))

      ;; Bollinger position — conditional on inside/outside
      (if (and (>= bp 0.0) (<= bp 1.0))
        (list (Linear "bb-position" bp 1.0))
        (if (> bp 1.0)
          (list (Log "bb-breakout-upper" (max (- bp 1.0) 0.001)))
          (list (Log "bb-breakout-lower" (max (- 0.0 bp) 0.001)))))

      ;; Squeeze — BB width / Keltner width. <1 = squeezed, >1 = expanded
      (list
        (Linear "squeeze" sq 2.0)
        ;; Bollinger bandwidth as log ratio
        (Log "bb-width" (max (:bb-width c) 0.001))))))
