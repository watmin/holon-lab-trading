;; engram-gate.wat — check-engram-gate
;; Depends on: primitives only (OnlineSubspace, Reckoner)
;;
;; After a recalibration with good accuracy, snapshot the discriminant
;; as a "good state." An OnlineSubspace learns what good discriminants
;; look like. Future recalibrations are checked against this memory.
;; Used by any entity that has a reckoner — market observers gate their
;; direction predictions, brokers gate their Grace/Violence predictions.
;; Same mechanism, same fields, different reckoner, different purpose.

(require primitives)

;; ── check-engram-gate — snapshot and validate discriminants ───────────
;; Returns true if the discriminant is consistent with known-good states,
;; or if there aren't enough samples yet (benefit of the doubt).
;; Mutates: good-state-subspace (learns), recalib-wins/total, last-recalib-count.
;;
;; The four engram gating fields live on the entity (MarketObserver or Broker):
;;   good-state-subspace : OnlineSubspace
;;   recalib-wins : usize
;;   recalib-total : usize
;;   last-recalib-count : usize
;;
;; This function is called after each prediction resolution to check if
;; a new recalibration happened and if so, whether the new discriminant
;; should be trusted.
(define (check-engram-gate [good-state-subspace : OnlineSubspace]
                           [recalib-wins : usize]
                           [recalib-total : usize]
                           [last-recalib-count : usize]
                           [reckoner : Reckoner]
                           [correct? : bool])
  : (OnlineSubspace, usize, usize, usize, bool)
  ;; Track accuracy since last recalibration
  (let ((new-recalib-total (+ recalib-total 1))
        (new-recalib-wins (if correct? (+ recalib-wins 1) recalib-wins))
        (current-recalib (recalib-count reckoner)))
    ;; Did a recalibration just happen?
    (if (> current-recalib last-recalib-count)
      ;; Yes — evaluate the old period's accuracy and decide about the new discriminant
      (let ((accuracy (if (> new-recalib-total 0)
                       (/ (+ 0.0 new-recalib-wins) (+ 0.0 new-recalib-total))
                       0.0))
            (accuracy-threshold 0.52)
            (min-gate-samples 50)
            (good-accuracy? (> accuracy accuracy-threshold)))
        ;; If the old period had good accuracy, teach the good-state subspace
        (when good-accuracy?
          (when-let ((disc (discriminant reckoner "Up")))
            (update good-state-subspace disc))
          (when-let ((disc (discriminant reckoner "Down")))
            (update good-state-subspace disc))
          (when-let ((disc (discriminant reckoner "Grace")))
            (update good-state-subspace disc))
          (when-let ((disc (discriminant reckoner "Violence")))
            (update good-state-subspace disc)))
        ;; Check if the new discriminant matches known-good states
        (let ((gate-passed
                (if (< (sample-count good-state-subspace) min-gate-samples)
                  true  ;; benefit of the doubt — not enough data
                  (let ((res (match (discriminant reckoner "Up")
                               ((Some disc) (residual good-state-subspace disc))
                               (None (match (discriminant reckoner "Grace")
                                       ((Some disc) (residual good-state-subspace disc))
                                       (None 0.0)))))
                        (thresh (threshold good-state-subspace)))
                    (< res thresh)))))
          ;; Reset counters for the new period
          (list good-state-subspace 0 0 current-recalib gate-passed)))
      ;; No recalibration — just update counters
      (list good-state-subspace new-recalib-wins new-recalib-total last-recalib-count true))))
