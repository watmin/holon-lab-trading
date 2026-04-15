;; exhaustion-top.wat — weakening rallies, longer pauses, declining volume.
;; The uptrend is dying. Each rally does less. Each peak lingers longer.
;;
;; Encoding: bundled bigrams of trigrams.
;; The same encoding shape as bullish-momentum.wat, but the deltas tell
;; a different story. The scalars carry the exhaustion.

;; ═══ Layer 1: Phase Records ═════════════════════════════════════════

(define phase-0 (encode (bundle                            ;; transition-up (strong rally)
  (atom "phase-transition-up")
  (bind (atom "rec-duration")  (log 20.0))
  (bind (atom "rec-move")      (linear 0.055 1.0))
  (bind (atom "rec-range")     (linear 0.058 1.0))
  (bind (atom "rec-volume")    (linear 1.8 1.0)))))

(define phase-1 (encode (bundle                            ;; peak (healthy)
  (atom "phase-peak")
  (bind (atom "rec-duration")        (log 12.0))
  (bind (atom "rec-move")            (linear 0.003 1.0))
  (bind (atom "rec-range")           (linear 0.012 1.0))
  (bind (atom "rec-volume")          (linear 1.2 1.0))
  (bind (atom "prior-duration-delta") (linear -0.40 1.0))
  (bind (atom "prior-move-delta")     (linear -0.052 1.0))
  (bind (atom "prior-volume-delta")   (linear -0.33 1.0)))))

(define phase-2 (encode (bundle                            ;; transition-down (shallow pullback)
  (atom "phase-transition-down")
  (bind (atom "rec-duration")        (log 6.0))
  (bind (atom "rec-move")            (linear -0.012 1.0))
  (bind (atom "rec-range")           (linear 0.015 1.0))
  (bind (atom "rec-volume")          (linear 0.7 1.0))
  (bind (atom "prior-duration-delta") (linear -0.50 1.0))
  (bind (atom "prior-move-delta")     (linear -0.015 1.0))
  (bind (atom "prior-volume-delta")   (linear -0.42 1.0)))))

(define phase-3 (encode (bundle                            ;; valley (brief)
  (atom "phase-valley")
  (bind (atom "rec-duration")        (log 8.0))
  (bind (atom "rec-move")            (linear -0.002 1.0))
  (bind (atom "rec-range")           (linear 0.006 1.0))
  (bind (atom "rec-volume")          (linear 0.6 1.0))
  (bind (atom "prior-duration-delta") (linear 0.33 1.0))
  (bind (atom "prior-move-delta")     (linear 0.010 1.0))
  (bind (atom "prior-volume-delta")   (linear -0.14 1.0)))))

(define phase-4 (encode (bundle                            ;; transition-up (WEAKENING)
  (atom "phase-transition-up")
  (bind (atom "rec-duration")         (log 15.0))
  (bind (atom "rec-move")             (linear 0.028 1.0))    ;; HALF the first rally
  (bind (atom "rec-range")            (linear 0.032 1.0))
  (bind (atom "rec-volume")           (linear 1.2 1.0))
  (bind (atom "prior-duration-delta")  (linear 0.88 1.0))
  (bind (atom "prior-move-delta")      (linear 0.030 1.0))
  (bind (atom "prior-volume-delta")    (linear 1.0 1.0))
  ;; prior-same (vs first rally) — THE SIGNAL
  (bind (atom "same-move-delta")       (linear -0.027 1.0))  ;; 2.7% weaker
  (bind (atom "same-duration-delta")   (linear -0.25 1.0))   ;; shorter
  (bind (atom "same-volume-delta")     (linear -0.33 1.0)))));; less volume

(define phase-5 (encode (bundle                            ;; peak (LINGERING)
  (atom "phase-peak")
  (bind (atom "rec-duration")         (log 22.0))            ;; LONGER
  (bind (atom "rec-move")             (linear 0.001 1.0))
  (bind (atom "rec-range")            (linear 0.014 1.0))
  (bind (atom "rec-volume")           (linear 0.9 1.0))
  (bind (atom "prior-duration-delta")  (linear 0.47 1.0))
  (bind (atom "prior-move-delta")      (linear -0.027 1.0))
  (bind (atom "prior-volume-delta")    (linear -0.25 1.0))
  ;; prior-same (vs first peak) — stalling
  (bind (atom "same-move-delta")       (linear -0.002 1.0))
  (bind (atom "same-duration-delta")   (linear 0.83 1.0))    ;; 83% longer
  (bind (atom "same-volume-delta")     (linear -0.25 1.0)))));; drying up

(define phase-6 (encode (bundle                            ;; transition-down (STRENGTHENING selloff)
  (atom "phase-transition-down")
  (bind (atom "rec-duration")         (log 10.0))
  (bind (atom "rec-move")             (linear -0.032 1.0))   ;; MORE than the first pullback
  (bind (atom "rec-range")            (linear 0.038 1.0))
  (bind (atom "rec-volume")           (linear 1.5 1.0))      ;; volume SPIKES
  (bind (atom "prior-duration-delta")  (linear -0.55 1.0))
  (bind (atom "prior-move-delta")      (linear -0.033 1.0))
  (bind (atom "prior-volume-delta")    (linear 0.67 1.0))
  ;; prior-same (vs first pullback) — panic growing
  (bind (atom "same-move-delta")       (linear -0.020 1.0))  ;; 2% more selling
  (bind (atom "same-duration-delta")   (linear 0.67 1.0))    ;; longer
  (bind (atom "same-volume-delta")     (linear 1.14 1.0))))) ;; DOUBLE the volume

;; ═══ Layer 2: Trigrams ══════════════════════════════════════════════

(define tri-0 (bind (bind phase-0 (permute phase-1 1)) (permute phase-2 2)))  ;; rally→peak→pullback
(define tri-1 (bind (bind phase-1 (permute phase-2 1)) (permute phase-3 2)))  ;; peak→pullback→valley
(define tri-2 (bind (bind phase-2 (permute phase-3 1)) (permute phase-4 2)))  ;; pullback→valley→weak-rally
(define tri-3 (bind (bind phase-3 (permute phase-4 1)) (permute phase-5 2)))  ;; valley→weak-rally→lingering-peak
(define tri-4 (bind (bind phase-4 (permute phase-5 1)) (permute phase-6 2)))  ;; weak-rally→lingering-peak→selloff

;; ═══ Layer 3: Bigram-Pairs ══════════════════════════════════════════

(define pair-0 (bind tri-0 tri-1))  ;; strong cycle THEN the top forms
(define pair-1 (bind tri-1 tri-2))  ;; top THEN weak recovery begins
(define pair-2 (bind tri-2 tri-3))  ;; weak recovery THEN the stall
(define pair-3 (bind tri-3 tri-4))  ;; the stall THEN the selloff

;; ═══ Layer 4: Rhythm ════════════════════════════════════════════════

(define rhythm (bundle pair-0 pair-1 pair-2 pair-3))

;; The deltas tell the story:
;;   transition-up same-move-delta = -0.027 (weaker rally)
;;   phase-peak same-duration-delta = +0.83 (lingering pause)
;;   transition-down same-volume-delta = +1.14 (panic selling)
;;
;; These scalars ride on the same atoms as bullish-momentum.wat.
;; The DIRECTION of the deltas is opposite. The reckoner's discriminant
;; separates the two: positive same-move-delta on rallies → Grace.
;; Negative same-move-delta on rallies → Violence.
;;
;; The broker-observer sees this rhythm and the reckoner says: Exit.
