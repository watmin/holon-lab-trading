;; breakdown.wat — lower high after higher highs. The pattern breaks.
;; Higher lows (valleys rising) but rallies weakening and peaks lingering.
;; The squeeze. The direction depends on which side gives first.
;;
;; Price: valley 3700 → peak 3900 → valley 3780 → peak 3870 (lower!)

;; ═══ Layer 1: Phase Records ═════════════════════════════════════════

(define phase-0 (bundle
  (atom "phase-valley")
  (bind (atom "rec-duration")  (log 20.0))
  (bind (atom "rec-move")      (linear -0.004 1.0))
  (bind (atom "rec-range")     (linear 0.009 1.0))
  (bind (atom "rec-volume")    (linear 0.8 1.0)))

(define phase-1 (bundle
  (atom "phase-transition-up")
  (bind (atom "rec-duration")        (log 16.0))
  (bind (atom "rec-move")            (linear 0.054 1.0))    ;; strong +5.4%
  (bind (atom "rec-range")           (linear 0.058 1.0))
  (bind (atom "rec-volume")          (linear 1.6 1.0))
  (bind (atom "prior-duration-delta") (linear -0.20 1.0))
  (bind (atom "prior-move-delta")     (linear 0.058 1.0))
  (bind (atom "prior-volume-delta")   (linear 1.0 1.0)))

(define phase-2 (bundle
  (atom "phase-peak")
  (bind (atom "rec-duration")        (log 14.0))
  (bind (atom "rec-move")            (linear 0.002 1.0))
  (bind (atom "rec-range")           (linear 0.011 1.0))
  (bind (atom "rec-volume")          (linear 1.1 1.0))
  (bind (atom "prior-duration-delta") (linear -0.13 1.0))
  (bind (atom "prior-move-delta")     (linear -0.052 1.0))
  (bind (atom "prior-volume-delta")   (linear -0.31 1.0)))

(define phase-3 (bundle
  (atom "phase-transition-down")
  (bind (atom "rec-duration")        (log 10.0))
  (bind (atom "rec-move")            (linear -0.031 1.0))
  (bind (atom "rec-range")           (linear 0.035 1.0))
  (bind (atom "rec-volume")          (linear 1.3 1.0))
  (bind (atom "prior-duration-delta") (linear -0.29 1.0))
  (bind (atom "prior-move-delta")     (linear -0.033 1.0))
  (bind (atom "prior-volume-delta")   (linear 0.18 1.0)))

(define phase-4 (bundle                            ;; valley at 3780 — HIGHER LOW
  (atom "phase-valley")
  (bind (atom "rec-duration")         (log 12.0))
  (bind (atom "rec-move")             (linear -0.002 1.0))
  (bind (atom "rec-range")            (linear 0.007 1.0))
  (bind (atom "rec-volume")           (linear 0.7 1.0))
  (bind (atom "prior-duration-delta")  (linear 0.20 1.0))
  (bind (atom "prior-move-delta")      (linear 0.029 1.0))
  (bind (atom "prior-volume-delta")    (linear -0.46 1.0))
  ;; prior-same (vs valley at 3700) — support rising
  (bind (atom "same-move-delta")       (linear 0.002 1.0))   ;; higher low
  (bind (atom "same-duration-delta")   (linear -0.40 1.0))
  (bind (atom "same-volume-delta")     (linear -0.13 1.0)))

(define phase-5 (bundle                            ;; transition-up — WEAKER rally
  (atom "phase-transition-up")
  (bind (atom "rec-duration")         (log 14.0))
  (bind (atom "rec-move")             (linear 0.024 1.0))    ;; only +2.4% vs 5.4%
  (bind (atom "rec-range")            (linear 0.028 1.0))
  (bind (atom "rec-volume")           (linear 1.1 1.0))
  (bind (atom "prior-duration-delta")  (linear 0.17 1.0))
  (bind (atom "prior-move-delta")      (linear 0.026 1.0))
  (bind (atom "prior-volume-delta")    (linear 0.57 1.0))
  ;; prior-same (vs first rally) — weakening
  (bind (atom "same-move-delta")       (linear -0.030 1.0))  ;; 3% WEAKER
  (bind (atom "same-duration-delta")   (linear -0.13 1.0))
  (bind (atom "same-volume-delta")     (linear -0.31 1.0)))

(define phase-6 (bundle                            ;; peak at 3870 — THE LOWER HIGH
  (atom "phase-peak")
  (bind (atom "rec-duration")         (log 18.0))            ;; lingering
  (bind (atom "rec-move")             (linear 0.001 1.0))
  (bind (atom "rec-range")            (linear 0.013 1.0))
  (bind (atom "rec-volume")           (linear 0.8 1.0))
  (bind (atom "prior-duration-delta")  (linear 0.29 1.0))
  (bind (atom "prior-move-delta")      (linear -0.023 1.0))
  (bind (atom "prior-volume-delta")    (linear -0.27 1.0))
  ;; prior-same (vs peak at 3900) — hesitation
  (bind (atom "same-move-delta")       (linear -0.001 1.0))
  (bind (atom "same-duration-delta")   (linear 0.29 1.0))    ;; longer pause
  (bind (atom "same-volume-delta")     (linear -0.27 1.0))));; no buyers

;; ═══ Layer 2: Trigrams ══════════════════════════════════════════════

(define tri-0 (bind (bind phase-0 (permute phase-1 1)) (permute phase-2 2)))  ;; valley→rally→peak
(define tri-1 (bind (bind phase-1 (permute phase-2 1)) (permute phase-3 2)))  ;; rally→peak→selloff
(define tri-2 (bind (bind phase-2 (permute phase-3 1)) (permute phase-4 2)))  ;; peak→selloff→higher-valley
(define tri-3 (bind (bind phase-3 (permute phase-4 1)) (permute phase-5 2)))  ;; selloff→valley→weak-rally
(define tri-4 (bind (bind phase-4 (permute phase-5 1)) (permute phase-6 2)))  ;; valley→weak-rally→lower-peak

;; ═══ Layer 3: Bigram-Pairs ══════════════════════════════════════════

(define pair-0 (bind tri-0 tri-1))  ;; strong cycle THEN top forms
(define pair-1 (bind tri-1 tri-2))  ;; top THEN selloff to higher valley
(define pair-2 (bind tri-2 tri-3))  ;; higher valley THEN weak rally
(define pair-3 (bind tri-3 tri-4))  ;; weak rally THEN lower peak

;; ═══ Layer 4: Rhythm ════════════════════════════════════════════════

(define rhythm (bundle pair-0 pair-1 pair-2 pair-3))

;; The contradiction in the deltas IS the signal:
;;   valley same-move-delta > 0 (higher lows — support holds)
;;   transition-up same-move-delta < 0 (weaker rallies — demand fading)
;;   phase-peak same-duration-delta > 0 (longer hesitation — no conviction)
;;   phase-peak same-volume-delta < 0 (no buyers)
;;
;; This is the squeeze. The reckoner sees opposing forces.
;; The geometry points to a region of uncertainty — neither strong
;; Grace nor strong Violence. The conviction is low. The broker
;; holds cautiously or exits with low confidence. The next phase
;; decides the direction.
