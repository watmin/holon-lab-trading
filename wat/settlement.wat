;; settlement.wat — TreasurySettlement and Settlement
;; Depends on: enums.wat, distances.wat, trade.wat

(require primitives)
(require enums)
(require distances)
(require trade)

;; ── TreasurySettlement ─────────────────────────────────────────────
;; What the treasury produces when a trade closes.
;; Does NOT have optimal-distances — the enterprise enriches it.

(struct treasury-settlement
  [trade : Trade]
  [exit-price : f64]
  [outcome : Outcome]
  [amount : f64]
  [composed-thought : Vector])

;; ── Settlement ─────────────────────────────────────────────────────
;; The complete record, after enterprise enrichment.

(struct settlement
  [treasury-settlement : TreasurySettlement]
  [direction : Direction]
  [optimal-distances : Distances])

;; ── derive-direction — from exit-price vs entry-rate ───────────────

(define (derive-direction [exit-price : f64] [entry-rate : f64])
  : Direction
  (if (>= exit-price entry-rate) :up :down))

;; ── make-settlement — enrich a TreasurySettlement ──────────────────

(define (make-settlement [ts : TreasurySettlement]
                         [optimal : Distances])
  : Settlement
  (let ((dir (derive-direction (:exit-price ts)
               (:entry-rate (:trade ts)))))
    (settlement ts dir optimal)))
