;; proposal.wat — Proposal struct
;; Depends on: enums (Side, prediction), distances, raw-candle (Asset)

(require primitives)
(require enums)
(require distances)
(require raw-candle)

;; A proposal — what a post produces, what the treasury evaluates.
(struct proposal
  [composed-thought : Vector]  ; market thought + exit facts
  [prediction : Prediction]    ; :discrete (Grace/Violence) from the broker
  [distances : Distances]      ; from the exit observer
  [edge : f64]                 ; the broker's edge [0.0, 1.0]
  [side : Side]                ; :buy or :sell
  [source-asset : Asset]       ; what is deployed (e.g. USDC)
  [target-asset : Asset]       ; what is acquired (e.g. WBTC)
  [post-idx : usize]           ; which post this came from
  [broker-slot-idx : usize])   ; which broker proposed this

(define (make-proposal [composed-thought : Vector] [prediction : Prediction]
                       [distances : Distances] [edge : f64] [side : Side]
                       [source-asset : Asset] [target-asset : Asset]
                       [post-idx : usize] [broker-slot-idx : usize])
  : Proposal
  (proposal composed-thought prediction distances edge side
            source-asset target-asset post-idx broker-slot-idx))
