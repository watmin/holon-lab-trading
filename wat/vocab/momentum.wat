;; ── vocab/momentum.wat — CCI zone detection ─────────────────────
;;
;; The simplest vocab module. Reads pre-computed CCI from Candle.
;; One indicator, two zones. That's it.
;;
;; Expert profile: momentum

(require vocab/mod)

;; ── Atoms introduced ───────────────────────────────────────────

;; Indicators:   cci
;; Zones:        cci-overbought, cci-oversold

;; ── Facts produced ─────────────────────────────────────────────

; rune:gaze(phantom) — fact/zone is not in the wat language
(define (eval-momentum candles)
  "CCI zone facts."

  ;; CCI — pre-computed on Candle (20-period)
  ;; Zone: (at cci cci-overbought) when CCI > 100
  ;;        (at cci cci-oversold)   when CCI < -100
  ;; Thresholds: 100/-100. Standard CCI interpretation.
  ;; Lambert's original levels. Two standard deviations from the mean.
  (when (> cci 100.0)  (fact/zone "cci" "cci-overbought"))
  (when (< cci -100.0) (fact/zone "cci" "cci-oversold")))

;; ── What momentum does NOT do ──────────────────────────────────
;; - Does NOT compute CCI (pre-computed on Candle)
;; - Does NOT emit scalars (just zones — the value is binary signal)
;; - Does NOT check ROC (that's oscillators.wat)
;; - Does NOT import holon or create vectors
;; - Pure function. Candles in, facts out.
