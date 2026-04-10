;; settlement.wat — TreasurySettlement
;; Depends on: enums, newtypes, trade
;; No Settlement struct — the enterprise routes values directly.

(require primitives)
(require enums)
(require newtypes)
(require trade)

(struct treasury-settlement
  [trade : Trade]              ; which trade closed
  [exit-price : f64]
  [outcome : Outcome]          ; :grace or :violence
  [amount : f64]               ; how much value gained or lost
  [composed-thought : Vector]  ; from trade-origins
  [prediction : Prediction])   ; from trade-origins — the broker's verdict at funding
