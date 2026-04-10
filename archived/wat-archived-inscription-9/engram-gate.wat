;; engram-gate.wat — engram gating for reckoner quality
;; Depends on: primitives only
;; Used by any entity with a reckoner: market observers, brokers.
;; After a recalibration with good accuracy, snapshot the discriminant.
;; An OnlineSubspace learns what good discriminants look like.

(require primitives)
(require enums)

;; Check if the reckoner has recalibrated since the last check.
;; If so, evaluate accuracy and update the engram gate.
;; Takes the Outcome of the most recent observation.
;; Returns updated gate fields: (good-state-subspace, recalib-wins, recalib-total, last-recalib-count)
(define (check-engram-gate [reckoner : Reckoner]
                           [good-state-subspace : OnlineSubspace]
                           [recalib-wins : usize]
                           [recalib-total : usize]
                           [last-recalib-count : usize]
                           [outcome : Outcome])
  : (OnlineSubspace usize usize usize)
  (let ((current-recalib (recalib-count reckoner))
        ;; Track wins/total for accuracy measurement
        (new-wins (match outcome
                    (:grace (+ recalib-wins 1))
                    (:violence recalib-wins)))
        (new-total (+ recalib-total 1)))
    (if (> current-recalib last-recalib-count)
      ;; Recalibration happened — evaluate and maybe snapshot
      (let ((accuracy (if (> new-total 0)
                        (/ (+ 0.0 new-wins) (+ 0.0 new-total))
                        0.0)))
        (if (> accuracy 0.5)
          ;; Good accuracy — snapshot the discriminant into the subspace
          (let ((labels-list (labels reckoner))
                (first-label (first labels-list)))
            (when-let ((disc (discriminant reckoner first-label)))
              (let ((updated-subspace (begin (update good-state-subspace disc)
                                            good-state-subspace)))
                (list updated-subspace 0 0 current-recalib))))
          ;; Poor accuracy — reset counters, don't snapshot
          (list good-state-subspace 0 0 current-recalib)))
      ;; No recalibration — just update counters
      (list good-state-subspace new-wins new-total last-recalib-count))))
