;; proposal.wat — Proposal struct
;; Depends on: enums (Side, prediction), distances (Distances), raw-candle (Asset)
;; What a post produces, what the treasury evaluates.

(require primitives)
(require enums)
(require distances)
(require raw-candle)

;; Assembled by the post during step-compute-dispatch.
(struct proposal
  [composed-thought : Vector]  ; market thought + exit facts
  [prediction : Prediction]    ; :discrete (Grace/Violence) — from the broker's reckoner
  [distances : Distances]      ; from the exit observer
  [edge : f64]                 ; accuracy from curve, 0.0 when unproven
  [side : Side]                ; :buy or :sell — from market observer's Up/Down prediction
  [source-asset : Asset]       ; what is deployed (e.g. USDC)
  [target-asset : Asset]       ; what is acquired (e.g. WBTC)
  [post-idx : usize]           ; which post this came from
  [broker-slot-idx : usize])   ; which broker proposed this

(define (make-proposal [composed : Vector] [pred : Prediction]
                       [dist : Distances] [edge-val : f64]
                       [side : Side] [source : Asset] [target : Asset]
                       [post-idx : usize] [slot-idx : usize])
  : Proposal
  (proposal composed pred dist edge-val side source target post-idx slot-idx))
