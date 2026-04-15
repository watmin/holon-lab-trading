;; recovery-bottom.wat — three rising valleys from a crash.
;; The market crashed. Now the lows are getting higher. Each valley
;; is shallower than the last. The transitions-up are strengthening.
;; The broker-observer sees structural recovery.
;;
;; Price: crash → valley 3400 → bounce → valley 3500 → rally → valley 3580

(sequential

  ;; ── Phase 0: transition-down (the crash) ──────────────────────
  (bundle
    (atom "phase-transition-down")
    (bind (atom "rec-duration")  (log 30.0))           ; 30 candles of selling
    (bind (atom "rec-move")      (linear -0.12 1.0))   ; -12% crash
    (bind (atom "rec-range")     (linear 0.14 1.0))    ; huge range
    (bind (atom "rec-volume")    (linear 2.5 1.0)))    ; panic volume

  ;; ── Phase 1: valley at 3400 (the bottom) ──────────────────────
  (bundle
    (atom "phase-valley")
    (bind (atom "rec-duration")        (log 25.0))          ; long capitulation
    (bind (atom "rec-move")            (linear -0.008 1.0)) ; grinding lower
    (bind (atom "rec-range")           (linear 0.015 1.0))
    (bind (atom "rec-volume")          (linear 1.8 1.0))    ; still heavy volume
    ;; prior-bundle (vs crash)
    (bind (atom "prior-duration-delta") (linear -0.17 1.0))
    (bind (atom "prior-move-delta")     (linear 0.112 1.0)) ; much less movement than the crash
    (bind (atom "prior-volume-delta")   (linear -0.28 1.0)))

  ;; ── Phase 2: transition-up (first bounce) ─────────────────────
  (bundle
    (atom "phase-transition-up")
    (bind (atom "rec-duration")        (log 10.0))
    (bind (atom "rec-move")            (linear 0.025 1.0))  ; +2.5% — tentative
    (bind (atom "rec-range")           (linear 0.030 1.0))
    (bind (atom "rec-volume")          (linear 1.2 1.0))
    ;; prior-bundle (vs valley)
    (bind (atom "prior-duration-delta") (linear -0.60 1.0))
    (bind (atom "prior-move-delta")     (linear 0.033 1.0))
    (bind (atom "prior-volume-delta")   (linear -0.33 1.0)))

  ;; ── Phase 3: peak (weak) ──────────────────────────────────────
  (bundle
    (atom "phase-peak")
    (bind (atom "rec-duration")        (log 8.0))
    (bind (atom "rec-move")            (linear 0.001 1.0))
    (bind (atom "rec-range")           (linear 0.008 1.0))
    (bind (atom "rec-volume")          (linear 0.9 1.0))
    ;; prior-bundle
    (bind (atom "prior-duration-delta") (linear -0.20 1.0))
    (bind (atom "prior-move-delta")     (linear -0.024 1.0))
    (bind (atom "prior-volume-delta")   (linear -0.25 1.0)))

  ;; ── Phase 4: transition-down (pullback) ───────────────────────
  ;; Prior same: crash at phase 0.
  ;; KEY: MUCH weaker selloff. The selling is exhausted.
  (bundle
    (atom "phase-transition-down")
    (bind (atom "rec-duration")         (log 8.0))
    (bind (atom "rec-move")             (linear -0.018 1.0)) ; only -1.8% vs -12%
    (bind (atom "rec-range")            (linear 0.022 1.0))
    (bind (atom "rec-volume")           (linear 0.8 1.0))
    ;; prior-bundle (vs peak)
    (bind (atom "prior-duration-delta")  (linear 0.0 1.0))
    (bind (atom "prior-move-delta")      (linear -0.019 1.0))
    (bind (atom "prior-volume-delta")    (linear -0.11 1.0))
    ;; prior-same (vs crash)
    (bind (atom "same-move-delta")       (linear 0.102 1.0))  ; 10.2% LESS selling
    (bind (atom "same-duration-delta")   (linear -0.73 1.0))  ; 73% shorter
    (bind (atom "same-volume-delta")     (linear -0.68 1.0))) ; 68% less volume

  ;; ── Phase 5: valley at 3500 ───────────────────────────────────
  ;; Prior same: valley at 3400.
  ;; KEY: HIGHER LOW. positive same-move-delta.
  (bundle
    (atom "phase-valley")
    (bind (atom "rec-duration")         (log 15.0))
    (bind (atom "rec-move")             (linear -0.003 1.0))
    (bind (atom "rec-range")            (linear 0.008 1.0))
    (bind (atom "rec-volume")           (linear 0.9 1.0))
    ;; prior-bundle (vs pullback)
    (bind (atom "prior-duration-delta")  (linear 0.88 1.0))
    (bind (atom "prior-move-delta")      (linear 0.015 1.0))
    (bind (atom "prior-volume-delta")    (linear 0.13 1.0))
    ;; prior-same (vs valley at 3400)
    (bind (atom "same-move-delta")       (linear 0.005 1.0))  ; higher low
    (bind (atom "same-duration-delta")   (linear -0.40 1.0))  ; shorter capitulation
    (bind (atom "same-volume-delta")     (linear -0.50 1.0))) ; much less panic

  ;; ── Phase 6: transition-up (strengthening rally) ──────────────
  ;; Prior same: first bounce at phase 2.
  ;; KEY: STRONGER rally. More move, more volume.
  (bundle
    (atom "phase-transition-up")
    (bind (atom "rec-duration")         (log 14.0))
    (bind (atom "rec-move")             (linear 0.038 1.0))  ; +3.8% vs +2.5%
    (bind (atom "rec-range")            (linear 0.042 1.0))
    (bind (atom "rec-volume")           (linear 1.5 1.0))    ; stronger volume
    ;; prior-bundle (vs valley)
    (bind (atom "prior-duration-delta")  (linear -0.07 1.0))
    (bind (atom "prior-move-delta")      (linear 0.041 1.0))
    (bind (atom "prior-volume-delta")    (linear 0.67 1.0))
    ;; prior-same (vs first bounce)
    (bind (atom "same-move-delta")       (linear 0.013 1.0))  ; 1.3% STRONGER
    (bind (atom "same-duration-delta")   (linear 0.40 1.0))   ; longer — more sustained
    (bind (atom "same-volume-delta")     (linear 0.25 1.0)))  ; more volume — conviction growing

  ;; ── Phase 7: peak ─────────────────────────────────────────────
  ;; Prior same: peak at phase 3.
  (bundle
    (atom "phase-peak")
    (bind (atom "rec-duration")         (log 10.0))
    (bind (atom "rec-move")             (linear 0.002 1.0))
    (bind (atom "rec-range")            (linear 0.010 1.0))
    (bind (atom "rec-volume")           (linear 1.0 1.0))
    ;; prior-bundle
    (bind (atom "prior-duration-delta")  (linear -0.29 1.0))
    (bind (atom "prior-move-delta")      (linear -0.036 1.0))
    (bind (atom "prior-volume-delta")    (linear -0.33 1.0))
    ;; prior-same
    (bind (atom "same-move-delta")       (linear 0.001 1.0))
    (bind (atom "same-duration-delta")   (linear 0.25 1.0))
    (bind (atom "same-volume-delta")     (linear 0.11 1.0)))

  ;; ── Phase 8: transition-down (shallower pullback) ─────────────
  ;; Prior same: pullback at phase 4.
  (bundle
    (atom "phase-transition-down")
    (bind (atom "rec-duration")         (log 6.0))
    (bind (atom "rec-move")             (linear -0.011 1.0)) ; -1.1% vs -1.8%
    (bind (atom "rec-range")            (linear 0.014 1.0))
    (bind (atom "rec-volume")           (linear 0.6 1.0))
    ;; prior-bundle
    (bind (atom "prior-duration-delta")  (linear -0.40 1.0))
    (bind (atom "prior-move-delta")      (linear -0.013 1.0))
    (bind (atom "prior-volume-delta")    (linear -0.40 1.0))
    ;; prior-same (vs pullback at phase 4)
    (bind (atom "same-move-delta")       (linear 0.007 1.0))  ; LESS selling
    (bind (atom "same-duration-delta")   (linear -0.25 1.0))  ; shorter
    (bind (atom "same-volume-delta")     (linear -0.25 1.0))) ; less panic

  ;; ── Phase 9: valley at 3580 ───────────────────────────────────
  ;; Prior same: valley at 3500.
  ;; KEY: ANOTHER higher low. The pattern holds.
  (bundle
    (atom "phase-valley")
    (bind (atom "rec-duration")         (log 10.0))
    (bind (atom "rec-move")             (linear -0.002 1.0))
    (bind (atom "rec-range")            (linear 0.006 1.0))
    (bind (atom "rec-volume")           (linear 0.7 1.0))
    ;; prior-bundle
    (bind (atom "prior-duration-delta")  (linear 0.67 1.0))
    (bind (atom "prior-move-delta")      (linear 0.009 1.0))
    (bind (atom "prior-volume-delta")    (linear 0.17 1.0))
    ;; prior-same (vs valley at 3500)
    (bind (atom "same-move-delta")       (linear 0.001 1.0))  ; higher low again
    (bind (atom "same-duration-delta")   (linear -0.33 1.0))  ; shorter — less fear
    (bind (atom "same-volume-delta")     (linear -0.22 1.0))) ; less panic — confidence

;; The geometry: three valleys with positive same-move-delta (rising lows).
;; Transition-ups with positive same-move-delta (strengthening rallies).
;; Transition-downs with positive same-move-delta (weaker selloffs).
;; The direction on the sphere where ALL of these compound IS recovery.
;; The reckoner learns: Hold. Grace is coming.
