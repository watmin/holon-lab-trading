;; choppy-range.wat — peaks and valleys at similar levels. No trend.
;; The market is going nowhere. Each peak is near the last peak.
;; Each valley is near the last valley. The transitions are short
;; and weak. The broker-observer learns: this is noise, not signal.

(sequential

  ;; ── Phase 0: peak at 3850 ─────────────────────────────────────
  (bundle
    (atom "phase-peak")
    (bind (atom "rec-duration")  (log 10.0))
    (bind (atom "rec-move")      (linear 0.001 1.0))
    (bind (atom "rec-range")     (linear 0.008 1.0))
    (bind (atom "rec-volume")    (linear 0.9 1.0)))

  ;; ── Phase 1: transition-down ──────────────────────────────────
  (bundle
    (atom "phase-transition-down")
    (bind (atom "rec-duration")        (log 7.0))
    (bind (atom "rec-move")            (linear -0.013 1.0))
    (bind (atom "rec-range")           (linear 0.016 1.0))
    (bind (atom "rec-volume")          (linear 0.7 1.0))
    ;; prior-bundle (vs peak)
    (bind (atom "prior-duration-delta") (linear -0.30 1.0))
    (bind (atom "prior-move-delta")     (linear -0.014 1.0))
    (bind (atom "prior-volume-delta")   (linear -0.22 1.0)))

  ;; ── Phase 2: valley at 3800 ───────────────────────────────────
  (bundle
    (atom "phase-valley")
    (bind (atom "rec-duration")        (log 12.0))
    (bind (atom "rec-move")            (linear -0.002 1.0))
    (bind (atom "rec-range")           (linear 0.006 1.0))
    (bind (atom "rec-volume")          (linear 0.6 1.0))
    ;; prior-bundle (vs transition-down)
    (bind (atom "prior-duration-delta") (linear 0.71 1.0))
    (bind (atom "prior-move-delta")     (linear 0.011 1.0))
    (bind (atom "prior-volume-delta")   (linear -0.14 1.0)))

  ;; ── Phase 3: transition-up ────────────────────────────────────
  (bundle
    (atom "phase-transition-up")
    (bind (atom "rec-duration")        (log 8.0))
    (bind (atom "rec-move")            (linear 0.016 1.0))  ; weak rally
    (bind (atom "rec-range")           (linear 0.018 1.0))
    (bind (atom "rec-volume")          (linear 0.8 1.0))
    ;; prior-bundle (vs valley)
    (bind (atom "prior-duration-delta") (linear -0.33 1.0))
    (bind (atom "prior-move-delta")     (linear 0.018 1.0))
    (bind (atom "prior-volume-delta")   (linear 0.33 1.0)))

  ;; ── Phase 4: peak at 3860 ─────────────────────────────────────
  ;; Prior same: peak at 3850.
  ;; KEY: same-move-delta near zero. Same level. No progress.
  (bundle
    (atom "phase-peak")
    (bind (atom "rec-duration")         (log 11.0))
    (bind (atom "rec-move")             (linear 0.002 1.0))
    (bind (atom "rec-range")            (linear 0.009 1.0))
    (bind (atom "rec-volume")           (linear 0.85 1.0))
    ;; prior-bundle
    (bind (atom "prior-duration-delta")  (linear 0.38 1.0))
    (bind (atom "prior-move-delta")      (linear -0.014 1.0))
    (bind (atom "prior-volume-delta")    (linear 0.06 1.0))
    ;; prior-same (vs peak at 3850)
    (bind (atom "same-move-delta")       (linear 0.001 1.0))  ; virtually identical
    (bind (atom "same-duration-delta")   (linear 0.10 1.0))   ; similar duration
    (bind (atom "same-volume-delta")     (linear -0.06 1.0))) ; similar volume

  ;; ── Phase 5: transition-down ──────────────────────────────────
  ;; Prior same: transition-down at phase 1.
  ;; Same magnitude. Same duration. Same volume. Chop.
  (bundle
    (atom "phase-transition-down")
    (bind (atom "rec-duration")         (log 8.0))
    (bind (atom "rec-move")             (linear -0.015 1.0))
    (bind (atom "rec-range")            (linear 0.018 1.0))
    (bind (atom "rec-volume")           (linear 0.75 1.0))
    ;; prior-bundle
    (bind (atom "prior-duration-delta")  (linear -0.27 1.0))
    (bind (atom "prior-move-delta")      (linear -0.017 1.0))
    (bind (atom "prior-volume-delta")    (linear -0.12 1.0))
    ;; prior-same (vs first transition-down)
    (bind (atom "same-move-delta")       (linear -0.002 1.0)) ; same magnitude
    (bind (atom "same-duration-delta")   (linear 0.14 1.0))   ; similar duration
    (bind (atom "same-volume-delta")     (linear 0.07 1.0)))  ; similar volume

  ;; ── Phase 6: valley at 3795 ───────────────────────────────────
  ;; Prior same: valley at 3800.
  ;; Virtually identical. No trend.
  (bundle
    (atom "phase-valley")
    (bind (atom "rec-duration")         (log 14.0))
    (bind (atom "rec-move")             (linear -0.001 1.0))
    (bind (atom "rec-range")            (linear 0.005 1.0))
    (bind (atom "rec-volume")           (linear 0.55 1.0))
    ;; prior-bundle
    (bind (atom "prior-duration-delta")  (linear 0.75 1.0))
    (bind (atom "prior-move-delta")      (linear 0.014 1.0))
    (bind (atom "prior-volume-delta")    (linear -0.27 1.0))
    ;; prior-same (vs valley at 3800)
    (bind (atom "same-move-delta")       (linear 0.001 1.0))  ; same level
    (bind (atom "same-duration-delta")   (linear 0.17 1.0))   ; similar
    (bind (atom "same-volume-delta")     (linear -0.08 1.0))) ; dying volume

;; The geometry: all same-deltas near zero. The peaks don't progress.
;; The valleys don't progress. The transitions are weak and symmetrical.
;; The direction on the sphere where all deltas cluster around zero IS
;; "range-bound." The reckoner learns: this region has low conviction.
;; Neither Hold nor Exit is strongly predicted. The broker does nothing.
