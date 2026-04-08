; log-entry.wat — the glass box. What happened.
;
; Depends on: TradeId, Outcome, Distances.
;
; Generic. Each function returns its log entries as values.
; Six typed variants — the sum type of observable events.

(require primitives)
(require enums)         ; Outcome
(require newtypes)      ; TradeId
(require distances)     ; Distances

;; ---- LogEntry — six typed variants -----------------------------------------

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
    [duration : usize])          ; candles held

  (PaperResolved
    [broker-slot-idx : usize]
    [outcome : Outcome]
    [optimal-distances : Distances])

  (Propagated
    [broker-slot-idx : usize]
    [observers-updated : usize]))  ; how many observers received the outcome
