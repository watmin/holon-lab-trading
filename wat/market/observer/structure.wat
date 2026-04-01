;; rune:assay(prose) — structure.wat lists the vocabulary atoms but does not express
;; eval dispatch or encoding. One instantiation line; the rest is description.

;; ── structure expert ────────────────────────────────────────────────
;;
;; Thinks about: geometric shape of price action.
;; Window: sampled from [min-window, max-window] per candle.

(require core/primitives)
(require core/structural)
(require common)
(require patterns)

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

;; expert: shorthand for (new-observer profile dims refit-interval seed labels).
;; See market/observer.wat for the Observer struct.
(define structure
  (new-observer "structure" dims refit-interval :seed-structure ["Buy" "Sell"]))

;; ── What structure does NOT see ─────────────────────────────────────
;; - RSI/stochastic/CCI zones (momentum)
;; - RSI divergence (momentum)
;; - Calendar / sessions (narrative)
;; - Volume (volume)
;; - Regime indicators (regime only)
