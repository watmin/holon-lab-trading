;; ── momentum expert ─────────────────────────────────────────────────
;;
;; Thinks about: speed and direction of price change.
;; Window: sampled from [min-window, max-window] per candle.

(require core/primitives)
(require core/structural)
(require facts)
(require patterns)

;; ── Profile dispatch ────────────────────────────────────────────────

(define (encode-momentum candles)
  "Momentum's thought: comparisons + oscillators + crosses + divergence."
  (append
    (eval-comparisons candles)          ; shared with structure
    (eval-rsi-sma candles)              ; (above rsi rsi-sma), crosses
    (eval-stochastic candles)           ; %K zones, %K/%D crosses
    (eval-momentum candles)             ; CCI zones, ROC
    (eval-divergence candles)           ; RSI divergence via PELT peaks
    (eval-oscillators candles)))        ; Williams %R, StochRSI, UltOsc, multi-ROC

;; ── The expert ──────────────────────────────────────────────────────

(define momentum
  (new-observer "momentum" dims refit-interval :seed-momentum ["Buy" "Sell"]))

;; ── Example thoughts ────────────────────────────────────────────────
;;
;; (fact/comparison "above" "close" "sma50")       ; price above SMA50
;; (fact/comparison "crosses-above" "macd-line" "macd-signal")
;; (fact/zone "stoch-k" "stoch-overbought")        ; stochastic overbought
;; (fact/zone "rsi" "overbought")                   ; RSI overbought
;; (fact/bare "roc-accelerating")                   ; cascading ROC momentum

;; ── What momentum does NOT see ──────────────────────────────────────
;; - Calendar / time of day (narrative)
;; - PELT segment narrative (structure)
;; - Fibonacci / Ichimoku / Keltner (structure)
;; - Range position (structure)
;; - Volume (volume)
;; - Regime indicators (regime only)
