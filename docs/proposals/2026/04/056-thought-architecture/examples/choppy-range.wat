;; choppy-range.wat — peaks and valleys at similar levels. No trend.
;; All same-deltas near zero. Transitions weak and symmetrical.
;; The reckoner sees noise — low conviction in either direction.

;; ═══ Layer 1: Phase Records ═════════════════════════════════════════

(define phase-0 (bundle
  (atom "phase-peak")
  (bind (atom "rec-duration")  (log 10.0))
  (bind (atom "rec-move")      (linear 0.001 1.0))
  (bind (atom "rec-range")     (linear 0.008 1.0))
  (bind (atom "rec-volume")    (linear 0.9 1.0)))

(define phase-1 (bundle
  (atom "phase-transition-down")
  (bind (atom "rec-duration")        (log 7.0))
  (bind (atom "rec-move")            (linear -0.013 1.0))
  (bind (atom "rec-range")           (linear 0.016 1.0))
  (bind (atom "rec-volume")          (linear 0.7 1.0))
  (bind (atom "prior-duration-delta") (linear -0.30 1.0))
  (bind (atom "prior-move-delta")     (linear -0.014 1.0))
  (bind (atom "prior-volume-delta")   (linear -0.22 1.0)))

(define phase-2 (bundle
  (atom "phase-valley")
  (bind (atom "rec-duration")        (log 12.0))
  (bind (atom "rec-move")            (linear -0.002 1.0))
  (bind (atom "rec-range")           (linear 0.006 1.0))
  (bind (atom "rec-volume")          (linear 0.6 1.0))
  (bind (atom "prior-duration-delta") (linear 0.71 1.0))
  (bind (atom "prior-move-delta")     (linear 0.011 1.0))
  (bind (atom "prior-volume-delta")   (linear -0.14 1.0)))

(define phase-3 (bundle
  (atom "phase-transition-up")
  (bind (atom "rec-duration")        (log 8.0))
  (bind (atom "rec-move")            (linear 0.016 1.0))
  (bind (atom "rec-range")           (linear 0.018 1.0))
  (bind (atom "rec-volume")          (linear 0.8 1.0))
  (bind (atom "prior-duration-delta") (linear -0.33 1.0))
  (bind (atom "prior-move-delta")     (linear 0.018 1.0))
  (bind (atom "prior-volume-delta")   (linear 0.33 1.0)))

(define phase-4 (bundle                            ;; peak — same level as phase-0
  (atom "phase-peak")
  (bind (atom "rec-duration")         (log 11.0))
  (bind (atom "rec-move")             (linear 0.002 1.0))
  (bind (atom "rec-range")            (linear 0.009 1.0))
  (bind (atom "rec-volume")           (linear 0.85 1.0))
  (bind (atom "prior-duration-delta")  (linear 0.38 1.0))
  (bind (atom "prior-move-delta")      (linear -0.014 1.0))
  (bind (atom "prior-volume-delta")    (linear 0.06 1.0))
  ;; prior-same — virtually identical to first peak
  (bind (atom "same-move-delta")       (linear 0.001 1.0))   ;; ~zero
  (bind (atom "same-duration-delta")   (linear 0.10 1.0))    ;; ~zero
  (bind (atom "same-volume-delta")     (linear -0.06 1.0))));; ~zero

(define phase-5 (bundle                            ;; transition-down — same as phase-1
  (atom "phase-transition-down")
  (bind (atom "rec-duration")         (log 8.0))
  (bind (atom "rec-move")             (linear -0.015 1.0))
  (bind (atom "rec-range")            (linear 0.018 1.0))
  (bind (atom "rec-volume")           (linear 0.75 1.0))
  (bind (atom "prior-duration-delta")  (linear -0.27 1.0))
  (bind (atom "prior-move-delta")      (linear -0.017 1.0))
  (bind (atom "prior-volume-delta")    (linear -0.12 1.0))
  ;; prior-same — same magnitude, same duration
  (bind (atom "same-move-delta")       (linear -0.002 1.0))  ;; ~zero
  (bind (atom "same-duration-delta")   (linear 0.14 1.0))    ;; ~zero
  (bind (atom "same-volume-delta")     (linear 0.07 1.0))) ;; ~zero

(define phase-6 (bundle                            ;; valley — same level as phase-2
  (atom "phase-valley")
  (bind (atom "rec-duration")         (log 14.0))
  (bind (atom "rec-move")             (linear -0.001 1.0))
  (bind (atom "rec-range")            (linear 0.005 1.0))
  (bind (atom "rec-volume")           (linear 0.55 1.0))
  (bind (atom "prior-duration-delta")  (linear 0.75 1.0))
  (bind (atom "prior-move-delta")      (linear 0.014 1.0))
  (bind (atom "prior-volume-delta")    (linear -0.27 1.0))
  ;; prior-same — same level
  (bind (atom "same-move-delta")       (linear 0.001 1.0))   ;; ~zero
  (bind (atom "same-duration-delta")   (linear 0.17 1.0))    ;; ~zero
  (bind (atom "same-volume-delta")     (linear -0.08 1.0))));; dying volume

;; ═══ Layer 2: Trigrams ══════════════════════════════════════════════

(define tri-0 (bind (bind phase-0 (permute phase-1 1)) (permute phase-2 2)))
(define tri-1 (bind (bind phase-1 (permute phase-2 1)) (permute phase-3 2)))
(define tri-2 (bind (bind phase-2 (permute phase-3 1)) (permute phase-4 2)))
(define tri-3 (bind (bind phase-3 (permute phase-4 1)) (permute phase-5 2)))
(define tri-4 (bind (bind phase-4 (permute phase-5 1)) (permute phase-6 2)))

;; ═══ Layer 3: Bigram-Pairs ══════════════════════════════════════════

(define pair-0 (bind tri-0 tri-1))
(define pair-1 (bind tri-1 tri-2))
(define pair-2 (bind tri-2 tri-3))
(define pair-3 (bind tri-3 tri-4))

;; ═══ Layer 4: Rhythm ════════════════════════════════════════════════

(define rhythm (bundle pair-0 pair-1 pair-2 pair-3))

;; All same-deltas cluster around zero. No progression. No trend.
;; The trigrams repeat — similar shapes produce similar vectors.
;; The pairs repeat — similar transitions produce similar pairs.
;; The bundle is dense around one direction: "range-bound."
;;
;; The reckoner sees: this region of the sphere has low conviction.
;; Neither Hold nor Exit is strongly predicted. The broker does nothing.
;; This IS the correct answer — doing nothing in chop is Grace.
