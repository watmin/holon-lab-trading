;; ── vocab/keltner.wat — Keltner Channels, Bollinger position, squeeze ──
;;
;; Band position scalars and squeeze detection.
;; All values pre-computed on the Candle struct.
;;
;; Profile: structure

(require facts)

(define (eval-keltner candles)
  "Keltner, Bollinger position, and squeeze facts.
   Returns empty if Keltner bands are zero (insufficient data)."
  (let ((now (last candles)))
    (when (and (> (:kelt-upper now) 0.0) (> (:kelt-lower now) 0.0))
      (let ((close    (:close now))
            (ku       (:kelt-upper now))
            (kl       (:kelt-lower now))
            (kp       (:kelt-pos now))
            (bp       (:bb-pos now))
            (sq       (:squeeze now)))
        (append
          ;; Close vs Keltner bands — breakout detection
          (cond
            ((> close ku) (list (fact/comparison "above" "close" "keltner-upper")))
            ((< close kl) (list (fact/comparison "below" "close" "keltner-lower")))
            (else (list)))

          ;; Channel position scalars
          (list (fact/scalar "kelt-pos" (clamp kp 0.0 1.0) 1.0)
                (fact/scalar "bb-pos"   (clamp bp 0.0 1.0) 1.0))

          ;; Squeeze — BB inside Keltner means volatility compression
          (if sq
              (list (fact/zone "volatility" "squeeze"))
              (list)))))))

;; ── What keltner does NOT do ───────────────────────────────────
;; - Does NOT compute bands (pre-computed on Candle)
;; - Does NOT detect band walks (consecutive touches — future work)
;; - Pure function. Candles in, facts out.
