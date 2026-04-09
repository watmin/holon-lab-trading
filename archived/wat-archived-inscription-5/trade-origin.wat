;; trade-origin.wat — TradeOrigin struct
;; Depends on: nothing (just Vector from primitives)
;; Where a trade came from, for propagation routing.

(require primitives)

(struct trade-origin
  [post-idx : usize]           ; which post
  [broker-slot-idx : usize]    ; which broker
  [composed-thought : Vector]) ; the thought at entry

(define (make-trade-origin [post-idx : usize] [slot-idx : usize]
                           [composed : Vector])
  : TradeOrigin
  (trade-origin post-idx slot-idx composed))
