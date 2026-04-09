;; log-entry.wat — the glass box. What happened.
;;
;; Depends on: newtypes (TradeId), enums (Outcome), distances (Distances)
;;
;; Generic. Each function returns its log entries as values.
;; Six variants — one per observable event in the enterprise.

(require primitives)
(require newtypes)
(require enums)
(require distances)

(enum log-entry
  (ProposalSubmitted
    [broker-slot-idx : usize]
    [composed-thought : Vector]
    [distances : Distances])
  (ProposalFunded
    [trade-id : TradeId]
    [broker-slot-idx : usize]
    [amount-reserved : f64])
  (ProposalRejected
    [broker-slot-idx : usize]
    [reason : String])
  (TradeSettled
    [trade-id : TradeId]
    [outcome : Outcome]
    [amount : f64]
    [duration : usize])
  (PaperResolved
    [broker-slot-idx : usize]
    [outcome : Outcome]
    [optimal-distances : Distances])
  (Propagated
    [broker-slot-idx : usize]
    [observers-updated : usize]))
