;; flow.wat — volume and money flow facts
;;
;; Depends on: candle (reads: obv-slope-12, vwap-distance, mfi, volume-accel)
;; Market domain. Lens: :volume, :generalist.
;;
;; OBV slope, VWAP distance, volume acceleration.
;; MFI is in oscillators — not duplicated here.

(require primitives)

(define (encode-flow-facts [candle : Candle]) : Vec<ThoughtAST>
  (list
    ;; OBV slope — signed, unbounded. Log of absolute + sign via linear.
    (Linear "obv-slope" (:obv-slope-12 candle) 1.0)

    ;; VWAP distance — signed, (close - VWAP) / close
    (Linear "vwap-distance" (:vwap-distance candle) 0.1)

    ;; Volume acceleration — volume / volume_sma20. Unbounded positive.
    (Log "volume-accel" (:volume-accel candle))))
