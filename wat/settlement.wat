;; settlement.wat — TreasurySettlement, Settlement, Resolution
;; Depends on: enums (Outcome, Direction), distances, trade, newtypes (TradeId)

(require primitives)
(require enums)
(require distances)
(require trade)
(require newtypes)

;; What the treasury produces when a trade closes.
(struct treasury-settlement
  [trade : Trade]
  [exit-price : f64]
  [outcome : Outcome]
  [amount : f64]
  [composed-thought : Vector])

;; The complete record, after enterprise enrichment.
;; The enterprise builds this by enriching a TreasurySettlement.
(struct settlement
  [treasury-settlement : TreasurySettlement]
  [direction : Direction]
  [optimal-distances : Distances])

;; What a broker produces when a paper resolves.
;; Facts, not mutations. Collected from parallel tick, applied sequentially.
(struct resolution
  [broker-slot-idx : usize]
  [composed-thought : Vector]
  [direction : Direction]
  [outcome : Outcome]
  [amount : f64]
  [optimal-distances : Distances])

(define (make-resolution [broker-slot-idx : usize] [composed-thought : Vector]
                         [direction : Direction] [outcome : Outcome]
                         [amount : f64] [optimal-distances : Distances])
  : Resolution
  (resolution broker-slot-idx composed-thought direction outcome amount optimal-distances))
