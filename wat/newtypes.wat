;; newtypes.wat — distinct types wrapping primitives
;;
;; Depends on: nothing

;; TradeId — the treasury's key for active trades.
;; Assigned at funding time. Not a raw integer — a distinct type
;; that the compiler enforces. Maps back to (post-idx, slot-idx)
;; via trade-origins.
(newtype TradeId usize)
