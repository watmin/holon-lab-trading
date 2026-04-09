;; vocab/market/flow.wat — OBV, VWAP, MFI, buying/selling pressure.
;;
;; Depends on: Candle, ThoughtAST.
;;
;; Pure: candle in, ASTs out. No state.
;; volume-accel (not vol-accel) — volume / volume_sma20.

(require primitives)
(require candle)
(require enums)     ; ThoughtAST

;; ── encode-flow-facts ───────────────────────────────────────────────────

(define (encode-flow-facts [c : Candle])
  : Vec<ThoughtAST>
  (list
    ;; OBV slope — signed, captures buying/selling pressure direction
    (Linear "obv-slope" (:obv-slope-12 c) 1.0)

    ;; Volume acceleration — ratio, unbounded positive
    ;; volume / volume_sma20: 1.0 = normal, 2.0 = double
    (Log "volume-accel" (:volume-accel c))

    ;; MFI — [0, 100] normalized to [0, 1]
    (Linear "mfi" (/ (:mfi c) 100.0) 1.0)

    ;; VWAP distance — signed, (close - VWAP) / close
    (Linear "vwap-distance" (:vwap-distance c) 0.1)

    ;; Buying vs selling pressure via close position within bar
    ;; (close - low) / (high - low) — [0, 1]
    (let ((bar-range (- (:high c) (:low c))))
      (if (> bar-range 0.0)
          (Linear "bar-pressure" (/ (- (:close c) (:low c)) bar-range) 1.0)
          (Linear "bar-pressure" 0.5 1.0)))))
