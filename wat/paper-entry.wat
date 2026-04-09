;; paper-entry.wat — PaperEntry struct
;; Depends on: distances

(require primitives)
(require distances)

;; A paper trade — a "what if." Every candle, every broker gets one.
;; Both sides (buy and sell) tracked simultaneously.
;; When both sides resolve (their trailing stops fire), the paper teaches.
(struct paper-entry
  [composed-thought : Vector]  ; the thought at entry
  [entry-price : f64]          ; price when the paper was created
  [entry-atr : f64]            ; volatility at entry
  [distances : Distances]      ; from the exit observer at entry
  [buy-extreme : f64]          ; best price in buy direction so far
  [buy-trail-stop : f64]       ; trailing stop level (from distances.trail)
  [sell-extreme : f64]         ; best price in sell direction so far
  [sell-trail-stop : f64]      ; trailing stop level (from distances.trail)
  [buy-resolved : bool]        ; buy side's stop fired
  [sell-resolved : bool])      ; sell side's stop fired

(define (make-paper-entry [composed-thought : Vector] [entry-price : f64]
                          [entry-atr : f64] [distances : Distances])
  : PaperEntry
  (let ((trail (:trail distances)))
    (paper-entry
      composed-thought entry-price entry-atr distances
      entry-price                                ; buy-extreme starts at entry
      (* entry-price (- 1.0 trail))              ; buy-trail-stop
      entry-price                                ; sell-extreme starts at entry
      (* entry-price (+ 1.0 trail))              ; sell-trail-stop
      false false)))                             ; neither side resolved
