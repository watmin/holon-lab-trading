;; settlement.wat — what the treasury produces and how the enterprise enriches it
;;
;; Depends on: trade (Trade), enums (Outcome, Direction), distances (Distances)
;;
;; TreasurySettlement: the treasury's accounting record when a trade closes.
;; Settlement: the complete record after enterprise enrichment — adds direction
;; and optimal-distances from replaying the trade's price history.

(require primitives)
(require enums)
(require distances)
(require trade)

;; ── TreasurySettlement — what the treasury produces ────────────────
;; Does NOT have optimal-distances — those come from replay.

(struct treasury-settlement
  [trade : Trade]                 ; which trade closed (carries post-idx, broker-slot-idx, side)
  [exit-price : f64]             ; price at settlement
  [outcome : Outcome]            ; :grace or :violence
  [amount : f64]                 ; how much value gained or lost
  [composed-thought : Vector])   ; from trade-origins, stashed at funding time

;; ── Settlement — the complete record after enrichment ──────────────
;; The enterprise builds this by enriching a TreasurySettlement.
;; The trade's price-history provides the replay data.

(struct settlement
  [treasury-settlement : TreasurySettlement]   ; the treasury's accounting
  [direction : Direction]                      ; :up or :down, derived from exit vs entry
  [optimal-distances : Distances])             ; replay trade's price-history, maximize residue
