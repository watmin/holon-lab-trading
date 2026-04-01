;; ── observer ────────────────────────────────────────────────
;;
;; Thinks about: geometric shape of price action.
;; Window: sampled from [min-window, max-window] per candle.

(require core/primitives)
(require core/structural)
(require facts)
(require patterns)

;; ── Lens ────────────────────────────────────────────────

(define (encode-structure candles)
  "Structure's thought: comparisons + segments + spatial + multi-timeframe."
  (append
    (eval-comparisons candles)          ; shared with momentum
    (eval-segment-narrative candles)    ; PELT direction, duration, magnitude per changepoint
    (eval-range-position candles)       ; where in the N-candle range
    (eval-ichimoku candles)             ; cloud position, span crosses
    (eval-fibonacci candles)            ; retracement levels
    (eval-keltner candles)              ; squeeze detection, channel position
    (eval-timeframe-structure candles))) ; 1h/4h range position, body ratio

;; ── observer ──────────────────────────────────────────────────────

(define structure
  (new-observer "structure" dims refit-interval :seed-structure ["Buy" "Sell"]))

;; ── Example thoughts ────────────────────────────────────────────────
;;
;; (fact/comparison "above" "close" "bb-upper")         ; price above upper Bollinger
;; (fact/comparison "below" "close" "sma200")           ; price below SMA200
;; (fact/zone "keltner-squeeze" "active")               ; Keltner squeeze firing
;; (fact/zone "close" "above-cloud")                    ; Ichimoku above cloud
;; (fact/zone "close" "fib-618")                        ; at 61.8% retracement
;; (fact/bare "tf-1h-up-strong")                        ; 1h timeframe bullish

;; ── What structure does NOT see ─────────────────────────────────────
;; - RSI/stochastic/CCI zones (momentum)
;; - RSI divergence (momentum)
;; - Calendar / sessions (narrative)
;; - Volume (volume)
;; - Regime indicators (regime only)
