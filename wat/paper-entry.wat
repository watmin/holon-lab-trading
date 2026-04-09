;; paper-entry.wat — PaperEntry struct
;; Depends on: distances

(require primitives)
(require distances)

;; ── PaperEntry — a hypothetical trade inside a broker ─────────────────
;; Every candle, every pair gets one. Tracks what WOULD have happened.
;; Both sides (buy and sell) are tracked simultaneously.
(struct paper-entry
  [composed-thought : Vector]
  [entry-price : f64]
  [distances : Distances]
  [buy-extreme : f64]
  [buy-trail-stop : f64]
  [sell-extreme : f64]
  [sell-trail-stop : f64]
  [buy-resolved : bool]
  [sell-resolved : bool])

(define (make-paper-entry [composed-thought : Vector]
                          [entry-price : f64]
                          [distances : Distances])
  : PaperEntry
  (let ((trail-dist (:trail distances)))
    (paper-entry
      composed-thought
      entry-price
      distances
      entry-price                           ; buy-extreme starts at entry
      (* entry-price (- 1.0 trail-dist))    ; buy-trail-stop below
      entry-price                           ; sell-extreme starts at entry
      (* entry-price (+ 1.0 trail-dist))    ; sell-trail-stop above
      false
      false)))
