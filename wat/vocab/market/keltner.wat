;; keltner.wat — keltner position, BB position, squeeze RATIO
;;
;; Depends on: candle
;; Domain: market (MarketLens :structure)
;;
;; Keltner channels and Bollinger Bands are volatility envelopes.
;; Position within them is a continuous scalar. Squeeze is the
;; RATIO of BB width to Keltner width — when < 1.0, Bollinger is
;; inside Keltner (squeeze). The continuous ratio IS the signal.

(require primitives)
(require enums)       ; ThoughtAST constructors
(require candle)

;; Keltner position — pre-computed on Candle. Range [0, 1].
;; Where is price within the Keltner channel?
;;
;; Bollinger position — pre-computed on Candle. Range [0, 1].
;; Where is price within the Bollinger bands?
;;
;; Bollinger width — pre-computed on Candle. Ratio of band width to price.
;; Log-encoded because ratios.
;;
;; Squeeze ratio — bb-width / keltner-width. Continuous.
;; < 1.0 = BB inside Keltner (squeeze). > 1.0 = BB wider than Keltner.
;; The ratio preserves how MUCH compression or expansion, not just whether.
;; Log-encoded because ratio.
;;
;; BB-Keltner spread: kelt-pos - bb-pos. Signed.
;; When positive, Keltner is wider relative to price — expansion.
;; When negative, BB is wider — unusual.

(define (encode-keltner-facts [candle : Candle])
  : Vec<ThoughtAST>
  ;; Guard: Keltner needs warmup
  (if (or (<= (:kelt-upper candle) 0.0)
          (<= (:kelt-lower candle) 0.0))
    (list)
    (let* ((kelt-width (- (:kelt-upper candle) (:kelt-lower candle)))
           (squeeze-ratio (/ (:bb-width candle) (max kelt-width 0.0001))))
      (list
        (Linear "kelt-pos" (clamp (:kelt-pos candle) 0.0 1.0) 1.0)
        (Linear "bb-pos" (clamp (:bb-pos candle) 0.0 1.0) 1.0)
        (Log "bb-width" (max (:bb-width candle) 0.0001))
        (Log "squeeze-ratio" (max squeeze-ratio 0.0001))
        (Linear "bk-spread" (- (:kelt-pos candle) (:bb-pos candle)) 1.0)))))
