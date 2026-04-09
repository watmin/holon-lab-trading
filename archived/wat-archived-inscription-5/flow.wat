;; vocab/market/flow.wat — OBV, VWAP, volume acceleration, buying/selling pressure
;; Depends on: candle
;; MarketLens :volume selects this module.

(require primitives)
(require candle)

;; Volume and flow facts.
;; OBV slope: signed — positive = accumulation, negative = distribution.
;; Volume acceleration: ratio — how unusual is current volume.
;; VWAP distance: signed — above or below institutional fair value.
(define (encode-flow-facts [c : Candle])
  : Vec<ThoughtAST>
  (list
    ;; OBV slope — 12-period linear regression. Signed, unbounded.
    (Linear "obv-slope-12" (:obv-slope-12 c) 1.0)

    ;; Volume acceleration — ratio of current volume to its 20-period SMA.
    ;; Log because ratios compress naturally. 1.0 = average, 2.0 = double.
    (Log "volume-accel" (max 0.01 (:volume-accel c)))

    ;; VWAP distance — signed distance from volume-weighted average price.
    ;; Percentage of price. Positive = above VWAP.
    (Linear "vwap-distance" (:vwap-distance c) 0.1)

    ;; Buying pressure: close near high. (close - low) / (high - low).
    (let ((rng (- (:high c) (:low c))))
      (if (= rng 0.0)
        (Linear "buying-pressure" 0.5 1.0)
        (Linear "buying-pressure"
          (/ (- (:close c) (:low c)) rng)
          1.0)))

    ;; MFI — money flow as a flow indicator [0, 1]
    (Linear "mfi-flow" (/ (:mfi c) 100.0) 1.0)))
