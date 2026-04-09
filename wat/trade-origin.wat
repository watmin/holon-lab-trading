;; trade-origin.wat — TradeOrigin struct
;; Depends on: nothing (just Vector)

(require primitives)

;; Where a trade came from, for propagation routing.
;; Stashed at funding time, read at settlement time.
(struct trade-origin
  [post-idx : usize]
  [broker-slot-idx : usize]
  [composed-thought : Vector])

(define (make-trade-origin [post-idx : usize] [broker-slot-idx : usize]
                           [composed-thought : Vector])
  : TradeOrigin
  (trade-origin post-idx broker-slot-idx composed-thought))
