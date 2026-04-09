;; trade-origin.wat — where a trade came from, for propagation routing
;;
;; Depends on: nothing (uses usize, Vector)
;;
;; Stashed at funding time. When a trade settles, the enterprise uses
;; the trade-origin to route the outcome back to the right post and broker.

(require primitives)

(struct trade-origin
  [post-idx : usize]              ; which post
  [broker-slot-idx : usize]       ; which broker
  [composed-thought : Vector])    ; the thought at entry
