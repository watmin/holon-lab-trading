;; ── paper-entry.wat ─────────────────────────────────────────────────
;;
;; Hypothetical trade inside a broker. A paper trade is a "what if."
;; Every candle, every pair gets one. Both sides (buy and sell) are
;; tracked simultaneously. When both sides resolve (their trailing stops
;; fire), the paper teaches the system: what distance would have been
;; optimal?
;; Depends on: Distances.

(require distances)

;; ── Struct ──────────────────────────────────────────────────────────

(struct paper-entry
  [composed-thought : Vector]          ; the thought at entry
  [entry-price : f64]                  ; price when the paper was created
  [distances : Distances]              ; from the exit observer at entry
  [buy-extreme : f64]                  ; best price in buy direction so far
  [buy-trail-stop : f64]               ; trailing stop level (from distances.trail)
  [sell-extreme : f64]                 ; best price in sell direction so far
  [sell-trail-stop : f64]              ; trailing stop level (from distances.trail)
  [buy-resolved : bool]                ; buy side's stop fired
  [sell-resolved : bool])              ; sell side's stop fired

;; ── Interface ───────────────────────────────────────────────────────

(define (make-paper-entry [composed-thought : Vector]
                          [entry-price : f64]
                          [distances : Distances])
  : PaperEntry
  ;; Both sides start unresolved. Trail stops computed from distances.trail.
  ;; Buy trail stop is below price, sell trail stop is above.
  (let ((trail-dist (* entry-price (:trail distances))))
    (paper-entry
      composed-thought
      entry-price
      distances
      entry-price                      ; buy-extreme — starts at entry
      (- entry-price trail-dist)       ; buy-trail-stop — below price
      entry-price                      ; sell-extreme — starts at entry
      (+ entry-price trail-dist)       ; sell-trail-stop — above price
      false                            ; buy-resolved
      false)))                         ; sell-resolved

(define (tick-paper [paper : PaperEntry]
                    [current-price : f64])
  : PaperEntry
  ;; Check trailing stops against current price. Update extremes and
  ;; trail stops. Mark sides as resolved when their stops fire.
  ;; Returns the updated paper entry.
  (let* (;; Buy side: track highest price, trail stop follows up
         (new-buy-extreme   (if (:buy-resolved paper)
                                (:buy-extreme paper)
                                (max (:buy-extreme paper) current-price)))
         (new-buy-trail     (if (:buy-resolved paper)
                                (:buy-trail-stop paper)
                                (max (:buy-trail-stop paper)
                                     (- new-buy-extreme
                                        (* new-buy-extreme
                                           (:trail (:distances paper)))))))
         (buy-fired         (and (not (:buy-resolved paper))
                                 (<= current-price new-buy-trail)))
         ;; Sell side: track lowest price, trail stop follows down
         (new-sell-extreme  (if (:sell-resolved paper)
                                (:sell-extreme paper)
                                (min (:sell-extreme paper) current-price)))
         (new-sell-trail    (if (:sell-resolved paper)
                                (:sell-trail-stop paper)
                                (min (:sell-trail-stop paper)
                                     (+ new-sell-extreme
                                        (* new-sell-extreme
                                           (:trail (:distances paper)))))))
         (sell-fired        (and (not (:sell-resolved paper))
                                 (>= current-price new-sell-trail))))
    (update paper
      :buy-extreme    new-buy-extreme
      :buy-trail-stop new-buy-trail
      :sell-extreme   new-sell-extreme
      :sell-trail-stop new-sell-trail
      :buy-resolved   (or (:buy-resolved paper) buy-fired)
      :sell-resolved  (or (:sell-resolved paper) sell-fired))))
