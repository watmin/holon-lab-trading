;; trade-origin.wat — TradeOrigin struct
;; Depends on: enums (prediction)

(require primitives)
(require enums)

;; ── TradeOrigin — where a trade came from, for propagation routing ────
;; 4 fields. prediction IS on TradeOrigin (not on Proposal).
;; The archaeological record of WHY this trade exists.
(struct trade-origin
  [post-idx : usize]
  [broker-slot-idx : usize]
  [composed-thought : Vector]
  [prediction : Prediction])
