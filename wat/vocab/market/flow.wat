;; ── vocab/market/flow.wat ────────────────────────────────────────
;;
;; Volume and pressure. Pure function: candle in, ASTs out.
;; atoms: obv-slope, vwap-distance, buying-pressure, selling-pressure,
;;        volume-ratio, body-ratio
;; Depends on: candle.

(require candle)

(define (encode-flow-facts [c : Candle])
  : Vec<ThoughtAST>
  (let ((range (- (:high c) (:low c)))
        (body  (- (:close c) (:open c)))
        (abs-body (abs body)))
    (list
      ;; OBV slope: unbounded rate of change. Log-encoded.
      '(Log "obv-slope" (exp (:obv-slope-12 c)))

      ;; VWAP distance: signed percentage from VWAP. Linear, bounded by ~10%.
      '(Linear "vwap-distance" (:vwap-distance c) 0.1)

      ;; Buying pressure: (close - low) / range. [0, 1].
      ;; When range is zero, emit 0.5 (neutral).
      '(Linear "buying-pressure"
               (if (> range 0.0)
                   (/ (- (:close c) (:low c)) range)
                   0.5)
               1.0)

      ;; Selling pressure: (high - close) / range. [0, 1].
      '(Linear "selling-pressure"
               (if (> range 0.0)
                   (/ (- (:high c) (:close c)) range)
                   0.5)
               1.0)

      ;; Volume ratio: current volume / average. Unbounded positive.
      ;; volume-accel on candle is acceleration; use raw volume with log.
      '(Log "volume-ratio" (max 0.001 (exp (:volume-accel c))))

      ;; Body ratio: |body| / range. [0, 1]. How much of the candle is body.
      '(Linear "body-ratio"
               (if (> range 0.0)
                   (/ abs-body range)
                   0.0)
               1.0))))
