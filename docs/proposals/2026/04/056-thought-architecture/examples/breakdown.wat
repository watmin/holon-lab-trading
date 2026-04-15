;; breakdown.wat — lower high after higher highs. The pattern breaks.
;; The market made higher highs, then failed. The latest peak is
;; LOWER than the previous peak. This is the signal.
;;
;; Price: valley 3700 → peak 3900 → valley 3780 → peak 3870 (lower!)

(sequential

  ;; ── Phase 0: valley at 3700 ────────────────────────────────────
  (bundle
    (atom "phase-valley")
    (bind (atom "rec-duration")  (log 20.0))
    (bind (atom "rec-move")      (linear -0.004 1.0))
    (bind (atom "rec-range")     (linear 0.009 1.0))
    (bind (atom "rec-volume")    (linear 0.8 1.0)))

  ;; ── Phase 1: transition-up to 3900 ────────────────────────────
  (bundle
    (atom "phase-transition-up")
    (bind (atom "rec-duration")        (log 16.0))
    (bind (atom "rec-move")            (linear 0.054 1.0))  ; strong +5.4%
    (bind (atom "rec-range")           (linear 0.058 1.0))
    (bind (atom "rec-volume")          (linear 1.6 1.0))
    ;; prior-bundle (vs valley)
    (bind (atom "prior-duration-delta") (linear -0.20 1.0))
    (bind (atom "prior-move-delta")     (linear 0.058 1.0))
    (bind (atom "prior-volume-delta")   (linear 1.0 1.0)))

  ;; ── Phase 2: peak at 3900 ─────────────────────────────────────
  (bundle
    (atom "phase-peak")
    (bind (atom "rec-duration")        (log 14.0))
    (bind (atom "rec-move")            (linear 0.002 1.0))
    (bind (atom "rec-range")           (linear 0.011 1.0))
    (bind (atom "rec-volume")          (linear 1.1 1.0))
    ;; prior-bundle (vs rally)
    (bind (atom "prior-duration-delta") (linear -0.13 1.0))
    (bind (atom "prior-move-delta")     (linear -0.052 1.0))
    (bind (atom "prior-volume-delta")   (linear -0.31 1.0)))

  ;; ── Phase 3: transition-down to 3780 ──────────────────────────
  (bundle
    (atom "phase-transition-down")
    (bind (atom "rec-duration")        (log 10.0))
    (bind (atom "rec-move")            (linear -0.031 1.0))
    (bind (atom "rec-range")           (linear 0.035 1.0))
    (bind (atom "rec-volume")          (linear 1.3 1.0))
    ;; prior-bundle (vs peak)
    (bind (atom "prior-duration-delta") (linear -0.29 1.0))
    (bind (atom "prior-move-delta")     (linear -0.033 1.0))
    (bind (atom "prior-volume-delta")   (linear 0.18 1.0)))

  ;; ── Phase 4: valley at 3780 ───────────────────────────────────
  ;; Prior same: valley at 3700.
  ;; Higher low — still looks bullish on the valley side.
  (bundle
    (atom "phase-valley")
    (bind (atom "rec-duration")         (log 12.0))
    (bind (atom "rec-move")             (linear -0.002 1.0))
    (bind (atom "rec-range")            (linear 0.007 1.0))
    (bind (atom "rec-volume")           (linear 0.7 1.0))
    ;; prior-bundle (vs transition-down)
    (bind (atom "prior-duration-delta")  (linear 0.20 1.0))
    (bind (atom "prior-move-delta")      (linear 0.029 1.0))
    (bind (atom "prior-volume-delta")    (linear -0.46 1.0))
    ;; prior-same (vs valley at 3700)
    (bind (atom "same-move-delta")       (linear 0.002 1.0))  ; higher low — positive
    (bind (atom "same-duration-delta")   (linear -0.40 1.0))  ; shorter — less selling pressure
    (bind (atom "same-volume-delta")     (linear -0.13 1.0)))

  ;; ── Phase 5: transition-up to 3870 ────────────────────────────
  ;; Prior same: transition-up to 3900.
  ;; WEAKER rally. Less move, less volume.
  (bundle
    (atom "phase-transition-up")
    (bind (atom "rec-duration")         (log 14.0))
    (bind (atom "rec-move")             (linear 0.024 1.0))   ; only +2.4% vs 5.4%
    (bind (atom "rec-range")            (linear 0.028 1.0))
    (bind (atom "rec-volume")           (linear 1.1 1.0))     ; weaker volume
    ;; prior-bundle (vs valley)
    (bind (atom "prior-duration-delta")  (linear 0.17 1.0))
    (bind (atom "prior-move-delta")      (linear 0.026 1.0))
    (bind (atom "prior-volume-delta")    (linear 0.57 1.0))
    ;; prior-same (vs first rally)
    (bind (atom "same-move-delta")       (linear -0.030 1.0)) ; 3% WEAKER
    (bind (atom "same-duration-delta")   (linear -0.13 1.0))
    (bind (atom "same-volume-delta")     (linear -0.31 1.0))) ; less conviction

  ;; ── Phase 6: peak at 3870 — THE LOWER HIGH ────────────────────
  ;; Prior same: peak at 3900.
  ;; The peak's own move is flat (it's a pause). But the PRICE is
  ;; lower than the last peak. The prior-same deltas capture this
  ;; through the volume and duration changes. The absolute price
  ;; difference is encoded in the transition-up's weaker move.
  (bundle
    (atom "phase-peak")
    (bind (atom "rec-duration")         (log 18.0))          ; lingering
    (bind (atom "rec-move")             (linear 0.001 1.0))
    (bind (atom "rec-range")            (linear 0.013 1.0))
    (bind (atom "rec-volume")           (linear 0.8 1.0))    ; drying up
    ;; prior-bundle (vs weaker rally)
    (bind (atom "prior-duration-delta")  (linear 0.29 1.0))
    (bind (atom "prior-move-delta")      (linear -0.023 1.0))
    (bind (atom "prior-volume-delta")    (linear -0.27 1.0))
    ;; prior-same (vs peak at 3900)
    (bind (atom "same-move-delta")       (linear -0.001 1.0)) ; both flat
    (bind (atom "same-duration-delta")   (linear 0.29 1.0))   ; LONGER pause — hesitation
    (bind (atom "same-volume-delta")     (linear -0.27 1.0))) ; LESS volume — no buyers

;; The geometry: the combination of:
;;   transition-up same-move-delta < 0 (weaker rally)
;;   phase-peak same-duration-delta > 0 (longer hesitation)
;;   phase-peak same-volume-delta < 0 (no buyers)
;;   phase-valley same-move-delta > 0 (higher low — support holds)
;;
;; This is the classic lower-high-with-higher-low pattern.
;; A SQUEEZE. The breakdown direction depends on which side gives first.
;; The reckoner sees this region of the sphere and learns: Violence
;; is likely. The pattern is breaking. Get out.
