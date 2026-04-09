;; vocab/market/keltner.wat — channel position, BB position, squeeze
;; Depends on: candle
;; MarketLens :structure uses this.

(require primitives)
(require candle)

;; Keltner channel facts — volatility envelope around EMA.
;; The vocabulary is conditional: inside the bands OR beyond them, not both.
(define (encode-keltner-facts [c : Candle])
  : Vec<ThoughtAST>
  (let ((bb-pos (:bb-pos c))
        (kelt-pos (:kelt-pos c))
        (squeeze (:squeeze c))
        (facts '()))
    ;; Bollinger position — conditional on inside/outside
    (cond
      ((and (>= bb-pos 0.0) (<= bb-pos 1.0))
        ;; Inside the bands — linear position
        (set! facts (append facts
          (list (Linear "bb-position" (- (* 2.0 bb-pos) 1.0) 1.0)))))
      ((> bb-pos 1.0)
        ;; Above upper band — how far beyond (log)
        (set! facts (append facts
          (list (Log "bb-breakout-upper" (max 0.001 (- bb-pos 1.0)))))))
      (else
        ;; Below lower band — how far beyond (log)
        (set! facts (append facts
          (list (Log "bb-breakout-lower" (max 0.001 (abs bb-pos))))))))
    ;; Keltner position — same treatment
    (cond
      ((and (>= kelt-pos 0.0) (<= kelt-pos 1.0))
        (set! facts (append facts
          (list (Linear "kelt-position" (- (* 2.0 kelt-pos) 1.0) 1.0)))))
      ((> kelt-pos 1.0)
        (set! facts (append facts
          (list (Log "kelt-breakout-upper" (max 0.001 (- kelt-pos 1.0)))))))
      (else
        (set! facts (append facts
          (list (Log "kelt-breakout-lower" (max 0.001 (abs kelt-pos))))))))
    ;; Squeeze — BB width / Keltner width. < 1 = BB inside Keltner (compression).
    (set! facts (append facts
      (list (Log "squeeze" (max 0.001 squeeze)))))
    ;; Bollinger width — raw measure of volatility relative to price
    (set! facts (append facts
      (list (Log "bb-width" (max 0.001 (:bb-width c))))))
    facts))
