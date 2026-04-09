;; vocab/market/flow.wat — OBV, VWAP, MFI, buying/selling pressure
;; Depends on: candle
;; MarketLens :volume uses this.

(require primitives)
(require candle)

;; Flow facts — volume-derived signals.
(define (encode-flow-facts [c : Candle])
  : Vec<ThoughtAST>
  (list
    ;; OBV slope — 12-period linear regression slope. Sign IS direction.
    ;; linreg-slope is ABOVE obv-step — it computes the OBV's trend direction.
    (Linear "obv-slope-12" (:obv-slope-12 c) 1000000.0)
    ;; Volume acceleration — volume / volume_sma20. Ratio — log compresses.
    (Log "volume-accel" (max 0.001 (:volume-accel c)))
    ;; VWAP distance — signed: (close - VWAP) / close
    (Linear "vwap-distance" (:vwap-distance c) 0.1)
    ;; MFI — money flow index, [0, 1] normalized
    (Linear "mfi" (/ (:mfi c) 100.0) 1.0)))
