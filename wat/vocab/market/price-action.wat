;; price-action.wat — inside/outside bars, gaps, consecutive runs, body ratio
;;
;; Depends on: candle
;; Domain: market (MarketLens :structure)
;;
;; Candlestick structure from a single candle. Body ratio encodes
;; decisiveness. Range and body geometry encode the candle's character.
;; Cross-candle patterns (inside bars, gaps, consecutive runs) are
;; pre-computed by the IndicatorBank on the enriched Candle.

(require primitives)
(require candle)

;; Body ratio: body / range. Range [0, 1].
;; 1.0 = no wicks (decisive). 0.0 = all wick (indecisive).
;;
;; Upper wick ratio: (high - body-top) / range. How much rejection above.
;; Lower wick ratio: (body-bottom - low) / range. How much rejection below.
;;
;; Candle direction: +1 bullish, -1 bearish, 0 doji.
;; ROC-1 captures the magnitude.
;;
;; Inside bar — pre-computed on Candle. Compression ratio: current range / prev range.
;; < 1 = inside bar (range contracted). The further below 1.0, the tighter.
;;
;; Outside bar — pre-computed on Candle. Expansion ratio: current range / prev range.
;; > 1 = outside bar (range expanded). The further above 1.0, the wider.
;;
;; Gap — pre-computed on Candle. Signed: (open - prev close) / prev close.
;; Positive = gap up. Negative = gap down.
;;
;; Consecutive up/down — pre-computed on Candle.
;; Run count of consecutive bullish or bearish closes.
;; Linear-encoded. Longer runs = stronger momentum or exhaustion signal.

(define (encode-price-action-facts [candle : Candle])
  : Vec<ThoughtAST>
  (let* ((range    (- (:high candle) (:low candle)))
         (body-top (max (:close candle) (:open candle)))
         (body-bot (min (:close candle) (:open candle)))
         (body     (- body-top body-bot)))

    ;; Only emit single-candle geometry when range is meaningful
    (if (< range 1e-10)
      (list)
      (let* ((facts (list
               (Linear "body-ratio" (/ body range) 1.0)
               (Linear "upper-wick" (/ (- (:high candle) body-top) range) 1.0)
               (Linear "lower-wick" (/ (- body-bot (:low candle)) range) 1.0)
               (Linear "candle-dir"
                 (signum (- (:close candle) (:open candle))) 1.0)))

             ;; Range ratio — one scalar, one atom. < 1 = compression, > 1 = expansion
             (rr (:range-ratio candle))
             (facts (if (> rr 0.0)
                      (append facts (list (Log "range-ratio" rr)))
                      facts))

             ;; Gap — signed distance
             (g (:gap candle))
             (facts (if (!= g 0.0)
                      (append facts (list (Linear "gap" g 0.05)))
                      facts))

             ;; Consecutive runs — bullish and bearish
             (cup (:consecutive-up candle))
             (facts (if (> cup 0.0)
                      (append facts (list (Linear "consecutive-up" cup 10.0)))
                      facts))

             (cdn (:consecutive-down candle))
             (facts (if (> cdn 0.0)
                      (append facts (list (Linear "consecutive-down" cdn 10.0)))
                      facts)))

        facts))))
