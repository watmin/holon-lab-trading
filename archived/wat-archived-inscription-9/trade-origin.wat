;; trade-origin.wat — TradeOrigin struct
;; Depends on: enums
;; Where a trade came from, for propagation routing.

(require primitives)
(require enums)

(struct trade-origin
  [post-idx : usize]           ; which post
  [broker-slot-idx : usize]    ; which broker
  [composed-thought : Vector]  ; the thought at entry
  [prediction : Prediction])   ; :discrete (Grace/Violence) — the broker's prediction at funding

(define (make-trade-origin [post-idx : usize]
                           [broker-slot-idx : usize]
                           [composed-thought : Vector]
                           [prediction : Prediction])
  : TradeOrigin
  (trade-origin post-idx broker-slot-idx composed-thought prediction))
