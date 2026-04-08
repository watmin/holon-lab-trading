;; oscillators.wat — Williams %R, StochRSI, UltOsc, multi-ROC
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
;; Ultimate Oscillator — weighted three-timeframe (7, 14, 28).
;; Window-dependent. Range [0, 100]. Normalized to [0, 1].
;;
;; Multi-ROC — rate of change at 1, 3, 6, 12 periods.
;; Per-candle rate: roc-N / N. Signed. Log-encoded because
;; the difference between 1% and 2% matters more than 10% and 11%.
;; ROC acceleration: comparison of rates across scales.

(define (encode-oscillator-facts [candle : Candle]
                                 [candles : Vec<Candle>])
  : Vec<ThoughtAST>
  (let* ((wr     (+ (/ (:williams-r candle) 100.0) 1.0))  ; normalize [-100,0] → [0,1]
         (sk     (/ (:stoch-k candle) 100.0))              ; normalize [0,100] → [0,1]
         (r1     (:roc-1 candle))
         (r3     (/ (:roc-3 candle) 3.0))
         (r6     (/ (:roc-6 candle) 6.0))
         (r12    (/ (:roc-12 candle) 12.0))
         (facts  (list
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

    ;; Ultimate Oscillator — window-dependent, optional
    (let ((uo (ultimate-oscillator candles 7 14 28)))
      (if uo
        (append facts (list (Linear "ult-osc" (/ uo 100.0) 1.0)))
        facts))))

;; Ultimate Oscillator: weighted average of three timeframes.
;; Computed from candle window (not pre-baked on Candle).
;; Returns None if insufficient data.
(define (ultimate-oscillator [candles : Vec<Candle>]
                             [p1 : usize] [p2 : usize] [p3 : usize])
  : Option<f64>
  ;; Needs p3+1 candles minimum.
  ;; BP = close - min(low, prev-close)
  ;; TR = max(high, prev-close) - min(low, prev-close)
  ;; UO = 100 * (4*avg1 + 2*avg2 + avg3) / 7
  ;; where avg_i = sum(BP_i) / sum(TR_i) over period i
  (if (< (len candles) (+ p3 1))
    None
    ;; Implementation deferred to Rust — window iteration
    ;; The wat declares the interface and the formula
    (let* ((avgs (map (lambda (p)
                   (let ((slice (last-n candles p)))
                     (/ (fold-left + 0.0 (map bp slice))
                        (fold-left + 0.0 (map tr slice)))))
                 (list p1 p2 p3)))
           (a1 (nth avgs 0))
           (a2 (nth avgs 1))
           (a3 (nth avgs 2)))
      (Some (* 100.0 (/ (+ (* 4.0 a1) (* 2.0 a2) a3) 7.0))))))
