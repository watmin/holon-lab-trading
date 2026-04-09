;; vocab/market/keltner.wat — channel position, BB position, squeeze
;; Depends on: candle
;; MarketLens :structure selects this module.

(require primitives)
(require candle)

;; Keltner channel and Bollinger squeeze facts.
;; Channel position: where is price relative to the channel?
;; Squeeze: how compressed is volatility? BB inside Keltner = squeeze.
(define (encode-keltner-facts [c : Candle])
  : Vec<ThoughtAST>
  (let ((close (:close c)))
    (list
      ;; Keltner position — [0, 1] when inside channel.
      ;; Can be <0 or >1 when price breaks out.
      (Linear "kelt-pos" (:kelt-pos c) 1.0)

      ;; Bollinger position — [0, 1] inside bands.
      (Linear "bb-pos" (:bb-pos c) 1.0)

      ;; Bollinger width — how wide are the bands relative to price?
      ;; Log because width is a ratio.
      (Log "bb-width" (max 0.001 (:bb-width c)))

      ;; Squeeze ratio — bb-width / kelt-width. < 1.0 = BB inside Keltner = squeeze.
      ;; Log because it's a ratio of ratios.
      (Log "squeeze" (max 0.01 (:squeeze c)))

      ;; Distance from Keltner upper — signed, as fraction of price.
      (Linear "kelt-upper-dist"
        (if (= close 0.0) 0.0
          (/ (- close (:kelt-upper c)) close))
        0.1)

      ;; Distance from Keltner lower — signed, as fraction of price.
      (Linear "kelt-lower-dist"
        (if (= close 0.0) 0.0
          (/ (- close (:kelt-lower c)) close))
        0.1)

      ;; Conditional breakout facts — beyond bands
      ;; Above upper Bollinger
      (if (> close (:bb-upper c))
        (Log "bb-breakout-upper"
          (max 0.01 (if (= close 0.0) 0.01
            (/ (- close (:bb-upper c)) close))))
        ;; Below lower Bollinger
        (if (< close (:bb-lower c))
          (Log "bb-breakout-lower"
            (max 0.01 (if (= close 0.0) 0.01
              (/ (- (:bb-lower c) close) close))))
          ;; Inside — emit position
          (Linear "bb-inside-pos" (:bb-pos c) 1.0))))))
