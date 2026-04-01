;; ── observer ──────────────────────────────────────────────────
;;
;; Thinks about: participation and conviction behind price moves.
;; Window: sampled from [min-window, max-window] per candle.

(require core/primitives)
(require core/structural)
(require facts)
(require patterns)

;; ── Lens ────────────────────────────────────────────────

(define (encode-volume candles)
  "Volume's thought: confirmation + analysis + price action + flow."
  (append
    (eval-volume-confirmation candles)  ; current volume vs window average
    (eval-volume-analysis candles)      ; volume trend, acceleration
    (eval-price-action candles)         ; inside/outside bars, gaps, consecutive
    (eval-flow-module candles)))        ; OBV, VWAP, MFI, buying/selling pressure

;; ── observer ──────────────────────────────────────────────────────

(define volume
  (new-observer "volume" dims refit-interval :seed-volume ["Buy" "Sell"]))

;; ── Example thoughts ────────────────────────────────────────────────
;;
;; (fact/zone "volume" "volume-spike")                  ; vol_accel > 2.0
;; (fact/zone "volume" "volume-drought")                ; vol_accel < 0.3
;; (fact/zone "mfi" "mfi-overbought")                   ; money flow > 80
;; (fact/zone "close" "inside-bar")                      ; range compressed
;; (fact/zone "close" "gap-up")                          ; gap from previous close
;; (fact/bare "obv-diverges")                            ; OBV vs price disagree

;; ── DISCOVERY ───────────────────────────────────────────────────────
;; Volume is the THINNEST lens. Only 4 eval methods.
;; Rarely proves its gate (appeared once in 100k run, at 50k).
;; Is the vocabulary too thin, or is volume inherently less predictive?
;; Inside bars are geometric (structure) but validated by volume (volume).

;; ── What volume does NOT see ────────────────────────────────────────
;; - Comparisons (momentum, structure)
;; - PELT segments (narrative, structure)
;; - Temporal crosses (narrative, momentum)
;; - Oscillators (momentum)
;; - Cloud/fib/keltner (structure)
;; - Calendar (narrative)
;; - Regime indicators (regime)
