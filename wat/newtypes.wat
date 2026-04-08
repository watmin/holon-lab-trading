;; newtypes.wat — distinct types wrapping primitives.
;;
;; Depends on: nothing.
;;
;; A newtype is about MEANING, not structure. TradeId is not a usize —
;; it is a TradeId that happens to be represented as a usize.
;; Maps to Rust's tuple struct: struct TradeId(usize).

(require primitives)

;; ── TradeId — the treasury's key for active trades ──────────────────
;; Assigned at funding time. Maps back to (post-idx, slot-idx) via trade-origins.
(newtype TradeId usize)
