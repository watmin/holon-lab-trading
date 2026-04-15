;; exhaustion-top.wat — weakening rallies, longer pauses, declining volume.
;; The uptrend is dying. Each rally does less. Each peak lingers longer.
;; The broker-observer sees this and the reckoner learns: exit.
;;
;; Price action: strong rally → peak → weak pullback → higher peak but
;; the rally was shorter, weaker, less volume. The peak lasts longer.
;; The next rally barely moves. The top is in.

(sequential

  ;; ── Phase 0: transition-up (the strong rally) ─────────────────
  (bundle
    (atom "phase-transition-up")
    (bind (atom "rec-duration")  (log 20.0))          ; 20 candles of strong buying
    (bind (atom "rec-move")      (linear 0.055 1.0))  ; +5.5% — powerful
    (bind (atom "rec-range")     (linear 0.058 1.0))
    (bind (atom "rec-volume")    (linear 1.8 1.0)))   ; heavy volume

  ;; ── Phase 1: peak (healthy consolidation) ─────────────────────
  (bundle
    (atom "phase-peak")
    (bind (atom "rec-duration")        (log 12.0))
    (bind (atom "rec-move")            (linear 0.003 1.0))
    (bind (atom "rec-range")           (linear 0.012 1.0))
    (bind (atom "rec-volume")          (linear 1.2 1.0))
    ;; prior-bundle
    (bind (atom "prior-duration-delta") (linear -0.40 1.0))
    (bind (atom "prior-move-delta")     (linear -0.052 1.0))
    (bind (atom "prior-volume-delta")   (linear -0.33 1.0)))

  ;; ── Phase 2: transition-down (shallow pullback) ───────────────
  (bundle
    (atom "phase-transition-down")
    (bind (atom "rec-duration")        (log 6.0))           ; quick pullback
    (bind (atom "rec-move")            (linear -0.012 1.0)) ; only -1.2%
    (bind (atom "rec-range")           (linear 0.015 1.0))
    (bind (atom "rec-volume")          (linear 0.7 1.0))    ; low volume — no panic
    ;; prior-bundle
    (bind (atom "prior-duration-delta") (linear -0.50 1.0))
    (bind (atom "prior-move-delta")     (linear -0.015 1.0))
    (bind (atom "prior-volume-delta")   (linear -0.42 1.0)))

  ;; ── Phase 3: valley (brief) ───────────────────────────────────
  (bundle
    (atom "phase-valley")
    (bind (atom "rec-duration")        (log 8.0))
    (bind (atom "rec-move")            (linear -0.002 1.0))
    (bind (atom "rec-range")           (linear 0.006 1.0))
    (bind (atom "rec-volume")          (linear 0.6 1.0))
    ;; prior-bundle
    (bind (atom "prior-duration-delta") (linear 0.33 1.0))
    (bind (atom "prior-move-delta")     (linear 0.010 1.0))
    (bind (atom "prior-volume-delta")   (linear -0.14 1.0)))

  ;; ── Phase 4: transition-up (THE WEAKENING RALLY) ──────────────
  ;; Prior same: transition-up at phase 0.
  ;; KEY: every same-delta is negative. The rally is weaker.
  (bundle
    (atom "phase-transition-up")
    (bind (atom "rec-duration")         (log 15.0))          ; shorter
    (bind (atom "rec-move")             (linear 0.028 1.0))  ; +2.8% — HALF the first rally
    (bind (atom "rec-range")            (linear 0.032 1.0))
    (bind (atom "rec-volume")           (linear 1.2 1.0))    ; less volume
    ;; prior-bundle (vs valley)
    (bind (atom "prior-duration-delta")  (linear 0.88 1.0))
    (bind (atom "prior-move-delta")      (linear 0.030 1.0))
    (bind (atom "prior-volume-delta")    (linear 1.0 1.0))
    ;; prior-same (vs first transition-up)
    (bind (atom "same-move-delta")       (linear -0.027 1.0)) ; 2.7% weaker move
    (bind (atom "same-duration-delta")   (linear -0.25 1.0))  ; 25% shorter
    (bind (atom "same-volume-delta")     (linear -0.33 1.0))) ; 33% less volume

  ;; ── Phase 5: peak (LINGERING) ─────────────────────────────────
  ;; Prior same: peak at phase 1.
  ;; KEY: longer duration, less volume. The market is hesitating.
  (bundle
    (atom "phase-peak")
    (bind (atom "rec-duration")         (log 22.0))          ; LONGER than the first peak
    (bind (atom "rec-move")             (linear 0.001 1.0))
    (bind (atom "rec-range")            (linear 0.014 1.0))
    (bind (atom "rec-volume")           (linear 0.9 1.0))    ; declining volume
    ;; prior-bundle (vs weakening rally)
    (bind (atom "prior-duration-delta")  (linear 0.47 1.0))
    (bind (atom "prior-move-delta")      (linear -0.027 1.0))
    (bind (atom "prior-volume-delta")    (linear -0.25 1.0))
    ;; prior-same (vs first peak)
    (bind (atom "same-move-delta")       (linear -0.002 1.0)) ; both flat
    (bind (atom "same-duration-delta")   (linear 0.83 1.0))   ; 83% LONGER — stalling
    (bind (atom "same-volume-delta")     (linear -0.25 1.0))) ; less volume — no interest

  ;; ── Phase 6: transition-down (the real selloff begins) ────────
  ;; Prior same: transition-down at phase 2.
  ;; KEY: STRONGER selloff than the first pullback.
  (bundle
    (atom "phase-transition-down")
    (bind (atom "rec-duration")         (log 10.0))
    (bind (atom "rec-move")             (linear -0.032 1.0)) ; -3.2% — MORE than the -1.2% pullback
    (bind (atom "rec-range")            (linear 0.038 1.0))
    (bind (atom "rec-volume")           (linear 1.5 1.0))    ; volume SPIKES on the selloff
    ;; prior-bundle (vs lingering peak)
    (bind (atom "prior-duration-delta")  (linear -0.55 1.0))
    (bind (atom "prior-move-delta")      (linear -0.033 1.0))
    (bind (atom "prior-volume-delta")    (linear 0.67 1.0))  ; volume jumped
    ;; prior-same (vs first pullback)
    (bind (atom "same-move-delta")       (linear -0.020 1.0)) ; 2% MORE selling
    (bind (atom "same-duration-delta")   (linear 0.67 1.0))   ; longer selloff
    (bind (atom "same-volume-delta")     (linear 1.14 1.0)))  ; DOUBLE the volume

;; The geometry: weakening rallies + lingering peaks + strengthening
;; selloffs with volume. The direction on the sphere where:
;;   transition-up same-move-delta < 0 (weaker rallies)
;;   phase-peak same-duration-delta > 0 (longer pauses)
;;   transition-down same-volume-delta > 0 (panic selling)
;; That direction IS exhaustion. The reckoner learns: Violence. Exit.
