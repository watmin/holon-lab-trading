;; settlement.wat — TreasurySettlement, Settlement
;; Depends on: enums (Outcome, Direction), distances (Distances), trade (Trade)
;; Resolution lives in broker.wat (it's a broker output).

(require primitives)
(require enums)
(require distances)
(require trade)

;; TreasurySettlement — what the treasury produces when a trade closes.
;; It does NOT have optimal-distances.
(struct treasury-settlement
  [trade : Trade]              ; which trade closed (carries post-idx, broker-slot-idx, side)
  [exit-price : f64]           ; price at settlement
  [outcome : Outcome]          ; :grace or :violence
  [amount : f64]               ; how much value gained or lost
  [composed-thought : Vector]) ; from trade-origins, stashed at funding time

(define (make-treasury-settlement [t : Trade] [exit-p : f64]
                                  [outcome : Outcome] [amt : f64]
                                  [composed : Vector])
  : TreasurySettlement
  (treasury-settlement t exit-p outcome amt composed))

;; Settlement — the complete record, after enterprise enrichment.
;; The enterprise builds this by enriching a TreasurySettlement.
(struct settlement
  [treasury-settlement : TreasurySettlement] ; the treasury's accounting
  [direction : Direction]                    ; :up or :down, derived from exit vs entry
  [optimal-distances : Distances])           ; replay trade's price-history

(define (make-settlement [ts : TreasurySettlement] [dir : Direction]
                         [optimal : Distances])
  : Settlement
  (settlement ts dir optimal))

;; Derive direction from entry and exit prices.
(define (derive-direction [entry-rate : f64] [exit-price : f64])
  : Direction
  (if (>= exit-price entry-rate) :up :down))
