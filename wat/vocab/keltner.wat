;; ── vocab/keltner.wat — Keltner Channels, Bollinger position, squeeze ──
;;
;; Band position scalars and squeeze detection.
;; All values pre-computed on the Candle struct.
;;
;; Expert profile: structure

(require vocab/mod)

;; ── Atoms introduced ───────────────────────────────────────────

;; Indicators:   close, keltner-upper, keltner-lower, kelt-pos, bb-pos, volatility
;; Predicates:   above, below
;; Zones:        squeeze

;; ── Channel definitions (from candle.wat) ──────────────────────
;;
;; Keltner: EMA(20) +/- 1.5 * ATR(14)
;; Bollinger: SMA(20) +/- 2 * StdDev(20)
;; Keltner position: (close - lower) / (upper - lower) — [0, 1]
;; Bollinger position: (close - bb_lower) / (bb_upper - bb_lower) — [0, 1]
;; Squeeze: BB width < Keltner width — volatility compression

;; ── Facts produced ─────────────────────────────────────────────

; rune:gaze(phantom) — fact/comparison is not in the wat language
; rune:gaze(phantom) — fact/scalar is not in the wat language
; rune:gaze(phantom) — fact/zone is not in the wat language
(define (eval-keltner candles)
  "Keltner, Bollinger position, and squeeze facts.
   Returns empty if Keltner bands are zero (insufficient data)."

  ;; Close vs Keltner bands
  ;; Comparison: (above close keltner-upper) — breakout above
  ;;              (below close keltner-lower) — breakout below
  ;; Only emitted on breakout. No fact when inside channel.
  (when (> close kelt-upper)
    (fact/comparison "above" "close" "keltner-upper"))
  (when (< close kelt-lower)
    (fact/comparison "below" "close" "keltner-lower"))

  ;; Keltner position — where is price within the channel?
  ;; Scalar: (kelt-pos value) clamped [0, 1], scale 1.0
  (fact/scalar "kelt-pos" (clamp kelt-pos 0.0 1.0) 1.0)

  ;; Bollinger position — where is price within the bands?
  ;; Scalar: (bb-pos value) clamped [0, 1], scale 1.0
  ;; 0.0 = lower band. 1.0 = upper band.
  (fact/scalar "bb-pos" (clamp bb-pos 0.0 1.0) 1.0)

  ;; Squeeze — BB inside Keltner means low volatility compression
  ;; Zone: (at volatility squeeze)
  ;; Binary. No threshold — it's a geometric containment test.
  (when squeeze
    (fact/zone "volatility" "squeeze")))

;; ── Guard: kelt_upper > 0 AND kelt_lower > 0 ──────────────────
;; During warmup, Keltner bands are zero. No facts emitted.

;; ── What keltner does NOT do ───────────────────────────────────
;; - Does NOT compute bands (pre-computed on Candle)
;; - Does NOT detect band walks (consecutive touches — future work)
;; - Does NOT import holon or create vectors
;; - Pure function. Candles in, facts out.
