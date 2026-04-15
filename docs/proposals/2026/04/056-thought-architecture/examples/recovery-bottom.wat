;; recovery-bottom.wat — three rising valleys from a crash.
;; Selloffs weakening. Rallies strengthening. The bottom is in.
;;
;; Price: crash → valley 3400 → bounce → valley 3500 → rally → valley 3580

;; ═══ Layer 1: Phase Records ═════════════════════════════════════════

(define phase-0 (bundle                            ;; the crash
  (atom "phase-transition-down")
  (bind (atom "rec-duration")  (log 30.0))
  (bind (atom "rec-move")      (linear -0.12 1.0))
  (bind (atom "rec-range")     (linear 0.14 1.0))
  (bind (atom "rec-volume")    (linear 2.5 1.0)))

(define phase-1 (bundle                            ;; valley at 3400 (capitulation)
  (atom "phase-valley")
  (bind (atom "rec-duration")        (log 25.0))
  (bind (atom "rec-move")            (linear -0.008 1.0))
  (bind (atom "rec-range")           (linear 0.015 1.0))
  (bind (atom "rec-volume")          (linear 1.8 1.0))
  (bind (atom "prior-duration-delta") (linear -0.17 1.0))
  (bind (atom "prior-move-delta")     (linear 0.112 1.0))
  (bind (atom "prior-volume-delta")   (linear -0.28 1.0)))

(define phase-2 (bundle                            ;; first bounce (tentative)
  (atom "phase-transition-up")
  (bind (atom "rec-duration")        (log 10.0))
  (bind (atom "rec-move")            (linear 0.025 1.0))
  (bind (atom "rec-range")           (linear 0.030 1.0))
  (bind (atom "rec-volume")          (linear 1.2 1.0))
  (bind (atom "prior-duration-delta") (linear -0.60 1.0))
  (bind (atom "prior-move-delta")     (linear 0.033 1.0))
  (bind (atom "prior-volume-delta")   (linear -0.33 1.0)))

(define phase-3 (bundle                            ;; weak peak
  (atom "phase-peak")
  (bind (atom "rec-duration")        (log 8.0))
  (bind (atom "rec-move")            (linear 0.001 1.0))
  (bind (atom "rec-range")           (linear 0.008 1.0))
  (bind (atom "rec-volume")          (linear 0.9 1.0))
  (bind (atom "prior-duration-delta") (linear -0.20 1.0))
  (bind (atom "prior-move-delta")     (linear -0.024 1.0))
  (bind (atom "prior-volume-delta")   (linear -0.25 1.0)))

(define phase-4 (bundle                            ;; pullback — MUCH weaker than crash
  (atom "phase-transition-down")
  (bind (atom "rec-duration")         (log 8.0))
  (bind (atom "rec-move")             (linear -0.018 1.0))
  (bind (atom "rec-range")            (linear 0.022 1.0))
  (bind (atom "rec-volume")           (linear 0.8 1.0))
  (bind (atom "prior-duration-delta")  (linear 0.0 1.0))
  (bind (atom "prior-move-delta")      (linear -0.019 1.0))
  (bind (atom "prior-volume-delta")    (linear -0.11 1.0))
  ;; prior-same (vs crash) — selling exhausted
  (bind (atom "same-move-delta")       (linear 0.102 1.0))   ;; 10.2% LESS selling
  (bind (atom "same-duration-delta")   (linear -0.73 1.0))   ;; 73% shorter
  (bind (atom "same-volume-delta")     (linear -0.68 1.0))));; 68% less volume

(define phase-5 (bundle                            ;; valley at 3500 — HIGHER LOW
  (atom "phase-valley")
  (bind (atom "rec-duration")         (log 15.0))
  (bind (atom "rec-move")             (linear -0.003 1.0))
  (bind (atom "rec-range")            (linear 0.008 1.0))
  (bind (atom "rec-volume")           (linear 0.9 1.0))
  (bind (atom "prior-duration-delta")  (linear 0.88 1.0))
  (bind (atom "prior-move-delta")      (linear 0.015 1.0))
  (bind (atom "prior-volume-delta")    (linear 0.13 1.0))
  ;; prior-same (vs valley at 3400) — higher low
  (bind (atom "same-move-delta")       (linear 0.005 1.0))   ;; rising
  (bind (atom "same-duration-delta")   (linear -0.40 1.0))   ;; less capitulation
  (bind (atom "same-volume-delta")     (linear -0.50 1.0))));; much less panic

(define phase-6 (bundle                            ;; stronger rally
  (atom "phase-transition-up")
  (bind (atom "rec-duration")         (log 14.0))
  (bind (atom "rec-move")             (linear 0.038 1.0))    ;; +3.8% vs +2.5%
  (bind (atom "rec-range")            (linear 0.042 1.0))
  (bind (atom "rec-volume")           (linear 1.5 1.0))
  (bind (atom "prior-duration-delta")  (linear -0.07 1.0))
  (bind (atom "prior-move-delta")      (linear 0.041 1.0))
  (bind (atom "prior-volume-delta")    (linear 0.67 1.0))
  ;; prior-same (vs first bounce) — STRONGER
  (bind (atom "same-move-delta")       (linear 0.013 1.0))   ;; 1.3% stronger
  (bind (atom "same-duration-delta")   (linear 0.40 1.0))    ;; more sustained
  (bind (atom "same-volume-delta")     (linear 0.25 1.0))) ;; growing conviction

(define phase-7 (bundle                            ;; peak
  (atom "phase-peak")
  (bind (atom "rec-duration")         (log 10.0))
  (bind (atom "rec-move")             (linear 0.002 1.0))
  (bind (atom "rec-range")            (linear 0.010 1.0))
  (bind (atom "rec-volume")           (linear 1.0 1.0))
  (bind (atom "prior-duration-delta")  (linear -0.29 1.0))
  (bind (atom "prior-move-delta")      (linear -0.036 1.0))
  (bind (atom "prior-volume-delta")    (linear -0.33 1.0))
  ;; prior-same (vs first peak)
  (bind (atom "same-move-delta")       (linear 0.001 1.0))
  (bind (atom "same-duration-delta")   (linear 0.25 1.0))
  (bind (atom "same-volume-delta")     (linear 0.11 1.0)))

(define phase-8 (bundle                            ;; shallower pullback
  (atom "phase-transition-down")
  (bind (atom "rec-duration")         (log 6.0))
  (bind (atom "rec-move")             (linear -0.011 1.0))   ;; -1.1% vs -1.8%
  (bind (atom "rec-range")            (linear 0.014 1.0))
  (bind (atom "rec-volume")           (linear 0.6 1.0))
  (bind (atom "prior-duration-delta")  (linear -0.40 1.0))
  (bind (atom "prior-move-delta")      (linear -0.013 1.0))
  (bind (atom "prior-volume-delta")    (linear -0.40 1.0))
  ;; prior-same (vs first pullback) — LESS selling
  (bind (atom "same-move-delta")       (linear 0.007 1.0))
  (bind (atom "same-duration-delta")   (linear -0.25 1.0))
  (bind (atom "same-volume-delta")     (linear -0.25 1.0)))

(define phase-9 (bundle                            ;; valley at 3580 — ANOTHER higher low
  (atom "phase-valley")
  (bind (atom "rec-duration")         (log 10.0))
  (bind (atom "rec-move")             (linear -0.002 1.0))
  (bind (atom "rec-range")            (linear 0.006 1.0))
  (bind (atom "rec-volume")           (linear 0.7 1.0))
  (bind (atom "prior-duration-delta")  (linear 0.67 1.0))
  (bind (atom "prior-move-delta")      (linear 0.009 1.0))
  (bind (atom "prior-volume-delta")    (linear 0.17 1.0))
  ;; prior-same (vs valley at 3500) — higher low again
  (bind (atom "same-move-delta")       (linear 0.001 1.0))   ;; rising
  (bind (atom "same-duration-delta")   (linear -0.33 1.0))   ;; shorter — less fear
  (bind (atom "same-volume-delta")     (linear -0.22 1.0))));; confidence

;; ═══ Layer 2: Trigrams ══════════════════════════════════════════════

(define tri-0 (bind (bind phase-0 (permute phase-1 1)) (permute phase-2 2)))  ;; crash→capitulation→bounce
(define tri-1 (bind (bind phase-1 (permute phase-2 1)) (permute phase-3 2)))  ;; capitulation→bounce→peak
(define tri-2 (bind (bind phase-2 (permute phase-3 1)) (permute phase-4 2)))  ;; bounce→peak→pullback
(define tri-3 (bind (bind phase-3 (permute phase-4 1)) (permute phase-5 2)))  ;; peak→pullback→higher-valley
(define tri-4 (bind (bind phase-4 (permute phase-5 1)) (permute phase-6 2)))  ;; pullback→valley→stronger-rally
(define tri-5 (bind (bind phase-5 (permute phase-6 1)) (permute phase-7 2)))  ;; valley→rally→peak
(define tri-6 (bind (bind phase-6 (permute phase-7 1)) (permute phase-8 2)))  ;; rally→peak→shallow-pullback
(define tri-7 (bind (bind phase-7 (permute phase-8 1)) (permute phase-9 2)))  ;; peak→pullback→higher-valley

;; ═══ Layer 3: Bigram-Pairs ══════════════════════════════════════════

(define pair-0 (bind tri-0 tri-1))  ;; crash cycle THEN capitulation resolves
(define pair-1 (bind tri-1 tri-2))  ;; first recovery THEN test
(define pair-2 (bind tri-2 tri-3))  ;; test THEN higher valley forms
(define pair-3 (bind tri-3 tri-4))  ;; higher valley THEN stronger rally
(define pair-4 (bind tri-4 tri-5))  ;; rally builds THEN peak forms
(define pair-5 (bind tri-5 tri-6))  ;; peak THEN shallow pullback
(define pair-6 (bind tri-6 tri-7))  ;; pullback THEN another higher valley

;; ═══ Layer 4: Rhythm ════════════════════════════════════════════════

(define rhythm (bundle pair-0 pair-1 pair-2 pair-3 pair-4 pair-5 pair-6))

;; Three valleys with positive same-move-delta (rising lows).
;; Transition-ups with positive same-move-delta (strengthening rallies).
;; Transition-downs with positive same-move-delta (weaker selloffs).
;;
;; The deltas carry the progression. The first valley has no same-delta.
;; The second says "I am higher than the last." The third says the same.
;; The bundle holds all the pairs. The direction on the sphere where
;; "valley + positive same-delta" and "transition-up + positive same-delta"
;; compound IS recovery. The reckoner learns: Hold. Grace is coming.
