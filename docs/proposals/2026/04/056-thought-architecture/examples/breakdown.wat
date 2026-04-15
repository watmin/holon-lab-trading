;; breakdown.wat — lower high after higher highs. The pattern breaks.
;;
;; Opposing forces: valleys rising (support holds) but rallies weakening
;; and peaks lingering (demand fading). The squeeze.

;; ═══ Phase records ══════════════════════════════════════════════════

(define phase-0 (bundle
  (atom "phase-valley")
  (bind (atom "rec-duration")  (log 20.0))
  (bind (atom "rec-move")      (linear -0.004 1.0))
  (bind (atom "rec-range")     (linear 0.009 1.0))
  (bind (atom "rec-volume")    (linear 0.8 1.0))))

(define phase-1 (bundle
  (atom "phase-transition-up")
  (bind (atom "rec-duration")        (log 16.0))
  (bind (atom "rec-move")            (linear 0.054 1.0))
  (bind (atom "rec-range")           (linear 0.058 1.0))
  (bind (atom "rec-volume")          (linear 1.6 1.0))
  (bind (atom "prior-duration-delta") (linear -0.20 1.0))
  (bind (atom "prior-move-delta")     (linear 0.058 1.0))
  (bind (atom "prior-volume-delta")   (linear 1.0 1.0))))

(define phase-2 (bundle
  (atom "phase-peak")
  (bind (atom "rec-duration")        (log 14.0))
  (bind (atom "rec-move")            (linear 0.002 1.0))
  (bind (atom "rec-range")           (linear 0.011 1.0))
  (bind (atom "rec-volume")          (linear 1.1 1.0))
  (bind (atom "prior-duration-delta") (linear -0.13 1.0))
  (bind (atom "prior-move-delta")     (linear -0.052 1.0))
  (bind (atom "prior-volume-delta")   (linear -0.31 1.0))))

(define phase-3 (bundle
  (atom "phase-transition-down")
  (bind (atom "rec-duration")        (log 10.0))
  (bind (atom "rec-move")            (linear -0.031 1.0))
  (bind (atom "rec-range")           (linear 0.035 1.0))
  (bind (atom "rec-volume")          (linear 1.3 1.0))
  (bind (atom "prior-duration-delta") (linear -0.29 1.0))
  (bind (atom "prior-move-delta")     (linear -0.033 1.0))
  (bind (atom "prior-volume-delta")   (linear 0.18 1.0))))

(define phase-4 (bundle                                    ;; HIGHER LOW
  (atom "phase-valley")
  (bind (atom "rec-duration")         (log 12.0))
  (bind (atom "rec-move")             (linear -0.002 1.0))
  (bind (atom "rec-range")            (linear 0.007 1.0))
  (bind (atom "rec-volume")           (linear 0.7 1.0))
  (bind (atom "prior-duration-delta")  (linear 0.20 1.0))
  (bind (atom "prior-move-delta")      (linear 0.029 1.0))
  (bind (atom "prior-volume-delta")    (linear -0.46 1.0))
  (bind (atom "same-move-delta")       (linear 0.002 1.0))  ;; higher low
  (bind (atom "same-duration-delta")   (linear -0.40 1.0))
  (bind (atom "same-volume-delta")     (linear -0.13 1.0))))

(define phase-5 (bundle                                    ;; WEAKER rally
  (atom "phase-transition-up")
  (bind (atom "rec-duration")         (log 14.0))
  (bind (atom "rec-move")             (linear 0.024 1.0))   ;; +2.4% vs 5.4%
  (bind (atom "rec-range")            (linear 0.028 1.0))
  (bind (atom "rec-volume")           (linear 1.1 1.0))
  (bind (atom "prior-duration-delta")  (linear 0.17 1.0))
  (bind (atom "prior-move-delta")      (linear 0.026 1.0))
  (bind (atom "prior-volume-delta")    (linear 0.57 1.0))
  (bind (atom "same-move-delta")       (linear -0.030 1.0)) ;; 3% weaker
  (bind (atom "same-duration-delta")   (linear -0.13 1.0))
  (bind (atom "same-volume-delta")     (linear -0.31 1.0))))

(define phase-6 (bundle                                    ;; THE LOWER HIGH
  (atom "phase-peak")
  (bind (atom "rec-duration")         (log 18.0))           ;; lingering
  (bind (atom "rec-move")             (linear 0.001 1.0))
  (bind (atom "rec-range")            (linear 0.013 1.0))
  (bind (atom "rec-volume")           (linear 0.8 1.0))
  (bind (atom "prior-duration-delta")  (linear 0.29 1.0))
  (bind (atom "prior-move-delta")      (linear -0.023 1.0))
  (bind (atom "prior-volume-delta")    (linear -0.27 1.0))
  (bind (atom "same-move-delta")       (linear -0.001 1.0))
  (bind (atom "same-duration-delta")   (linear 0.29 1.0))   ;; longer pause
  (bind (atom "same-volume-delta")     (linear -0.27 1.0)))) ;; no buyers

;; ═══ Trigrams ═══════════════════════════════════════════════════════

(define tri-0 (bind (bind phase-0 (permute phase-1 1)) (permute phase-2 2)))
(define tri-1 (bind (bind phase-1 (permute phase-2 1)) (permute phase-3 2)))
(define tri-2 (bind (bind phase-2 (permute phase-3 1)) (permute phase-4 2)))
(define tri-3 (bind (bind phase-3 (permute phase-4 1)) (permute phase-5 2)))
(define tri-4 (bind (bind phase-4 (permute phase-5 1)) (permute phase-6 2)))

;; ═══ The rhythm ══════════════════════════════════════════════════��══

(define rhythm
  (bundle
    (bind tri-0 tri-1)
    (bind tri-1 tri-2)
    (bind tri-2 tri-3)
    (bind tri-3 tri-4)))

;; Opposing deltas — the contradiction IS the signal:
;;   valley same-move-delta > 0 (higher lows — support holds)
;;   transition-up same-move-delta < 0 (weaker rallies — demand fading)
;;   phase-peak same-duration-delta > 0 (longer hesitation)
;;   phase-peak same-volume-delta < 0 (no buyers)
;; The squeeze. Low conviction. The next phase decides.
