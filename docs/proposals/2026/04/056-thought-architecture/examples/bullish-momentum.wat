;; bullish-momentum.wat — three rising valleys, strengthening rallies.
;; The classic uptrend. Higher highs, higher lows, increasing conviction.
;;
;; Price action: 3700 → valley → 3850 → peak → 3780 → valley → 3920 → peak → 3840 → valley → 3980
;;
;; The broker-observer sees this sequence and the reckoner learns:
;; "this pattern produces Grace. Hold."

(sequential

  ;; ── Phase 0: valley at 3700 ────────────────────────────────────
  ;; First record. No priors. Own properties only.
  (bundle
    (atom "phase-valley")
    (bind (atom "rec-duration")  (log 18.0))          ; 18 candles consolidating
    (bind (atom "rec-move")      (linear -0.005 1.0)) ; barely moved — flat pause
    (bind (atom "rec-range")     (linear 0.008 1.0))  ; tight range
    (bind (atom "rec-volume")    (linear 0.9 1.0)))   ; low volume

  ;; ── Phase 1: transition-up from 3700 → 3850 ───────────────────
  ;; Prior bundle: the valley. Prior same: none (first transition-up).
  (bundle
    (atom "phase-transition-up")
    (bind (atom "rec-duration")        (log 12.0))          ; 12 candles rising
    (bind (atom "rec-move")            (linear 0.041 1.0))  ; +4.1% move
    (bind (atom "rec-range")           (linear 0.045 1.0))  ; range matches move
    (bind (atom "rec-volume")          (linear 1.4 1.0))    ; increasing volume
    ;; prior-bundle deltas (vs valley at 3700)
    (bind (atom "prior-duration-delta") (linear -0.33 1.0)) ; 33% shorter than the valley
    (bind (atom "prior-move-delta")     (linear 0.046 1.0)) ; moved 4.6% more than the valley's -0.5%
    (bind (atom "prior-volume-delta")   (linear 0.56 1.0))) ; 56% more volume than the valley

  ;; ── Phase 2: peak at 3850 ─────────────────────────────────────
  ;; Prior bundle: transition-up. Prior same: none (first peak).
  (bundle
    (atom "phase-peak")
    (bind (atom "rec-duration")        (log 15.0))
    (bind (atom "rec-move")            (linear 0.002 1.0))  ; flat — it's a peak
    (bind (atom "rec-range")           (linear 0.010 1.0))
    (bind (atom "rec-volume")          (linear 1.1 1.0))
    ;; prior-bundle deltas (vs transition-up)
    (bind (atom "prior-duration-delta") (linear 0.25 1.0))  ; 25% longer than the rally
    (bind (atom "prior-move-delta")     (linear -0.039 1.0)); moved 3.9% less (it's a pause)
    (bind (atom "prior-volume-delta")   (linear -0.21 1.0))); volume dropped 21%

  ;; ── Phase 3: transition-down from 3850 → 3780 ─────────────────
  ;; Prior bundle: peak. Prior same: none (first transition-down).
  (bundle
    (atom "phase-transition-down")
    (bind (atom "rec-duration")        (log 8.0))           ; short pullback
    (bind (atom "rec-move")            (linear -0.018 1.0)) ; -1.8% retracement
    (bind (atom "rec-range")           (linear 0.022 1.0))
    (bind (atom "rec-volume")          (linear 0.8 1.0))    ; declining volume on pullback
    ;; prior-bundle deltas (vs peak)
    (bind (atom "prior-duration-delta") (linear -0.47 1.0)) ; 47% shorter than the peak
    (bind (atom "prior-move-delta")     (linear -0.020 1.0)); moved 2% more (downward) than peak's flat
    (bind (atom "prior-volume-delta")   (linear -0.27 1.0))); less volume

  ;; ── Phase 4: valley at 3780 ───────────────────────────────────
  ;; Prior bundle: transition-down. Prior same: valley at 3700.
  ;; KEY: same-move-delta is POSITIVE — this valley is HIGHER than the last.
  (bundle
    (atom "phase-valley")
    (bind (atom "rec-duration")         (log 14.0))
    (bind (atom "rec-move")             (linear -0.003 1.0))  ; flat pause
    (bind (atom "rec-range")            (linear 0.007 1.0))
    (bind (atom "rec-volume")           (linear 0.85 1.0))
    ;; prior-bundle deltas (vs transition-down)
    (bind (atom "prior-duration-delta")  (linear 0.75 1.0))   ; 75% longer than the pullback
    (bind (atom "prior-move-delta")      (linear 0.015 1.0))  ; moved less than the transition
    (bind (atom "prior-volume-delta")    (linear 0.06 1.0))
    ;; prior-same-phase deltas (vs valley at 3700)
    (bind (atom "same-move-delta")       (linear 0.002 1.0))  ; slightly higher valley
    (bind (atom "same-duration-delta")   (linear -0.22 1.0))  ; shorter consolidation
    (bind (atom "same-volume-delta")     (linear -0.06 1.0))) ; similar volume

  ;; ── Phase 5: transition-up from 3780 → 3920 ───────────────────
  ;; Prior bundle: valley. Prior same: transition-up 3700→3850.
  ;; KEY: same-move-delta is POSITIVE — this rally is STRONGER.
  (bundle
    (atom "phase-transition-up")
    (bind (atom "rec-duration")         (log 14.0))
    (bind (atom "rec-move")             (linear 0.037 1.0))   ; +3.7%
    (bind (atom "rec-range")            (linear 0.040 1.0))
    (bind (atom "rec-volume")           (linear 1.6 1.0))     ; even more volume
    ;; prior-bundle deltas (vs valley at 3780)
    (bind (atom "prior-duration-delta")  (linear 0.0 1.0))    ; same duration
    (bind (atom "prior-move-delta")      (linear 0.040 1.0))  ; moved much more than the valley
    (bind (atom "prior-volume-delta")    (linear 0.88 1.0))   ; 88% more volume
    ;; prior-same-phase deltas (vs transition-up 3700→3850)
    (bind (atom "same-move-delta")       (linear -0.004 1.0)) ; slightly weaker move
    (bind (atom "same-duration-delta")   (linear 0.17 1.0))   ; slightly longer
    (bind (atom "same-volume-delta")     (linear 0.14 1.0)))  ; more volume — growing conviction

  ;; ── Phase 6: peak at 3920 ─────────────────────────────────────
  ;; Prior bundle: transition-up. Prior same: peak at 3850.
  ;; KEY: same-move-delta near zero (both are flat pauses) but the
  ;; PRICE is higher. The peak-delta is encoded in the prior-same
  ;; relative to the peak's move property.
  (bundle
    (atom "phase-peak")
    (bind (atom "rec-duration")         (log 10.0))
    (bind (atom "rec-move")             (linear 0.001 1.0))
    (bind (atom "rec-range")            (linear 0.009 1.0))
    (bind (atom "rec-volume")           (linear 1.2 1.0))
    ;; prior-bundle deltas (vs transition-up)
    (bind (atom "prior-duration-delta")  (linear -0.29 1.0))
    (bind (atom "prior-move-delta")      (linear -0.036 1.0))
    (bind (atom "prior-volume-delta")    (linear -0.25 1.0))
    ;; prior-same-phase deltas (vs peak at 3850)
    (bind (atom "same-move-delta")       (linear -0.001 1.0)) ; both flat — similar
    (bind (atom "same-duration-delta")   (linear -0.33 1.0))  ; shorter pause — eager
    (bind (atom "same-volume-delta")     (linear 0.09 1.0)))) ; slightly more volume

;; The geometry: the Sequential encodes positional order via permutation.
;; The pattern "valley with positive same-delta, transition-up with
;; growing volume, peak with shorter duration" points in a specific
;; direction on the sphere. That direction IS "bullish momentum."
;; The scalars carry the strength. The reckoner learns: this direction
;; at this magnitude → Grace. Hold.
