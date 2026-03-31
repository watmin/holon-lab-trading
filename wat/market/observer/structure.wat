;; ── structure expert ────────────────────────────────────────────────
;;
;; Thinks about: geometric shape of price action.
;; Window: sampled from [min-window, max-window] per candle.

(require core/primitives)
(require core/structural)
(require std/common)
(require std/patterns)

;; ── Vocabulary ──────────────────────────────────────────────────────
;;
;; Comparisons (shared with momentum):
;;   (bind :above (bind :close :bb-upper))
;;   (bind :below (bind :close :sma200))
;;
;; PELT segments:
;;   direction, duration, magnitude per changepoint
;;
;; Spatial features:
;;   (bind :at (bind :close :above-cloud))     ; Ichimoku
;;   (bind :at (bind :close :fib-618))         ; Fibonacci
;;   (bind :at (bind :keltner-squeeze :active)) ; Keltner
;;   (range-position 0.85)                      ; where in the range
;;
;; Multi-timeframe:
;;   1h and 4h range position, body ratio

;; ── The expert ──────────────────────────────────────────────────────

; rune:gaze(phantom) — expert is not in the wat language
(define structure
  (expert "structure" :structure dims refit-interval))

;; ── What structure does NOT see ─────────────────────────────────────
;; - RSI/stochastic/CCI zones (momentum)
;; - RSI divergence (momentum)
;; - Calendar / sessions (narrative)
;; - Volume (volume)
;; - Regime indicators (regime only)
