;; flow.wat — OBV, VWAP, MFI, buying/selling pressure
;;
;; Depends on: candle
;; Domain: market (MarketLens :volume)
;;
;; Volume tells what CONVICTION accompanies a move.
;; Price without volume is opinion. Price with volume is fact.

(require primitives)
(require candle)

;; OBV slope — pre-computed on Candle (obv-slope-12: 12-period linear
;; regression slope of OBV). Sign: +1 volume rising, -1 volume falling.
;; Magnitude: how fast.
;;
;; VWAP distance — pre-computed on Candle (vwap-distance).
;; (close - VWAP) / close. Signed: positive = above, negative = below.
;;
;; MFI — pre-computed on Candle. Range [0, 100]. Normalized to [0, 1].
;;
;; Buying/selling pressure — wick analysis per candle.
;; buy-pressure = (body-bottom - low) / range
;; sell-pressure = (high - body-top) / range
;; body-ratio = body / range
;;
;; Volume acceleration — pre-computed on Candle (vol-accel).
;; volume / volume-sma-20. Log-encoded because ratios.

(define (encode-flow-facts [candle : Candle])
  : Vec<ThoughtAST>
  (let* ((range     (- (:high candle) (:low candle)))
         (body-top  (max (:close candle) (:open candle)))
         (body-bot  (min (:close candle) (:open candle)))
         (body      (- body-top body-bot))
         (facts     (list
                      ;; MFI — normalized to [0, 1]
                      (Linear "mfi" (/ (:mfi candle) 100.0) 1.0)

                      ;; OBV slope — signed scalar
                      (Linear "obv-slope" (:obv-slope-12 candle) 1.0)

                      ;; Volume acceleration — ratio, log-encoded
                      (Log "vol-accel" (max (:vol-accel candle) 0.001))

                      ;; VWAP distance — pre-computed, signed
                      (Linear "vwap-dist" (:vwap-distance candle) 0.1))))

    ;; Buying/selling pressure — only when range is meaningful
    (if (> range 1e-10)
      (append facts
        (list (Linear "buy-pressure" (/ (- body-bot (:low candle)) range) 1.0)
              (Linear "sell-pressure" (/ (- (:high candle) body-top) range) 1.0)
              (Linear "body-ratio" (/ body range) 1.0)))
      facts)))
