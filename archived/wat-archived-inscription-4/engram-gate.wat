; engram-gate.wat — shared engram gating logic.
;
; Depends on: primitives (OnlineSubspace, Reckoner)
;
; Both MarketObserver and Broker use identical engram gating:
; check recalib-count, count wins, snapshot discriminant at 0.55
; accuracy, reset counters. This function extracts that pattern.

(require primitives)

;; ── check-engram-gate ─────────────────────────────────────────────────
;;
;; Called after a resolved outcome. Checks whether the reckoner has
;; recalibrated since the last check. If so, counts wins/total since
;; that recalibration. If accuracy exceeds 0.55, snapshots the
;; discriminant into the good-state subspace. Resets counters.
;;
;; label: the label name to query for the discriminant (e.g. "Up" for
;; market observers, "Grace" for brokers). The discriminant is the
;; direction in thought-space that separates this label from the others.
;;
;; Returns: (new-wins : usize, new-total : usize, new-last-count : usize)
;; The caller stores these back into its own fields.

(define (check-engram-gate [reckoner : Reckoner]
                           [good-state-subspace : OnlineSubspace]
                           [wins : usize]
                           [total : usize]
                           [last-count : usize]
                           [outcome : Outcome]
                           [label : String])
  : (usize, usize, usize)

  (let ((current-recalib (recalib-count reckoner)))
    (if (<= current-recalib last-count)
        ;; No recalibration — return unchanged
        (list wins total last-count)

        ;; Recalibration happened — update engram gate
        (let* ((correct (= outcome :grace))
               (new-wins  (if correct (+ wins 1) wins))
               (new-total (+ total 1)))

          ;; If enough data and good accuracy, snapshot the discriminant
          (when (and (> new-total 0)
                     (> (/ (+ new-wins 0.0)
                           (+ new-total 0.0))
                        0.55))
            (when-let ((d (discriminant reckoner label)))
              (update good-state-subspace d)))

          ;; Reset counters
          (list 0 0 current-recalib)))))
