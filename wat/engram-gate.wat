;; engram-gate.wat — engram gating for reckoners
;; Depends on: primitives only
;;
;; After a recalibration with good accuracy, snapshot the discriminant
;; as a "good state." An OnlineSubspace learns what good discriminants
;; look like. Future recalibrations are checked against this memory.
;; Used by any entity that has a reckoner — market observers and brokers.
;; Same mechanism, same four fields, different reckoner, different purpose.

(require primitives)

;; Check if a new recalibration should be accepted based on engram gating.
;; Returns true if the new discriminant is consistent with known good states.
;; entity must have: reckoner, good-state-subspace, recalib-wins, recalib-total,
;;                   last-recalib-count
;; outcome: Outcome — the most recent outcome (:grace or :violence)
(define (check-engram-gate [entity-reckoner : Reckoner]
                           [good-state-subspace : OnlineSubspace]
                           [recalib-wins : usize]
                           [recalib-total : usize]
                           [last-recalib-count : usize]
                           [outcome : Outcome])
  : (bool, usize, usize, usize)  ; (accepted?, new-recalib-wins, new-recalib-total, new-last-recalib-count)
  (let ((current-recalib (recalib-count entity-reckoner))
        (new-wins (if (= outcome :grace) (+ recalib-wins 1) recalib-wins))
        (new-total (+ recalib-total 1)))
    (if (> current-recalib last-recalib-count)
      ;; A recalibration has occurred since last check
      (let ((accuracy (if (> new-total 0)
                        (/ (+ new-wins 0.0) (+ new-total 0.0))
                        0.0))
            (min-accuracy 0.52))  ; better than random
        (if (> accuracy min-accuracy)
          ;; Good accuracy — snapshot the discriminant
          (let ((disc (discriminant entity-reckoner "Grace")))
            (when-let ((d (match disc ((Some v) v) (None None))))
              (when d
                (update good-state-subspace d)))
            ;; Reset counters, accept
            (list true 0 0 current-recalib))
          ;; Poor accuracy — check if discriminant matches known good states
          (let ((disc (discriminant entity-reckoner "Grace"))
                (residual-score (match disc
                                  ((Some d) (residual good-state-subspace d))
                                  (None 999.0))))
            (if (and (> (sample-count good-state-subspace) 0)
                     (> residual-score (threshold good-state-subspace)))
              ;; Discriminant is unusual — reject recalibration
              (list false 0 0 current-recalib)
              ;; No data or consistent — accept
              (list true 0 0 current-recalib)))))
      ;; No recalibration happened — just update counters
      (list true new-wins new-total last-recalib-count))))
