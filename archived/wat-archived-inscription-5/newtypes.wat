;; newtypes.wat — distinct types wrapping primitives
;; Depends on: nothing
;; A newtype is about MEANING, not structure. TradeId is not a usize —
;; it is a TradeId that happens to be represented as a usize.

(require primitives)

;; Treasury's key for active trades. Assigned at funding time.
(newtype TradeId usize)
