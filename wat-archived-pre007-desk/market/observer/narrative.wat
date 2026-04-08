;; ── observer ────────────────────────────────────────────────
;;
;; Thinks about: the story of what happened and when.
;; Window: sampled from [min-window, max-window] per candle.

(require core/primitives)
(require core/structural)
(require facts)
(require patterns)

;; ── Lens ────────────────────────────────────────────────

(define (encode-narrative candles)
  "Narrative's thought: temporal lookback + calendar + multi-timeframe narrative."
  (append
    (eval-temporal candles)             ; PELT segments for cross timing, zone entry
    (eval-calendar candles)             ; day, session, hour (circular), day-of-week (circular)
    (eval-timeframe-narrative candles))) ; 1h/4h return direction/magnitude, agreement

;; ── observer ──────────────────────────────────────────────────────

(define narrative
  (new-observer "narrative" dims refit-interval :seed-narrative ["Buy" "Sell"]))

;; ── Example thoughts ────────────────────────────────────────────────
;;
;; (fact/bare "monday")                                 ; day of week
;; (fact/bare "us")                                     ; trading session
;; (bind (atom "hour") (encode-circular hour 24.0))     ; circular hour (not fact/scalar — uses encode-circular)
;; (fact/zone "tf-1h" "tf-1h-up-strong")                ; 1h bullish
;; (fact/bare "tf-all-agree")                            ; all timeframes aligned
;; (fact/bare "tf-4h-agrees")                            ; 4h agrees with 5m

;; ── DISCOVERY ───────────────────────────────────────────────────────
;; Narrative is the only observer with calendar awareness. The manager
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
