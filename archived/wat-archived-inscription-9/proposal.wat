;; proposal.wat — Proposal struct
;; Depends on: enums, distances, raw-candle (Asset)
;; Assembled by the post during step-compute-dispatch.

(require primitives)
(require enums)
(require distances)
(require raw-candle)

(struct proposal
  [composed-thought : Vector]  ; market thought + exit facts
  [distances : Distances]      ; from the exit observer
  [edge : f64]                 ; the broker's edge [0.0, 1.0]
  [side : Side]                ; :buy or :sell
  [source-asset : Asset]       ; what is deployed
  [target-asset : Asset]       ; what is acquired
  [post-idx : usize]           ; which post
  [broker-slot-idx : usize])   ; which broker proposed this

(define (make-proposal [composed-thought : Vector]
                       [distances : Distances]
                       [edge : f64]
                       [side : Side]
                       [source-asset : Asset]
                       [target-asset : Asset]
                       [post-idx : usize]
                       [broker-slot-idx : usize])
  : Proposal
  (proposal composed-thought distances edge side
    source-asset target-asset post-idx broker-slot-idx))
