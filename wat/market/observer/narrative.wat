;; ── narrative expert ────────────────────────────────────────────────
;;
;; Thinks about: the story of what happened and when.
;; Window: sampled from [min-window, max-window] per candle.

(require core/primitives)
(require core/structural)
(require std/common)
(require std/patterns)

;; ── Vocabulary ──────────────────────────────────────────────────────
;;
;; Temporal lookback (eval_temporal — PELT segments for cross timing):
;;   (bind :seg (bundle
;;     (bind :indicator (atom indicator-name))
;;     (bind :direction (atom "up"))            ; or "down"
;;     (bind :magnitude (encode-linear mag 1.0))
;;     (bind :duration  (encode-log dur))
;;     (bind :position  (encode-linear seg-idx 1.0))
;;     (bind :recency   (encode-log candles-ago))))
;;   (bind :since (bind :crosses-above (bind :close :sma50)))  ; cross timing
;;   (bind :zone  (bundle
;;     (bind :indicator (atom "rsi"))
;;     (bind :zone-name (atom "rsi-overbought"))
;;     (bind :position  (atom "beginning"))))                   ; zone entry at segment start
;;
;; Calendar (eval_calendar — the only expert with session awareness):
;;   (bind :at-day     (atom day-name))                          ; "monday" .. "sunday"
;;   (bind :at-session (atom session-name))                      ; "us", "europe", "asia", "off-hours"
;;   (bind :hour       (encode-circular hour 24.0))              ; circular — 23 is near 0
;;   (bind :day        (encode-circular day-of-week 7.0))        ; circular — Sunday near Monday
;;
;; Multi-timeframe narrative (vocab/timeframe module):
;;   (bind :at (bind :tf-1h (atom "tf-1h-up-strong")))          ; 1h return direction
;;   (bind :tf-1h-ret  (encode-linear ret 1.0))                 ; 1h return magnitude
;;   (bind :at (bind :tf-4h (atom "tf-4h-down-mild")))          ; 4h return direction
;;   (bind :tf-4h-ret  (encode-linear ret 1.0))                 ; 4h return magnitude
;;   (atom "tf-all-agree")                                       ; 5m, 1h, 4h same direction
;;   (atom "tf-all-disagree")                                    ; all timeframes disagree
;;   (atom "tf-1h-agrees")                                       ; only 1h agrees with 5m
;;   (atom "tf-4h-agrees")                                       ; only 4h agrees with 5m

;; ── The expert ──────────────────────────────────────────────────────

; rune:gaze(phantom) — expert is not in the wat language
(define narrative
  (expert "narrative" :narrative dims refit-interval))

;; ── DISCOVERY ───────────────────────────────────────────────────────
;; Narrative is the only expert with calendar awareness. The manager
;; also encodes hour-of-day and session as context facts. Is the
;; duplication harmful? No — the manager's version is bound with
;; manager-level atoms (structurally distinct hyperspace). The
;; narrative's conviction already incorporates calendar effects.
;; The manager gets temporal signal twice: once from narrative's
;; signed conviction, once from its own temporal atoms. Redundancy
;; or reinforcement? Unknown.
;;
;; Window sensitivity: PELT segments and temporal lookback change
;; with window size. Calendar facts are window-independent.

;; ── What narrative does NOT see ─────────────────────────────────────
;; - Comparisons (momentum, structure)
;; - Segment encoding (structure) — narrative uses PELT for temporal lookback only
;; - Oscillator zones (momentum)
;; - RSI divergence (momentum)
;; - Volume (volume)
;; - Ichimoku / Fibonacci / Keltner (structure)
;; - Range position (structure)
;; - Regime indicators (regime)
