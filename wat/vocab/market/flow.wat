;; vocab/market/flow.wat — OBV, VWAP, volume pressure
;; Depends on: candle.wat
;; Domain: market — direction signal
;; Lens: :volume

(require primitives)
(require candle)

(define (encode-flow-facts [c : Candle])
  : Vec<ThoughtAST>
  (let ((obv-slope (:obv-slope-12 c))
        (vol-accel (:volume-accel c))
        (vwap-dist (:vwap-distance c))
        (mfi-norm (/ (:mfi c) 100.0)))
    (list
      ;; OBV slope — signed, unbounded
      (Linear "obv-slope" obv-slope 1.0)

      ;; Volume acceleration — ratio, always positive
      (Log "volume-accel" (max vol-accel 0.001))

      ;; VWAP distance — signed fraction
      (Linear "vwap-distance" vwap-dist 0.1)

      ;; MFI — money flow as buying/selling pressure
      (Linear "mfi-pressure" mfi-norm 1.0)

      ;; Buying pressure: close relative to range
      (let ((range (- (:high c) (:low c)))
            (pressure (if (= range 0.0) 0.5
                        (/ (- (:close c) (:low c)) range))))
        (Linear "buying-pressure" pressure 1.0)))))
