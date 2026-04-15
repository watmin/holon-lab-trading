;; bullish-momentum.wat — three rising valleys, strengthening rallies.
;;
;; One AST. One encode call at the top. The cache handles subexpressions.
;; The defines are naming convenience — the encoder sees one tree.
;;
;; Price action: 3700 → 3850 → 3780 → 3920 → 3840 → 3980

;; ═══ Phase records ══════════════════════════════════════════════════

(define phase-0 (bundle                                    ;; valley at 3700
  (atom "phase-valley")
  (bind (atom "rec-duration")  (log 18.0))
  (bind (atom "rec-move")      (linear -0.005 1.0))
  (bind (atom "rec-range")     (linear 0.008 1.0))
  (bind (atom "rec-volume")    (linear 0.9 1.0))))

(define phase-1 (bundle                                    ;; transition-up 3700→3850
  (atom "phase-transition-up")
  (bind (atom "rec-duration")        (log 12.0))
  (bind (atom "rec-move")            (linear 0.041 1.0))
  (bind (atom "rec-range")           (linear 0.045 1.0))
  (bind (atom "rec-volume")          (linear 1.4 1.0))
  (bind (atom "prior-duration-delta") (linear -0.33 1.0))
  (bind (atom "prior-move-delta")     (linear 0.046 1.0))
  (bind (atom "prior-volume-delta")   (linear 0.56 1.0))))

(define phase-2 (bundle                                    ;; peak at 3850
  (atom "phase-peak")
  (bind (atom "rec-duration")        (log 15.0))
  (bind (atom "rec-move")            (linear 0.002 1.0))
  (bind (atom "rec-range")           (linear 0.010 1.0))
  (bind (atom "rec-volume")          (linear 1.1 1.0))
  (bind (atom "prior-duration-delta") (linear 0.25 1.0))
  (bind (atom "prior-move-delta")     (linear -0.039 1.0))
  (bind (atom "prior-volume-delta")   (linear -0.21 1.0))))

(define phase-3 (bundle                                    ;; transition-down 3850→3780
  (atom "phase-transition-down")
  (bind (atom "rec-duration")        (log 8.0))
  (bind (atom "rec-move")            (linear -0.018 1.0))
  (bind (atom "rec-range")           (linear 0.022 1.0))
  (bind (atom "rec-volume")          (linear 0.8 1.0))
  (bind (atom "prior-duration-delta") (linear -0.47 1.0))
  (bind (atom "prior-move-delta")     (linear -0.020 1.0))
  (bind (atom "prior-volume-delta")   (linear -0.27 1.0))))

(define phase-4 (bundle                                    ;; valley at 3780 — HIGHER LOW
  (atom "phase-valley")
  (bind (atom "rec-duration")         (log 14.0))
  (bind (atom "rec-move")             (linear -0.003 1.0))
  (bind (atom "rec-range")            (linear 0.007 1.0))
  (bind (atom "rec-volume")           (linear 0.85 1.0))
  (bind (atom "prior-duration-delta")  (linear 0.75 1.0))
  (bind (atom "prior-move-delta")      (linear 0.015 1.0))
  (bind (atom "prior-volume-delta")    (linear 0.06 1.0))
  (bind (atom "same-move-delta")       (linear 0.002 1.0))
  (bind (atom "same-duration-delta")   (linear -0.22 1.0))
  (bind (atom "same-volume-delta")     (linear -0.06 1.0))))

(define phase-5 (bundle                                    ;; transition-up 3780→3920
  (atom "phase-transition-up")
  (bind (atom "rec-duration")         (log 14.0))
  (bind (atom "rec-move")             (linear 0.037 1.0))
  (bind (atom "rec-range")            (linear 0.040 1.0))
  (bind (atom "rec-volume")           (linear 1.6 1.0))
  (bind (atom "prior-duration-delta")  (linear 0.0 1.0))
  (bind (atom "prior-move-delta")      (linear 0.040 1.0))
  (bind (atom "prior-volume-delta")    (linear 0.88 1.0))
  (bind (atom "same-move-delta")       (linear -0.004 1.0))
  (bind (atom "same-duration-delta")   (linear 0.17 1.0))
  (bind (atom "same-volume-delta")     (linear 0.14 1.0))))

(define phase-6 (bundle                                    ;; peak at 3920
  (atom "phase-peak")
  (bind (atom "rec-duration")         (log 10.0))
  (bind (atom "rec-move")             (linear 0.001 1.0))
  (bind (atom "rec-range")            (linear 0.009 1.0))
  (bind (atom "rec-volume")           (linear 1.2 1.0))
  (bind (atom "prior-duration-delta")  (linear -0.29 1.0))
  (bind (atom "prior-move-delta")      (linear -0.036 1.0))
  (bind (atom "prior-volume-delta")    (linear -0.25 1.0))
  (bind (atom "same-move-delta")       (linear -0.001 1.0))
  (bind (atom "same-duration-delta")   (linear -0.33 1.0))
  (bind (atom "same-volume-delta")     (linear 0.09 1.0))))

;; ═══ Trigrams ═══════════════════════════════════════════════════════

(define tri-0 (bind (bind phase-0 (permute phase-1 1)) (permute phase-2 2)))
(define tri-1 (bind (bind phase-1 (permute phase-2 1)) (permute phase-3 2)))
(define tri-2 (bind (bind phase-2 (permute phase-3 1)) (permute phase-4 2)))
(define tri-3 (bind (bind phase-3 (permute phase-4 1)) (permute phase-5 2)))
(define tri-4 (bind (bind phase-4 (permute phase-5 1)) (permute phase-6 2)))

;; ═══ The rhythm — one AST, one encode ═══════════════════════════════

(define rhythm
  (bundle
    (bind tri-0 tri-1)
    (bind tri-1 tri-2)
    (bind tri-2 tri-3)
    (bind tri-3 tri-4)))

;; Rising valleys (positive same-move-delta on phase-valley).
;; Growing volume on rallies (positive same-volume-delta on transition-up).
;; Shorter peaks (negative same-duration-delta on phase-peak).
;; The direction on the sphere → Grace. Hold.
