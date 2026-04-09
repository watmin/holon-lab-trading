;; vocab/market/keltner.wat — channel position, BB position, squeeze
;; Depends on: candle.wat
;; Domain: market — direction signal
;; Lens: :structure

(require primitives)
(require candle)

(define (encode-keltner-facts [c : Candle])
  : Vec<ThoughtAST>
  (let ((kelt-pos (:kelt-pos c))
        (bb-pos (:bb-pos c))
        (bb-width (:bb-width c))
        (squeeze (:squeeze c)))
    ;; Conditional: inside vs outside bands
    (let ((facts '()))
      ;; Bollinger position — where in the bands
      (if (and (>= bb-pos 0.0) (<= bb-pos 1.0))
        ;; Inside bands — linear position
        (set! facts (append facts (list (Linear "bb-position" bb-pos 1.0))))
        ;; Outside bands — how far beyond (log)
        (if (> bb-pos 1.0)
          (set! facts (append facts (list (Log "bb-breakout-upper" (+ 1.0 (- bb-pos 1.0))))))
          (set! facts (append facts (list (Log "bb-breakout-lower" (+ 1.0 (abs bb-pos))))))))

      ;; Keltner position
      (if (and (>= kelt-pos 0.0) (<= kelt-pos 1.0))
        (set! facts (append facts (list (Linear "kelt-position" kelt-pos 1.0))))
        (if (> kelt-pos 1.0)
          (set! facts (append facts (list (Log "kelt-breakout-upper" (+ 1.0 (- kelt-pos 1.0))))))
          (set! facts (append facts (list (Log "kelt-breakout-lower" (+ 1.0 (abs kelt-pos))))))))

      ;; BB width — volatility breadth
      (set! facts (append facts (list (Log "bb-width" (+ 1.0 bb-width)))))

      ;; Squeeze — BB/Keltner ratio. < 1.0 = squeezed
      (set! facts (append facts (list (Linear "squeeze" squeeze 2.0))))

      facts)))
