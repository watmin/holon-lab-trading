;; newtypes.wat — TradeId
;; Depends on: nothing

(require primitives)

;; ── TradeId — the treasury's key for active trades ────────────────────
;; Not a raw integer — a distinct type the compiler enforces.
;; Assigned at funding time. Maps back to (post-idx, slot-idx)
;; via trade-origins.
(newtype TradeId usize)
