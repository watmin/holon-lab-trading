;; ── vocab/oscillators.wat — momentum oscillator facts ────────────
;;
;; Williams %R, Stochastic RSI, Ultimate Oscillator, multi-ROC.
;; Reads pre-computed values from Candle where available.
;; Ultimate Oscillator is window-dependent — computed from raw candles.
;;
;; Expert profile: momentum

(require vocab/mod)

;; ── Atoms introduced ───────────────────────────────────────────

;; Indicators:   williams-r, stoch-rsi, ult-osc
;; Zones:        williams-overbought, williams-oversold,
;;               stoch-rsi-overbought, stoch-rsi-oversold,
;;               ult-osc-overbought, ult-osc-oversold
;; Bare:         roc-accelerating, roc-decelerating

;; ── Facts produced ─────────────────────────────────────────────

; rune:gaze(phantom) — fact/zone is not in the wat language
; rune:gaze(phantom) — fact/scalar is not in the wat language
; rune:gaze(phantom) — fact/bare is not in the wat language
; rune:gaze(phantom) — cond is not in the wat language
; rune:gaze(phantom) — len is not in the wat language
(define (eval-oscillators candles)
  "Momentum oscillator facts from a candle window."

  ;; Williams %R — pre-computed on Candle
  ;; Zone: (at williams-r williams-overbought) when %R > -20
  ;;        (at williams-r williams-oversold)   when %R < -80
  ;; Scalar: (williams-r value) where value = (wr + 100) / 100, scale 1.0
  ;; Thresholds: -20 (overbought), -80 (oversold). Standard Williams %R levels.
  (fact/zone "williams-r" (cond
    ((> wr -20.0) "williams-overbought")
    ((< wr -80.0) "williams-oversold")))
  (fact/scalar "williams-r" (/ (+ wr 100.0) 100.0) 1.0)

  ;; Stochastic — pre-computed stoch_k on Candle (raw %K, not smoothed)
  ;; Zone: (at stoch-rsi stoch-rsi-overbought) when %K > 80
  ;;        (at stoch-rsi stoch-rsi-oversold)   when %K < 20
  ;; Scalar: (stoch-rsi value) where value = sk / 100, scale 1.0
  ;; Thresholds: 80/20. Standard stochastic overbought/oversold.
  (fact/zone "stoch-rsi" (cond
    ((> sk 80.0) "stoch-rsi-overbought")
    ((< sk 20.0) "stoch-rsi-oversold")))
  (fact/scalar "stoch-rsi" (/ sk 100.0) 1.0)

  ;; Ultimate Oscillator — window-dependent, computed from raw candles
  ;; Three timeframes (7, 14, 28) weighted 4:2:1.
  ;; uo = 100 * (4*avg7 + 2*avg14 + 1*avg28) / 7
  ;; where avg = buying_pressure / true_range over period.
  ;; Zone: (at ult-osc ult-osc-overbought) when uo > 70
  ;;        (at ult-osc ult-osc-oversold)   when uo < 30
  ;; Thresholds: 70/30. Standard UO levels.
  ;; Returns None if window < 29 candles.
  (when (>= (len candles) 29)
    (fact/zone "ult-osc" (cond
      ((> uo 70.0) "ult-osc-overbought")
      ((< uo 30.0) "ult-osc-oversold"))))

  ;; Multi-timeframe ROC — pre-computed roc_1, roc_3, roc_6, roc_12
  ;; Accelerating: roc_1 > roc_3 > roc_6 > roc_12 (cascading momentum)
  ;; Decelerating: roc_1 < roc_3 < roc_6 < roc_12 (momentum fading)
  ;; Bare: (roc-accelerating) or (roc-decelerating)
  ;; No thresholds. Pure ordering test.
  (when (and (> roc-1 roc-3) (> roc-3 roc-6) (> roc-6 roc-12))
    (fact/bare "roc-accelerating"))
  (when (and (< roc-1 roc-3) (< roc-3 roc-6) (< roc-6 roc-12))
    (fact/bare "roc-decelerating")))

;; ── What oscillators does NOT do ───────────────────────────────
;; - Does NOT compute RSI (that's the segment narrative in thought/mod.rs)
;; - Does NOT detect crosses (that's stochastic.wat)
;; - Does NOT import holon or create vectors
;; - Pure function. Candles in, facts out.
