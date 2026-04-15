;; exhaustion-top.wat — weakening rallies, longer pauses, declining volume.
;;
;; One AST. Same atoms as bullish-momentum.wat. The scalars tell a
;; different story — the deltas are negative where bullish was positive.

;; ═══ Phase records ══════════════════════════════════════════════════

(define phase-0 (bundle                                    ;; strong rally
  (atom "phase-transition-up")
  (bind (atom "rec-duration")  (log 20.0))
  (bind (atom "rec-move")      (linear 0.055 1.0))
  (bind (atom "rec-range")     (linear 0.058 1.0))
  (bind (atom "rec-volume")    (linear 1.8 1.0))))

(define phase-1 (bundle                                    ;; healthy peak
  (atom "phase-peak")
  (bind (atom "rec-duration")        (log 12.0))
  (bind (atom "rec-move")            (linear 0.003 1.0))
  (bind (atom "rec-range")           (linear 0.012 1.0))
  (bind (atom "rec-volume")          (linear 1.2 1.0))
  (bind (atom "prior-duration-delta") (linear -0.40 1.0))
  (bind (atom "prior-move-delta")     (linear -0.052 1.0))
  (bind (atom "prior-volume-delta")   (linear -0.33 1.0))))

(define phase-2 (bundle                                    ;; shallow pullback
  (atom "phase-transition-down")
  (bind (atom "rec-duration")        (log 6.0))
  (bind (atom "rec-move")            (linear -0.012 1.0))
  (bind (atom "rec-range")           (linear 0.015 1.0))
  (bind (atom "rec-volume")          (linear 0.7 1.0))
  (bind (atom "prior-duration-delta") (linear -0.50 1.0))
  (bind (atom "prior-move-delta")     (linear -0.015 1.0))
  (bind (atom "prior-volume-delta")   (linear -0.42 1.0))))

(define phase-3 (bundle                                    ;; brief valley
  (atom "phase-valley")
  (bind (atom "rec-duration")        (log 8.0))
  (bind (atom "rec-move")            (linear -0.002 1.0))
  (bind (atom "rec-range")           (linear 0.006 1.0))
  (bind (atom "rec-volume")          (linear 0.6 1.0))
  (bind (atom "prior-duration-delta") (linear 0.33 1.0))
  (bind (atom "prior-move-delta")     (linear 0.010 1.0))
  (bind (atom "prior-volume-delta")   (linear -0.14 1.0))))

(define phase-4 (bundle                                    ;; WEAKENING rally
  (atom "phase-transition-up")
  (bind (atom "rec-duration")         (log 15.0))
  (bind (atom "rec-move")             (linear 0.028 1.0))   ;; half the first rally
  (bind (atom "rec-range")            (linear 0.032 1.0))
  (bind (atom "rec-volume")           (linear 1.2 1.0))
  (bind (atom "prior-duration-delta")  (linear 0.88 1.0))
  (bind (atom "prior-move-delta")      (linear 0.030 1.0))
  (bind (atom "prior-volume-delta")    (linear 1.0 1.0))
  (bind (atom "same-move-delta")       (linear -0.027 1.0)) ;; 2.7% weaker
  (bind (atom "same-duration-delta")   (linear -0.25 1.0))
  (bind (atom "same-volume-delta")     (linear -0.33 1.0))))

(define phase-5 (bundle                                    ;; LINGERING peak
  (atom "phase-peak")
  (bind (atom "rec-duration")         (log 22.0))           ;; longer
  (bind (atom "rec-move")             (linear 0.001 1.0))
  (bind (atom "rec-range")            (linear 0.014 1.0))
  (bind (atom "rec-volume")           (linear 0.9 1.0))
  (bind (atom "prior-duration-delta")  (linear 0.47 1.0))
  (bind (atom "prior-move-delta")      (linear -0.027 1.0))
  (bind (atom "prior-volume-delta")    (linear -0.25 1.0))
  (bind (atom "same-move-delta")       (linear -0.002 1.0))
  (bind (atom "same-duration-delta")   (linear 0.83 1.0))   ;; 83% longer
  (bind (atom "same-volume-delta")     (linear -0.25 1.0))))

(define phase-6 (bundle                                    ;; STRENGTHENING selloff
  (atom "phase-transition-down")
  (bind (atom "rec-duration")         (log 10.0))
  (bind (atom "rec-move")             (linear -0.032 1.0))  ;; more than the first pullback
  (bind (atom "rec-range")            (linear 0.038 1.0))
  (bind (atom "rec-volume")           (linear 1.5 1.0))     ;; volume spikes
  (bind (atom "prior-duration-delta")  (linear -0.55 1.0))
  (bind (atom "prior-move-delta")      (linear -0.033 1.0))
  (bind (atom "prior-volume-delta")    (linear 0.67 1.0))
  (bind (atom "same-move-delta")       (linear -0.020 1.0)) ;; 2% more selling
  (bind (atom "same-duration-delta")   (linear 0.67 1.0))
  (bind (atom "same-volume-delta")     (linear 1.14 1.0))))  ;; double the volume

;; ═══ Trigrams ═══════════════════════════════════════════════════════

(define tri-0 (bind (bind phase-0 (permute phase-1 1)) (permute phase-2 2)))
(define tri-1 (bind (bind phase-1 (permute phase-2 1)) (permute phase-3 2)))
(define tri-2 (bind (bind phase-2 (permute phase-3 1)) (permute phase-4 2)))
(define tri-3 (bind (bind phase-3 (permute phase-4 1)) (permute phase-5 2)))
(define tri-4 (bind (bind phase-4 (permute phase-5 1)) (permute phase-6 2)))

;; ═══ The rhythm ════════════════════════════════════════════════��════

(define rhythm
  (bundle
    (bind tri-0 tri-1)
    (bind tri-1 tri-2)
    (bind tri-2 tri-3)
    (bind tri-3 tri-4)))

;; Weakening rallies (negative same-move-delta on transition-up).
;; Lingering peaks (positive same-duration-delta on phase-peak).
;; Strengthening selloffs (positive same-volume-delta on transition-down).
;; The direction on the sphere → Violence. Exit.
