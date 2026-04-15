;; choppy-range.wat — peaks and valleys at similar levels. No trend.
;;
;; All same-deltas near zero. No progression. The reckoner sees noise.

;; ═══ Phase records ══════════════════════════════════════════════════

(define phase-0 (bundle
  (atom "phase-peak")
  (bind (atom "rec-duration")  (log 10.0))
  (bind (atom "rec-move")      (linear 0.001 1.0))
  (bind (atom "rec-range")     (linear 0.008 1.0))
  (bind (atom "rec-volume")    (linear 0.9 1.0))))

(define phase-1 (bundle
  (atom "phase-transition-down")
  (bind (atom "rec-duration")        (log 7.0))
  (bind (atom "rec-move")            (linear -0.013 1.0))
  (bind (atom "rec-range")           (linear 0.016 1.0))
  (bind (atom "rec-volume")          (linear 0.7 1.0))
  (bind (atom "prior-duration-delta") (linear -0.30 1.0))
  (bind (atom "prior-move-delta")     (linear -0.014 1.0))
  (bind (atom "prior-volume-delta")   (linear -0.22 1.0))))

(define phase-2 (bundle
  (atom "phase-valley")
  (bind (atom "rec-duration")        (log 12.0))
  (bind (atom "rec-move")            (linear -0.002 1.0))
  (bind (atom "rec-range")           (linear 0.006 1.0))
  (bind (atom "rec-volume")          (linear 0.6 1.0))
  (bind (atom "prior-duration-delta") (linear 0.71 1.0))
  (bind (atom "prior-move-delta")     (linear 0.011 1.0))
  (bind (atom "prior-volume-delta")   (linear -0.14 1.0))))

(define phase-3 (bundle
  (atom "phase-transition-up")
  (bind (atom "rec-duration")        (log 8.0))
  (bind (atom "rec-move")            (linear 0.016 1.0))
  (bind (atom "rec-range")           (linear 0.018 1.0))
  (bind (atom "rec-volume")          (linear 0.8 1.0))
  (bind (atom "prior-duration-delta") (linear -0.33 1.0))
  (bind (atom "prior-move-delta")     (linear 0.018 1.0))
  (bind (atom "prior-volume-delta")   (linear 0.33 1.0))))

(define phase-4 (bundle                                    ;; same level as phase-0
  (atom "phase-peak")
  (bind (atom "rec-duration")         (log 11.0))
  (bind (atom "rec-move")             (linear 0.002 1.0))
  (bind (atom "rec-range")            (linear 0.009 1.0))
  (bind (atom "rec-volume")           (linear 0.85 1.0))
  (bind (atom "prior-duration-delta")  (linear 0.38 1.0))
  (bind (atom "prior-move-delta")      (linear -0.014 1.0))
  (bind (atom "prior-volume-delta")    (linear 0.06 1.0))
  (bind (atom "same-move-delta")       (linear 0.001 1.0))  ;; ~zero
  (bind (atom "same-duration-delta")   (linear 0.10 1.0))   ;; ~zero
  (bind (atom "same-volume-delta")     (linear -0.06 1.0))))

(define phase-5 (bundle                                    ;; same as phase-1
  (atom "phase-transition-down")
  (bind (atom "rec-duration")         (log 8.0))
  (bind (atom "rec-move")             (linear -0.015 1.0))
  (bind (atom "rec-range")            (linear 0.018 1.0))
  (bind (atom "rec-volume")           (linear 0.75 1.0))
  (bind (atom "prior-duration-delta")  (linear -0.27 1.0))
  (bind (atom "prior-move-delta")      (linear -0.017 1.0))
  (bind (atom "prior-volume-delta")    (linear -0.12 1.0))
  (bind (atom "same-move-delta")       (linear -0.002 1.0)) ;; ~zero
  (bind (atom "same-duration-delta")   (linear 0.14 1.0))   ;; ~zero
  (bind (atom "same-volume-delta")     (linear 0.07 1.0))))

(define phase-6 (bundle                                    ;; same level as phase-2
  (atom "phase-valley")
  (bind (atom "rec-duration")         (log 14.0))
  (bind (atom "rec-move")             (linear -0.001 1.0))
  (bind (atom "rec-range")            (linear 0.005 1.0))
  (bind (atom "rec-volume")           (linear 0.55 1.0))
  (bind (atom "prior-duration-delta")  (linear 0.75 1.0))
  (bind (atom "prior-move-delta")      (linear 0.014 1.0))
  (bind (atom "prior-volume-delta")    (linear -0.27 1.0))
  (bind (atom "same-move-delta")       (linear 0.001 1.0))  ;; ~zero
  (bind (atom "same-duration-delta")   (linear 0.17 1.0))   ;; ~zero
  (bind (atom "same-volume-delta")     (linear -0.08 1.0))))

;; ═══ Trigrams ═══════════════════════════════════════════════════════

(define tri-0 (bind (bind phase-0 (permute phase-1 1)) (permute phase-2 2)))
(define tri-1 (bind (bind phase-1 (permute phase-2 1)) (permute phase-3 2)))
(define tri-2 (bind (bind phase-2 (permute phase-3 1)) (permute phase-4 2)))
(define tri-3 (bind (bind phase-3 (permute phase-4 1)) (permute phase-5 2)))
(define tri-4 (bind (bind phase-4 (permute phase-5 1)) (permute phase-6 2)))

;; ═══ The rhythm ═════════════════════════════════════════════════════

(define rhythm
  (bundle
    (bind tri-0 tri-1)
    (bind tri-1 tri-2)
    (bind tri-2 tri-3)
    (bind tri-3 tri-4)))

;; All same-deltas cluster around zero. The trigrams repeat — similar
;; shapes produce similar vectors. The pairs repeat. The bundle is
;; dense around one direction: range-bound. Low conviction. The broker
;; does nothing. Doing nothing in chop is Grace.
