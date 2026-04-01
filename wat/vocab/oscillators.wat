;; ── vocab/oscillators.wat — momentum oscillator facts ────────────
;;
;; Williams %R, Stochastic RSI, Ultimate Oscillator, multi-ROC.
;; Reads pre-computed values from Candle where available.
;; Ultimate Oscillator is window-dependent — computed from raw candles.
;;
;; Lens: momentum

(require facts)

(define (ultimate-oscillator candles p1 p2 p3)
  "Weighted average of three timeframes. Returns None if window < p3+1.
   uo = 100 * (4*avg7 + 2*avg14 + 1*avg28) / 7
   where avg = buying_pressure / true_range over period."
  (when (>= (len candles) (+ p3 1))
    ;; rune:scry(aspirational) — accumulation loop over candle pairs
    ;; Each candle contributes to periods it falls within.
    ;; buying_pressure = close - min(low, prev_close)
    ;; true_range      = max(high, prev_close) - min(low, prev_close)
    None))

(define (eval-oscillators candles)
  "Momentum oscillator facts from a candle window."
  (let ((now (last candles)))
    (let ((wr     (:williams-r now))
          (sk     (:stoch-k now))
          (roc-1  (:roc-1 now))
          (roc-3  (:roc-3 now))
          (roc-6  (:roc-6 now))
          (roc-12 (:roc-12 now)))
      (append
        ;; Williams %R — zone + scalar
        (cond
          ((> wr -20.0) (list (fact/zone "williams-r" "williams-overbought")))
          ((< wr -80.0) (list (fact/zone "williams-r" "williams-oversold")))
          (else (list)))
        (list (fact/scalar "williams-r" (/ (+ wr 100.0) 100.0) 1.0))

        ;; Stochastic %K — zone + scalar
        (cond
          ((> sk 80.0) (list (fact/zone "stoch-rsi" "stoch-rsi-overbought")))
          ((< sk 20.0) (list (fact/zone "stoch-rsi" "stoch-rsi-oversold")))
          (else (list)))
        (list (fact/scalar "stoch-rsi" (/ sk 100.0) 1.0))

        ;; Ultimate Oscillator — window-dependent
        (when-let ((uo (ultimate-oscillator candles 7 14 28)))
          (cond
            ((> uo 70.0) (list (fact/zone "ult-osc" "ult-osc-overbought")))
            ((< uo 30.0) (list (fact/zone "ult-osc" "ult-osc-oversold")))
            (else (list))))

        ;; Multi-timeframe ROC — cascading momentum test
        (if (and (> roc-1 roc-3) (> roc-3 roc-6) (> roc-6 roc-12))
            (list (fact/bare "roc-accelerating"))
            (list))
        (if (and (< roc-1 roc-3) (< roc-3 roc-6) (< roc-6 roc-12))
            (list (fact/bare "roc-decelerating"))
            (list))))))

;; ── What oscillators does NOT do ───────────────────────────────
;; - Does NOT compute RSI (that's the segment narrative in thought/mod.rs)
;; - Does NOT detect crosses (that's stochastic.wat)
;; - Pure function. Candles in, facts out.
