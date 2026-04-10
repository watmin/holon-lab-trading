;; vocab/market/flow.wat — OBV, VWAP, MFI, buying/selling pressure
;; Depends on: candle
;; MarketLens :volume uses this module.

(require primitives)
(require candle)

(define (encode-flow-facts [c : Candle])
  : Vec<ThoughtAST>
  (list
    ;; OBV slope — direction and magnitude of on-balance volume
    (Linear "obv-slope" (:obv-slope-12 c) 1.0)
    ;; Volume acceleration — how unusual is current volume
    (Log "volume-accel" (max 0.001 (:volume-accel c)))
    ;; VWAP distance — signed: positive = above VWAP, negative = below
    (Linear "vwap-distance" (:vwap-distance c) 0.1)
    ;; MFI — money flow index [0, 1]
    (Linear "mfi" (:mfi c) 1.0)))
