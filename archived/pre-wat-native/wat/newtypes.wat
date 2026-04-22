;; ── newtypes.wat ────────────────────────────────────────────────────
;;
;; Distinct types wrapping primitives. A newtype is about MEANING, not
;; structure. TradeId is not a usize — it is a TradeId that happens to
;; be represented as a usize. Maps to Rust's tuple struct.
;; Depends on: nothing.

;; Treasury's key for active trades. Assigned at funding time.
;; Maps back to (post-idx, slot-idx) via trade-origins.
(newtype TradeId usize)
