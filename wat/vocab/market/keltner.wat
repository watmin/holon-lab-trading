;; keltner.wat — channel position, BB position, squeeze
;;
;; Depends on: candle
;; Domain: market (MarketLens :structure)
;;
;; Keltner channels and Bollinger Bands are volatility envelopes.
;; Position within them is a continuous scalar. Squeeze is the
;; relationship between them — BB inside Keltner = compression.

(require primitives)
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
;; Squeeze — pre-computed boolean on Candle.
;; BB inside Keltner = volatility compression.
;; Encoded as a scalar: 1.0 = squeeze active, 0.0 = not.
;; The discriminant learns whether squeeze matters.
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
    (list
      (Linear "kelt-pos" (clamp (:kelt-pos candle) 0.0 1.0) 1.0)
      (Linear "bb-pos" (clamp (:bb-pos candle) 0.0 1.0) 1.0)
      (Log "bb-width" (max (:bb-width candle) 0.0001))
      (Linear "squeeze" (if (:squeeze candle) 1.0 0.0) 1.0)
      (Linear "bk-spread" (- (:kelt-pos candle) (:bb-pos candle)) 1.0))))
