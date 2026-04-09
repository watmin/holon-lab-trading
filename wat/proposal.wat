;; proposal.wat — Proposal struct
;; Depends on: enums.wat, distances.wat, raw-candle.wat

(require primitives)
(require enums)
(require distances)
(require raw-candle)

;; ── Proposal ───────────────────────────────────────────────────────
;; What a post produces, what the treasury evaluates.

(struct proposal
  [composed-thought : Vector]
  [prediction : Prediction]
  [distances : Distances]
  [edge : f64]
  [side : Side]
  [source-asset : Asset]
  [target-asset : Asset]
  [post-idx : usize]
  [broker-slot-idx : usize])

(define (make-proposal [composed-thought : Vector]
                       [prediction : Prediction]
                       [distances : Distances]
                       [edge : f64]
                       [side : Side]
                       [source-asset : Asset]
                       [target-asset : Asset]
                       [post-idx : usize]
                       [broker-slot-idx : usize])
  : Proposal
  (proposal composed-thought prediction distances edge side
    source-asset target-asset post-idx broker-slot-idx))
