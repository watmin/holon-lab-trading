;; engram-gate.wat — Shared utility for gating reckoner quality.
;; After recalibration with good accuracy, snapshot the discriminant
;; into a good-state subspace. Used by both MarketObserver and Broker.
;; Depends on: Outcome enum, Reckoner, OnlineSubspace.

(require primitives)

;; ── Struct ──────────────────────────────────────────────────────────

(struct engram-gate-state
  [recalib-wins : usize]
  [recalib-total : usize]
  [last-recalib-count : usize])

;; ── Interface ───────────────────────────────────────────────────────

(define (check-engram-gate [reckoner : Reckoner]
                           [good-state-subspace : Subspace]
                           [gate-state : EngramGateState]
                           [recalib-interval : usize]
                           [accuracy-threshold : f64])
  : EngramGateState
  ;; Called after each resolved prediction. Tracks wins/total since last
  ;; recalibration. When recalib-count advances and accuracy exceeds the
  ;; threshold, snapshots the discriminant into the good-state subspace.
  ;; Returns the updated gate state.
  (let ((current-recalib (recalib-count reckoner))
        (new-wins (:recalib-wins gate-state))
        (new-total (:recalib-total gate-state)))
    (if (> current-recalib (:last-recalib-count gate-state))
        ;; Recalibration boundary crossed — evaluate and possibly snapshot
        (let ((accuracy (if (> new-total 0)
                            (/ new-wins new-total)
                            0.0)))
          (when (>= accuracy accuracy-threshold)
            ;; Good accuracy — snapshot discriminant into subspace
            (for-each (lambda (label)
                        (when-let ((disc (discriminant reckoner label)))
                          (update good-state-subspace disc)))
                      (labels reckoner)))
          ;; Reset counters for next recalibration period
          (engram-gate-state 0 0 current-recalib))
        ;; Same recalibration period — just return current state
        gate-state)))
