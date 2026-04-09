;; log-entry.wat — LogEntry enum
;; Depends on: enums.wat, distances.wat, newtypes.wat

(require primitives)
(require enums)
(require distances)
(require newtypes)

;; ── LogEntry ───────────────────────────────────────────────────────
;; The glass box. What happened. Generic. Each function returns its
;; log entries as values.

(enum log-entry
  (ProposalSubmitted
    broker-slot-idx
    composed-thought
    distances)
  (ProposalFunded
    trade-id
    broker-slot-idx
    amount-reserved)
  (ProposalRejected
    broker-slot-idx
    reason)
  (TradeSettled
    trade-id
    outcome
    amount
    duration)
  (PaperResolved
    broker-slot-idx
    outcome
    optimal-distances)
  (Propagated
    broker-slot-idx
    observers-updated))
