;; vocab/market/keltner.wat — channel position, BB position, squeeze
;; Depends on: candle
;; MarketLens :structure uses this module.

(require primitives)
(require candle)

(define (encode-keltner-facts [c : Candle])
  : Vec<ThoughtAST>
  (let ((kelt-pos (:kelt-pos c))
        (bb-pos (:bb-pos c))
        (squeeze (:squeeze c)))
    (append
      (list
        ;; Keltner position — where in the channel [0, 1]
        (Linear "kelt-pos" kelt-pos 1.0)
        ;; Bollinger position — where in the bands [0, 1]
        (Linear "bb-pos" bb-pos 1.0)
        ;; Squeeze — BB width / Keltner width ratio
        ;; < 1 means BB inside Keltner = squeeze
        (Log "squeeze" (max 0.001 squeeze)))

      ;; Conditional: beyond the bands or inside
      (cond
        ;; Beyond upper Bollinger band
        ((> bb-pos 1.0)
          (list (Log "bb-breakout-upper" (+ 1.0 (- bb-pos 1.0)))))
        ;; Beyond lower Bollinger band
        ((< bb-pos 0.0)
          (list (Log "bb-breakout-lower" (+ 1.0 (abs bb-pos)))))
        ;; Inside bands — just position
        (else '()))

      ;; Bollinger width — how volatile is the market
      (list (Log "bb-width" (max 0.001 (:bb-width c)))))))
