;; newtypes.wat — distinct types wrapping primitives
;; Depends on: nothing

(require primitives)

;; TradeId — the treasury's key for active trades.
;; Not a raw integer — a distinct type the compiler enforces.
;; Assigned at funding time.
(newtype TradeId usize)
