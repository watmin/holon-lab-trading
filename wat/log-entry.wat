;; log-entry.wat — LogEntry enum
;; Depends on: enums (Outcome), distances, newtypes (TradeId)

(require primitives)
(require enums)
(require distances)
(require newtypes)

;; The glass box. What happened. Generic.
;; Each function returns its log entries as values.
(enum log-entry
  (ProposalSubmitted
    broker-slot-idx    ; usize
    composed-thought   ; Vector
    distances)         ; Distances
  (ProposalFunded
    trade-id           ; TradeId
    broker-slot-idx    ; usize
    amount-reserved)   ; f64
  (ProposalRejected
    broker-slot-idx    ; usize
    reason)            ; String
  (TradeSettled
    trade-id           ; TradeId
    outcome            ; Outcome
    amount             ; f64
    duration)          ; usize — candles held
  (PaperResolved
    broker-slot-idx    ; usize
    outcome            ; Outcome
    optimal-distances) ; Distances
  (Propagated
    broker-slot-idx    ; usize
    observers-updated)); usize — how many observers received the outcome
