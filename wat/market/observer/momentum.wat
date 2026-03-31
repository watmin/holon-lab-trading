;; ── momentum expert ─────────────────────────────────────────────────
;;
;; Thinks about: speed and direction of price change.
;; Window: sampled from [min-window, max-window] per candle.

(require core/primitives)
(require core/structural)
(require common)
(require patterns)

;; ── Vocabulary ──────────────────────────────────────────────────────
;;
;; Comparisons (shared with structure):
;;   (bind :above (bind :close :sma50))
;;   (bind :crosses-above (bind :macd-line :macd-signal))
;;   (bind :above (bind :dmi-plus :dmi-minus))
;;
;; Oscillator zones:
;;   (bind :at (bind :rsi :overbought))
;;   (bind :at (bind :stoch-k :stoch-overbought))
;;   (bind :at (bind :cci :cci-overbought))
;;
;; Crosses:
;;   (bind :crosses-above (bind :rsi :rsi-sma))
;;   (bind :crosses-above (bind :macd-histogram :zero))
;;
;; Divergence:
;;   (bind :diverging (bind :close :up) (bind :rsi :down))
;;
;; Oscillators (vocab/oscillators module):
;;   Williams %R, StochRSI, UltOsc, multi-ROC

;; ── The expert ──────────────────────────────────────────────────────

;; expert: shorthand for (new-observer profile dims refit-interval seed labels).
;; See market/observer.wat for the Observer struct.
(define momentum
  (new-observer "momentum" dims refit-interval :seed-momentum ["Buy" "Sell"]))

;; ── What momentum does NOT see ──────────────────────────────────────
;; - Calendar / time of day (narrative)
;; - PELT segment narrative (structure)
;; - Fibonacci levels (structure)
;; - Ichimoku cloud (structure)
;; - Keltner / squeeze (structure)
;; - Range position (structure)
;; - Volume (volume)
;; - Regime indicators (regime only — RESOLVED)
