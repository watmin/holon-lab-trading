;; paper-entry.wat — PaperEntry struct
;; Depends on: distances
;; A paper trade is a "what if." Both sides tracked simultaneously.

(require primitives)
(require distances)

(struct paper-entry
  [composed-thought : Vector]  ; the thought at entry
  [entry-price : f64]          ; price when the paper was created
  [distances : Distances]      ; from the exit observer at entry
  [buy-extreme : f64]          ; best price in buy direction so far
  [buy-trail-stop : f64]       ; trailing stop level for buy side
  [sell-extreme : f64]         ; best price in sell direction so far
  [sell-trail-stop : f64]      ; trailing stop level for sell side
  [buy-resolved : bool]        ; buy side's stop fired
  [sell-resolved : bool])      ; sell side's stop fired

(define (make-paper-entry [composed-thought : Vector]
                          [entry-price : f64]
                          [distances : Distances])
  : PaperEntry
  (let ((trail (:trail distances)))
    (paper-entry
      composed-thought
      entry-price
      distances
      entry-price                          ; buy-extreme starts at entry
      (* entry-price (- 1.0 trail))        ; buy-trail-stop below entry
      entry-price                          ; sell-extreme starts at entry
      (* entry-price (+ 1.0 trail))        ; sell-trail-stop above entry
      false                                ; buy not resolved
      false)))                             ; sell not resolved

;; Tick a paper entry at the current price.
;; Returns the updated paper entry.
(define (tick-paper [paper : PaperEntry] [current-price : f64])
  : PaperEntry
  (let ((trail (:trail (:distances paper)))
        ;; Buy side: price going up is good
        (new-buy-extreme (if (:buy-resolved paper)
                           (:buy-extreme paper)
                           (max (:buy-extreme paper) current-price)))
        (new-buy-trail (if (:buy-resolved paper)
                         (:buy-trail-stop paper)
                         (max (:buy-trail-stop paper)
                              (* new-buy-extreme (- 1.0 trail)))))
        (buy-fired (and (not (:buy-resolved paper))
                        (<= current-price new-buy-trail)))
        ;; Sell side: price going down is good
        (new-sell-extreme (if (:sell-resolved paper)
                            (:sell-extreme paper)
                            (min (:sell-extreme paper) current-price)))
        (new-sell-trail (if (:sell-resolved paper)
                          (:sell-trail-stop paper)
                          (min (:sell-trail-stop paper)
                               (* new-sell-extreme (+ 1.0 trail)))))
        (sell-fired (and (not (:sell-resolved paper))
                         (>= current-price new-sell-trail))))
    (update paper
      :buy-extreme new-buy-extreme
      :buy-trail-stop new-buy-trail
      :sell-extreme new-sell-extreme
      :sell-trail-stop new-sell-trail
      :buy-resolved (or (:buy-resolved paper) buy-fired)
      :sell-resolved (or (:sell-resolved paper) sell-fired))))

;; Is this paper fully resolved (both sides done)?
(define (paper-resolved? [paper : PaperEntry])
  : bool
  (and (:buy-resolved paper) (:sell-resolved paper)))
