;; newtypes.wat — distinct types wrapping primitives
;; Depends on: nothing

(require primitives)

;; ── TradeId — the treasury's key for active trades ─────────────────
;; Not a raw usize — a distinct type the compiler enforces.
;; Assigned at funding time. Maps back to (post-idx, broker-slot-idx)
;; via trade-origins.
(newtype TradeId usize)
