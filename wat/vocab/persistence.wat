;; ── vocab/persistence.wat — trend persistence and memory ────────
;;
;; Properties of the price series, not direction.
;; "Is this market trending or mean-reverting? Persistent or random?"
;;
;; Hurst exponent, lag-1 autocorrelation, ADX zone classification.
;;
;; Expert profile: regime

(require vocab/mod)
(require std/facts)
(require std/statistics)

;; ── Atoms introduced ───────────────────────────────────────────

;; Indicators:   hurst, autocorr, adx
;; Zones:        hurst-trending, hurst-reverting,
;;               autocorr-positive, autocorr-negative,
;;               strong-trend, weak-trend, moderate-trend

;; ── Hurst exponent ─────────────────────────────────────────────
;;
;; Rescaled range (R/S) estimate.
;; H > 0.5: persistent — trends continue.
;; H < 0.5: anti-persistent — reversals likely.
;; H = 0.5: random walk.
;;
;; Lookback: min(window_length, 100). Minimum 10 candles.
;; H = ln(R/S) / ln(N) where R/S = (max_cum - min_cum) / std
;; Returns None if std < 1e-15 or R/S <= 0.

; rune:gaze(phantom) — log-returns is not in the wat language
; rune:gaze(phantom) — last-n is not in the wat language
; rune:gaze(phantom) — range is not in the wat language
; rune:gaze(phantom) — cumulative-deviation is not in the wat language
; rune:gaze(phantom) — std is not in the wat language
(define (hurst-estimate candles lookback)
  "Simplified Hurst via rescaled range. Returns [0, 1] or None."
  (let ((returns (log-returns (last-n candles lookback))))
    (/ (ln (/ (range (cumulative-deviation returns)) (std returns)))
       (ln (len returns)))))

;; ── Autocorrelation ────────────────────────────────────────────
;;
;; Lag-1 autocorrelation of returns.
;; Positive = momentum. Negative = mean-reversion. Near zero = random.
;; Lookback: min(window_length, 50). Minimum 5 candles.
;; Returns None if variance < 1e-15.

; rune:gaze(phantom) — covariance is not in the wat language
; rune:gaze(phantom) — lag-1 is not in the wat language
(define (autocorrelation-lag1 candles lookback)
  "Lag-1 return autocorrelation. Returns [-1, 1] or None."
  (/ (covariance returns (lag-1 returns))
     (variance returns)))

;; ── ADX zone ───────────────────────────────────────────────────
;;
;; Pre-computed on Candle (14-period Wilder ADX).
;; ADX > 25: "strong-trend" — the market has conviction.
;; ADX < 20: "weak-trend"   — directionless.
;; Else:     "moderate-trend"
;; Thresholds: 25/20. Standard ADX interpretation.

;; ── Facts produced ─────────────────────────────────────────────

; rune:gaze(phantom) — adx-zone is not in the wat language
(define (eval-persistence candles)
  "Trend persistence facts."

  ;; Hurst — computed from window (up to 100 candles)
  ;; Scalar: (hurst value) clamped [0, 1], scale 1.0
  ;; Zone: (at hurst hurst-trending)  when H > 0.55
  ;;        (at hurst hurst-reverting) when H < 0.45
  ;; Thresholds: 0.55/0.45. Modest separation from 0.5 random walk.
  (when hurst
    (fact/scalar "hurst" (clamp hurst 0.0 1.0) 1.0)
    (when (> hurst 0.55) (fact/zone "hurst" "hurst-trending"))
    (when (< hurst 0.45) (fact/zone "hurst" "hurst-reverting")))

  ;; Autocorrelation — computed from window (up to 50 candles)
  ;; Scalar: (autocorr value) clamped [-1,1] mapped to [0,1], scale 1.0
  ;; Zone: (at autocorr autocorr-positive) when ac > 0.1
  ;;        (at autocorr autocorr-negative) when ac < -0.1
  ;; Thresholds: 0.1/-0.1. Minimal significance filter.
  (when ac
    (fact/scalar "autocorr" (+ (* (clamp ac -1.0 1.0) 0.5) 0.5) 1.0)
    (when (> ac  0.1) (fact/zone "autocorr" "autocorr-positive"))
    (when (< ac -0.1) (fact/zone "autocorr" "autocorr-negative")))

  ;; ADX zone — pre-computed, always emitted
  ;; Zone: (at adx strong-trend | weak-trend | moderate-trend)
  ; rune:gaze(phantom) — . (dot accessor) is not in the wat language
  (fact/zone "adx" (adx-zone (. now adx))))

;; ── What persistence does NOT do ───────────────────────────────
;; - Does NOT detect direction (it measures character of the series)
;; - Does NOT compute DFA, entropy, or fractals (that's regime.wat)
;; - Does NOT import holon or create vectors
;; - Pure function. Candles in, facts out.
