;; vocab/market/flow.wat — OBV, VWAP, MFI, buying/selling pressure
;; Depends on: candle
;; MarketLens :volume selects this module.

(require primitives)
(require candle)

(define (encode-flow-facts [c : Candle])
  : Vec<ThoughtAST>
  (list
    ;; OBV slope — linear regression slope of OBV over 12 periods
    ;; Signed, unbounded — log compresses the magnitude
    (Log "obv-slope" (max (abs (:obv-slope-12 c)) 0.001))

    ;; OBV slope direction — signed
    (Linear "obv-step" (* (signum (:obv-slope-12 c)) 1.0) 1.0)

    ;; Volume acceleration — ratio vs SMA(20), always positive
    (Log "volume-accel" (max (:volume-accel c) 0.001))

    ;; VWAP distance — signed, how far from VWAP
    (Linear "vwap-distance" (:vwap-distance c) 0.05)

    ;; MFI — buying vs selling pressure [0, 1]
    (Linear "mfi-flow" (/ (:mfi c) 100.0) 1.0)))
