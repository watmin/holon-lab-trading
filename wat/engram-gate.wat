;; engram-gate.wat — engram gating: snapshot good discriminants, verify new ones
;; Depends on: primitives only (OnlineSubspace, Reckoner)
;; Used by any entity that has a reckoner — market observers, brokers.
;; Same mechanism, same four fields, different reckoner, different purpose.

(require primitives)

;; Check whether a recalibration produced a good state.
;; If accuracy since last check exceeds the threshold, snapshot the
;; discriminant into the good-state subspace. Then verify the current
;; discriminant against the good-state memory.
;;
;; Returns true if the discriminant is consistent with known good states
;; (or if the subspace has no data yet — benefit of the doubt).
;;
;; Fields read/written (on the caller's struct):
;;   :reckoner, :good-state-subspace, :recalib-wins, :recalib-total, :last-recalib-count
;;
;; The caller owns these fields. This function is a shared mechanism,
;; not a struct method. The caller destructures as needed.
(define (check-engram-gate [reckoner : Reckoner]
                           [good-sub : OnlineSubspace]
                           [wins : usize]
                           [total : usize]
                           [last-rc : usize]
                           [accuracy-threshold : f64])
  : (bool, OnlineSubspace, usize, usize, usize)
  (let ((current-rc (recalib-count reckoner)))
    (if (= current-rc last-rc)
      ;; No new recalibration — pass through
      (list true good-sub wins total last-rc)
      ;; New recalibration occurred
      (let ((accuracy (if (> total 0) (/ (+ 0.0 wins) (+ 0.0 total)) 0.0))
            (up-label (first (labels reckoner))))
        (if (>= accuracy accuracy-threshold)
          ;; Good recalibration — snapshot the discriminant
          (let ((disc (discriminant reckoner up-label)))
            (match disc
              ((Some d)
                (begin
                  (update good-sub d)
                  (list true good-sub 0 0 current-rc)))
              (None
                (list true good-sub 0 0 current-rc))))
          ;; Bad recalibration — check against memory
          (let ((disc (discriminant reckoner up-label)))
            (match disc
              ((Some d)
                (if (> (sample-count good-sub) 0)
                  ;; Memory exists — check consistency
                  (let ((res (residual good-sub d)))
                    (list (<= res (threshold good-sub))
                          good-sub 0 0 current-rc))
                  ;; No memory yet — benefit of the doubt
                  (list true good-sub 0 0 current-rc)))
              (None
                (list true good-sub 0 0 current-rc)))))))))

;; Record a resolved prediction for engram tracking.
;; Call this after each resolve to accumulate wins/total.
(define (engram-gate-record [correct : bool] [wins : usize] [total : usize])
  : (usize, usize)
  (list (if correct (+ wins 1) wins) (+ total 1)))
