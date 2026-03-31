;; ── volume expert ──────────────────────────────────────────────────
;;
;; Thinks about: participation and conviction behind price moves.
;; Window: sampled from [min-window, max-window] per candle.

(require core/primitives)
(require core/structural)
(require std/common)
(require std/patterns)

;; ── Vocabulary ──────────────────────────────────────────────────────
;;
;; Flow (vocab/flow module):
;;   (bind :vwap   (encode-linear (vwap-distance candles) 1.0))  ; price vs volume-weighted average
;;   (bind :at     (bind :mfi :mfi-overbought))                  ; money flow > 80
;;   (bind :at     (bind :mfi :mfi-oversold))                    ; money flow < 20
;;   (bind :buy-pressure  (encode-linear bp 1.0))                ; lower wick / range
;;   (bind :sell-pressure (encode-linear sp 1.0))                ; upper wick / range
;;   (bind :body-ratio    (encode-linear br 1.0))                ; body / range
;;   (bind :at     (bind :volume :volume-spike))                 ; vol_accel > 2.0
;;   (bind :at     (bind :volume :volume-drought))               ; vol_accel < 0.3
;;
;; OBV (special encoding — bind patterns, not Fact interface):
;;   (bind :obv-direction (atom (if (> obv-slope 0) "up" "down")))
;;   (bind :obv-diverges  (atom "true"))                         ; OBV vs price disagree
;;
;; Participation (vocab/price_action module):
;;   (bind :at (bind :close :inside-bar))                        ; range compressed
;;   (bind :at (bind :close :outside-bar))                       ; range engulfs previous
;;   (bind :at (bind :close :gap-up))                            ; gap from previous close
;;   (bind :at (bind :close :gap-down))
;;   (bind :at (bind :close :consecutive-up))                    ; 3+ green candles
;;   (bind :at (bind :close :consecutive-down))                  ; 3+ red candles
;;
;; Volume confirmation (eval_volume_confirmation):
;;   current volume vs window average, direction match

;; ── The expert ──────────────────────────────────────────────────────

(define volume
  (expert "volume" :volume dims refit-interval))

;; ── DISCOVERY ───────────────────────────────────────────────────────
;; Volume is the THINNEST expert vocabulary. Only 4 eval methods.
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
