; settlement.wat — TreasurySettlement and Settlement structs.
;
; Depends on: Trade, Outcome, Direction, Distances.
;
; TreasurySettlement: what the treasury produces when a trade closes.
; It has the accounting but NOT the hindsight optimal-distances.
;
; Settlement: the complete record after enterprise enrichment.
; The enterprise derives direction from exit-price vs entry-rate,
; and replays the trade's price-history for optimal-distances.

(require primitives)
(require enums)         ; Outcome, Direction
(require distances)     ; Distances
(require trade)         ; Trade

;; ── TreasurySettlement — treasury's output ──────────────────────────────

(struct treasury-settlement
  [trade : Trade]              ; which trade closed (carries post-idx, broker-slot-idx, side)
  [exit-price : f64]           ; price at settlement
  [outcome : Outcome]          ; :grace or :violence
  [amount : f64]               ; how much value gained or lost
  [composed-thought : Vector]) ; from trade-origins, stashed at funding time

;; ── Settlement — enterprise-enriched complete record ────────────────────
;; Built by the enterprise from a TreasurySettlement.
;; Adds direction (derived) and optimal-distances (replayed).

(struct settlement
  [treasury-settlement : TreasurySettlement] ; the treasury's accounting
  [direction : Direction]                    ; :up or :down, derived from exit-price vs entry-rate
  [optimal-distances : Distances])           ; replay trade's price-history, maximize residue
