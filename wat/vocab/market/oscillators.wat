;; oscillators.wat — Williams %R, StochRSI, multi-ROC
;;
;; Depends on: candle
;; Domain: market (MarketLens :momentum)
;;
;; Every value is a scalar. No zones. The discriminant learns
;; where the boundaries are.

(require primitives)
(require candle)

;; Williams %R — pre-computed on Candle. Range [-100, 0].
;; Normalized to [0, 1]: (wr + 100) / 100.
;;
;; StochRSI — stoch-k used as an RSI-like oscillator.
;; Pre-computed on Candle. Range [0, 100]. Normalized to [0, 1].
;;
;; Multi-ROC — rate of change at 1, 3, 6, 12 periods.
;; Per-candle rate: roc-N / N. Signed. Log-encoded because
;; the difference between 1% and 2% matters more than 10% and 11%.
;; ROC acceleration: comparison of rates across scales.

(define (encode-oscillator-facts [candle : Candle])
  : Vec<ThoughtAST>
  (let* ((wr     (+ (/ (:williams-r candle) 100.0) 1.0))  ; normalize [-100,0] -> [0,1]
         (sk     (/ (:stoch-k candle) 100.0))              ; normalize [0,100] -> [0,1]
         (r1     (:roc-1 candle))
         (r3     (/ (:roc-3 candle) 3.0))
         (r6     (/ (:roc-6 candle) 6.0))
         (r12    (/ (:roc-12 candle) 12.0)))
    (list
      (Linear "williams-r" wr 1.0)
      (Linear "stoch-rsi" sk 1.0)
      (Log "roc-1" (abs r1))
      (Log "roc-3" (abs r3))
      (Log "roc-6" (abs r6))
      (Log "roc-12" (abs r12))
      (Linear "roc-1-sign" (signum r1) 1.0)
      (Linear "roc-3-sign" (signum r3) 1.0)
      (Linear "roc-6-sign" (signum r6) 1.0)
      (Linear "roc-12-sign" (signum r12) 1.0))))
