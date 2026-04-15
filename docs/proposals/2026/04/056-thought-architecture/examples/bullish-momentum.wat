;; bullish-momentum.wat — three rising valleys, strengthening rallies.
;; The classic uptrend. Higher highs, higher lows, increasing conviction.
;;
;; Encoding: bundled bigrams of trigrams.
;; - Each phase → bundle of facts + deltas → encode → one vector
;; - Trigram: 3 consecutive phases → bind+permute → one vector (one cycle)
;; - Bigram-pair: 2 consecutive trigrams → bind → one vector (cycle-to-cycle)
;; - Rhythm: bundle all pairs → one vector (the shape of the market)
;;
;; Price action: 3700 → 3850 → 3780 → 3920 → 3840 → 3980

;; ═══ Layer 1: Phase Records ═════════════════════════════════════════
;; Each phase encodes its own properties + deltas. One vector each.

(define phase-0 (bundle                            ;; valley at 3700
  (atom "phase-valley")
  (bind (atom "rec-duration")  (log 18.0))
  (bind (atom "rec-move")      (linear -0.005 1.0))
  (bind (atom "rec-range")     (linear 0.008 1.0))
  (bind (atom "rec-volume")    (linear 0.9 1.0)))

(define phase-1 (bundle                            ;; transition-up 3700→3850
  (atom "phase-transition-up")
  (bind (atom "rec-duration")        (log 12.0))
  (bind (atom "rec-move")            (linear 0.041 1.0))
  (bind (atom "rec-range")           (linear 0.045 1.0))
  (bind (atom "rec-volume")          (linear 1.4 1.0))
  ;; prior-bundle (vs valley)
  (bind (atom "prior-duration-delta") (linear -0.33 1.0))
  (bind (atom "prior-move-delta")     (linear 0.046 1.0))
  (bind (atom "prior-volume-delta")   (linear 0.56 1.0)))

(define phase-2 (bundle                            ;; peak at 3850
  (atom "phase-peak")
  (bind (atom "rec-duration")        (log 15.0))
  (bind (atom "rec-move")            (linear 0.002 1.0))
  (bind (atom "rec-range")           (linear 0.010 1.0))
  (bind (atom "rec-volume")          (linear 1.1 1.0))
  ;; prior-bundle (vs transition-up)
  (bind (atom "prior-duration-delta") (linear 0.25 1.0))
  (bind (atom "prior-move-delta")     (linear -0.039 1.0))
  (bind (atom "prior-volume-delta")   (linear -0.21 1.0)))

(define phase-3 (bundle                            ;; transition-down 3850→3780
  (atom "phase-transition-down")
  (bind (atom "rec-duration")        (log 8.0))
  (bind (atom "rec-move")            (linear -0.018 1.0))
  (bind (atom "rec-range")           (linear 0.022 1.0))
  (bind (atom "rec-volume")          (linear 0.8 1.0))
  ;; prior-bundle (vs peak)
  (bind (atom "prior-duration-delta") (linear -0.47 1.0))
  (bind (atom "prior-move-delta")     (linear -0.020 1.0))
  (bind (atom "prior-volume-delta")   (linear -0.27 1.0)))

(define phase-4 (bundle                            ;; valley at 3780
  (atom "phase-valley")
  (bind (atom "rec-duration")         (log 14.0))
  (bind (atom "rec-move")             (linear -0.003 1.0))
  (bind (atom "rec-range")            (linear 0.007 1.0))
  (bind (atom "rec-volume")           (linear 0.85 1.0))
  ;; prior-bundle (vs transition-down)
  (bind (atom "prior-duration-delta")  (linear 0.75 1.0))
  (bind (atom "prior-move-delta")      (linear 0.015 1.0))
  (bind (atom "prior-volume-delta")    (linear 0.06 1.0))
  ;; prior-same (vs valley at 3700) — HIGHER LOW
  (bind (atom "same-move-delta")       (linear 0.002 1.0))
  (bind (atom "same-duration-delta")   (linear -0.22 1.0))
  (bind (atom "same-volume-delta")     (linear -0.06 1.0)))

(define phase-5 (bundle                            ;; transition-up 3780→3920
  (atom "phase-transition-up")
  (bind (atom "rec-duration")         (log 14.0))
  (bind (atom "rec-move")             (linear 0.037 1.0))
  (bind (atom "rec-range")            (linear 0.040 1.0))
  (bind (atom "rec-volume")           (linear 1.6 1.0))
  ;; prior-bundle (vs valley)
  (bind (atom "prior-duration-delta")  (linear 0.0 1.0))
  (bind (atom "prior-move-delta")      (linear 0.040 1.0))
  (bind (atom "prior-volume-delta")    (linear 0.88 1.0))
  ;; prior-same (vs transition-up 3700→3850) — growing conviction
  (bind (atom "same-move-delta")       (linear -0.004 1.0))
  (bind (atom "same-duration-delta")   (linear 0.17 1.0))
  (bind (atom "same-volume-delta")     (linear 0.14 1.0)))

(define phase-6 (bundle                            ;; peak at 3920
  (atom "phase-peak")
  (bind (atom "rec-duration")         (log 10.0))
  (bind (atom "rec-move")             (linear 0.001 1.0))
  (bind (atom "rec-range")            (linear 0.009 1.0))
  (bind (atom "rec-volume")           (linear 1.2 1.0))
  ;; prior-bundle (vs transition-up)
  (bind (atom "prior-duration-delta")  (linear -0.29 1.0))
  (bind (atom "prior-move-delta")      (linear -0.036 1.0))
  (bind (atom "prior-volume-delta")    (linear -0.25 1.0))
  ;; prior-same (vs peak at 3850) — shorter pause, eager
  (bind (atom "same-move-delta")       (linear -0.001 1.0))
  (bind (atom "same-duration-delta")   (linear -0.33 1.0))
  (bind (atom "same-volume-delta")     (linear 0.09 1.0)))

;; ═══ Layer 2: Trigrams ══════════════════════════════════════════════
;; Sliding window of 3. Each trigram is one cycle: pause→move→pause.
;; Internal order via bind+permute.

(define tri-0 (bind (bind phase-0 (permute phase-1 1)) (permute phase-2 2)))  ;; valley→up→peak
(define tri-1 (bind (bind phase-1 (permute phase-2 1)) (permute phase-3 2)))  ;; up→peak→down
(define tri-2 (bind (bind phase-2 (permute phase-3 1)) (permute phase-4 2)))  ;; peak→down→valley
(define tri-3 (bind (bind phase-3 (permute phase-4 1)) (permute phase-5 2)))  ;; down→valley→up
(define tri-4 (bind (bind phase-4 (permute phase-5 1)) (permute phase-6 2)))  ;; valley→up→peak

;; ═══ Layer 3: Bigram-Pairs ══════════════════════════════════════════
;; "This cycle then that cycle." Ordered via bind.

(define pair-0 (bind tri-0 tri-1))  ;; valley→up→peak THEN up→peak→down
(define pair-1 (bind tri-1 tri-2))  ;; up→peak→down THEN peak→down→valley
(define pair-2 (bind tri-2 tri-3))  ;; peak→down→valley THEN down→valley→up
(define pair-3 (bind tri-3 tri-4))  ;; down→valley→up THEN valley→up→peak

;; ═══ Layer 4: Rhythm ════════════════════════════════════════════════
;; Bundle all pairs. One vector. One thought.

(define rhythm (bundle pair-0 pair-1 pair-2 pair-3))

;; pair-0 and pair-3 overlap through shared trigrams.
;; tri-0 (valley→up→peak) and tri-4 (valley→up→peak) have the SAME shape
;; but different scalars — the second valley is higher (same-move-delta > 0),
;; the second rally has more volume (same-volume-delta > 0).
;;
;; These similar-but-not-identical trigrams produce similar-but-not-identical
;; pairs. The bundle amplifies the common direction (bullish cycles) and
;; preserves the drift (strengthening conviction via the deltas).
;;
;; The reckoner sees: this direction on the sphere → Grace. Hold.
