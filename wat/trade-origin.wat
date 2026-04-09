;; trade-origin.wat — TradeOrigin struct
;; Depends on: nothing

(require primitives)

;; ── TradeOrigin ────────────────────────────────────────────────────
;; Where a trade came from, for propagation routing at settlement.

(struct trade-origin
  [post-idx : usize]
  [broker-slot-idx : usize]
  [composed-thought : Vector])

(define (make-trade-origin [post-idx : usize]
                           [broker-slot-idx : usize]
                           [composed-thought : Vector])
  : TradeOrigin
  (trade-origin post-idx broker-slot-idx composed-thought))
