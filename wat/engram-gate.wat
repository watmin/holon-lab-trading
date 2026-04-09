;; engram-gate.wat — engram gating logic shared by market observers and brokers
;; Depends on: primitives only (OnlineSubspace, Reckoner)

(require primitives)

;; ── Engram Gate ────────────────────────────────────────────────────
;; After a recalibration with good accuracy, snapshot the discriminant
;; as a "good state." An OnlineSubspace learns what good discriminants
;; look like. Future recalibrations are checked against this memory.

;; check-engram-gate — called after observing an outcome.
;; Tracks per-recalibration accuracy. When a recalibration completes
;; and accuracy exceeds the threshold, the current discriminant is
;; fed to the good-state subspace as a positive example.
;;
;; Parameters:
;;   reckoner           — the entity's reckoner
;;   good-state-sub     — OnlineSubspace that learns good discriminants
;;   recalib-wins       — wins since last recalibration (mutable, on caller)
;;   recalib-total      — total since last recalibration (mutable, on caller)
;;   last-recalib-count — recalib-count at last engram check (mutable, on caller)
;;   outcome            — Outcome (:grace or :violence)
;;   accuracy-threshold — minimum accuracy to gate (e.g. 0.55)
;;   label              — the label whose discriminant we snapshot (e.g. "Up" or "Grace")
;;
;; Returns: nothing. Mutates the tracking fields and good-state subspace.

(define (check-engram-gate [reckoner : Reckoner]
                           [good-state-sub : OnlineSubspace]
                           [recalib-wins : usize]
                           [recalib-total : usize]
                           [last-recalib-count : usize]
                           [outcome : Outcome]
                           [accuracy-threshold : f64]
                           [label : String])
  (let ((current-recalib (recalib-count reckoner)))
    ;; Track this outcome
    (set! recalib-total (+ recalib-total 1))
    (when (= outcome :grace)
      (set! recalib-wins (+ recalib-wins 1)))

    ;; Check if a new recalibration has occurred
    (when (> current-recalib last-recalib-count)
      (let ((accuracy (if (> recalib-total 0)
                        (/ recalib-wins recalib-total)
                        0.0)))
        ;; If accuracy exceeds threshold, feed the discriminant to the subspace
        (when (> accuracy accuracy-threshold)
          (when-let ((disc (discriminant reckoner label)))
            (update good-state-sub disc)))

        ;; Reset tracking for the new recalibration window
        (set! recalib-wins 0)
        (set! recalib-total 0)
        (set! last-recalib-count current-recalib)))))
