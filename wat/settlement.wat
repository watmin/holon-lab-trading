;; settlement.wat — TreasurySettlement ONLY
;; No Settlement struct. Enterprise passes values directly to post-propagate.
;; Depends on: enums (Outcome), trade (Trade)

(require primitives)
(require enums)
(require trade)

;; ── TreasurySettlement — what the treasury produces when a trade closes
(struct treasury-settlement
  [trade : Trade]
  [exit-price : f64]
  [outcome : Outcome]
  [amount : f64]
  [composed-thought : Vector])
