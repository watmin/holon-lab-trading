;; proposal.wat — Proposal struct
;; Depends on: enums (Side), distances, raw-candle (Asset)

(require primitives)
(require enums)
(require distances)
(require raw-candle)

;; ── Proposal — what a post produces, what the treasury evaluates ──────
;; 8 fields. prediction is NOT on Proposal — it lives on TradeOrigin.
(struct proposal
  [composed-thought : Vector]
  [distances : Distances]
  [edge : f64]
  [side : Side]
  [source-asset : Asset]
  [target-asset : Asset]
  [post-idx : usize]
  [broker-slot-idx : usize])
