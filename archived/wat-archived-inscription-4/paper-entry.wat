;; paper-entry.wat — hypothetical trade inside a broker
;;
;; Depends on: distances (Distances), enums (Outcome, Direction)
;;
;; A paper trade is a "what if." Every candle, every broker gets one.
;; Both sides (buy and sell) are tracked simultaneously.
;; When both sides resolve (their trailing stops fire), the paper
;; teaches the system: what distance would have been optimal?
;;
;; distances.trail drives the paper's trailing stops (buy-trail-stop,
;; sell-trail-stop). The other three (stop, tp, runner-trail) are stored
;; for the learning signal — when the paper resolves, the Resolution
;; carries optimal-distances (what hindsight says was best).

(require primitives)
(require distances)
(require enums)

(struct paper-entry
  [composed-thought : Vector]     ; the thought at entry
  [entry-price : f64]            ; price when the paper was created
  [entry-atr : f64]              ; volatility at entry
  [distances : Distances]        ; from the exit observer at entry
  [buy-extreme : f64]            ; best price in buy direction so far
  [buy-trail-stop : f64]         ; trailing stop level (from distances.trail)
  [sell-extreme : f64]           ; best price in sell direction so far
  [sell-trail-stop : f64]        ; trailing stop level (from distances.trail)
  [buy-resolved : bool]          ; buy side's stop fired
  [sell-resolved : bool])        ; sell side's stop fired

;; ── make-paper-entry ───────────────────────────────────────────────
;; Create a new paper entry from the current composed thought, price,
;; ATR, and distances. Both sides start unresolved. The buy extreme
;; and sell extreme start at the entry price. Trailing stops are
;; computed from distances.trail.

(define (make-paper-entry [composed-thought : Vector]
                          [entry-price : f64]
                          [entry-atr : f64]
                          [distances : Distances])
  : PaperEntry
  (paper-entry
    composed-thought
    entry-price
    entry-atr
    distances
    entry-price                                    ; buy-extreme = entry price
    (* entry-price (- 1.0 (:trail distances)))     ; buy-trail-stop below
    entry-price                                    ; sell-extreme = entry price
    (* entry-price (+ 1.0 (:trail distances)))     ; sell-trail-stop above
    false                                          ; buy not resolved
    false))                                        ; sell not resolved

;; ── tick-paper ─────────────────────────────────────────────────────
;; Advance the paper by one candle. Update extremes and trailing stops
;; for both sides. Check if either side's trailing stop has fired.
;; Mutates the paper in place.

(define (tick-paper [paper : PaperEntry] [current-price : f64])
  (let ((trail (:trail (:distances paper))))
    ;; Buy side: track the maximum, trail below it
    (when (not (:buy-resolved paper))
      (when (> current-price (:buy-extreme paper))
        (set! (:buy-extreme paper) current-price)
        (set! (:buy-trail-stop paper)
              (* current-price (- 1.0 trail))))
      (when (<= current-price (:buy-trail-stop paper))
        (set! (:buy-resolved paper) true)))
    ;; Sell side: track the minimum, trail above it
    (when (not (:sell-resolved paper))
      (when (< current-price (:sell-extreme paper))
        (set! (:sell-extreme paper) current-price)
        (set! (:sell-trail-stop paper)
              (* current-price (+ 1.0 trail))))
      (when (>= current-price (:sell-trail-stop paper))
        (set! (:sell-resolved paper) true)))))

;; ── fully-resolved? ───────────────────────────────────────────────
;; Both sides have fired their trailing stops.

(define (fully-resolved? [paper : PaperEntry])
  : bool
  (and (:buy-resolved paper) (:sell-resolved paper)))

;; ── paper-pnl ──────────────────────────────────────────────────────
;; Compute the PnL for a resolved side.
;; Buy side: (exit - entry) / entry. Sell side: (entry - exit) / entry.
;; direction: which side we're computing for.
;; Returns: (pnl : f64, outcome : Outcome)

(define (paper-pnl [paper : PaperEntry] [direction : Direction])
  : (f64, Outcome)
  (let* ((entry (:entry-price paper))
         (pnl (match direction
                (:up   (/ (- (:buy-trail-stop paper) entry) entry))
                (:down (/ (- entry (:sell-trail-stop paper)) entry))))
         (outcome (if (>= pnl 0.0) :grace :violence)))
    (list pnl outcome)))
