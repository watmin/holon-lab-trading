;; distances.wat — two representations of exit thresholds + conversion.
;;
;; Depends on: nothing.
;;
;; Distances are percentages (from the exit observer — scale-free).
;; Levels are absolute prices (from the post — computed from distance x price).
;; Observers think in Distances. Trades execute at Levels. Different types
;; because they are different concepts with the same four fields.

(require primitives)
(require enums)    ; Side

;; ── Distances — percentages from the exit observer ───────────────────
(struct distances
  [trail : f64]                ; trailing stop distance (percentage of price)
  [stop : f64]                 ; safety stop distance
  [tp : f64]                   ; take-profit distance
  [runner-trail : f64])        ; runner trailing stop distance (wider than trail,
                               ; because the cost of stopping out a runner is zero)

;; ── Levels — absolute prices computed by the post ────────────────────
;; distance x current price -> level
;; Trade stores Levels. Proposal carries Distances.
(struct levels
  [trail-stop : f64]           ; absolute price level for trailing stop
  [safety-stop : f64]          ; absolute price level for safety stop
  [take-profit : f64]          ; absolute price level for take-profit
  [runner-trail-stop : f64])   ; absolute price level for runner trailing stop

;; ── distances-to-levels — named function on distances.wat ───────────────
;;
;; Converts percentage distances to absolute price levels. Side-dependent:
;; buy stops are below price, sell stops are above. One place to get the
;; signs right.

(define (distances-to-levels [dists : Distances]
                             [price : f64]
                             [side : Side])
  : Levels
  (match side
    (:buy
      (make-levels
        (* price (- 1.0 (:trail dists)))         ; trail-stop below
        (* price (- 1.0 (:stop dists)))          ; safety-stop below
        (* price (+ 1.0 (:tp dists)))            ; take-profit above
        (* price (- 1.0 (:runner-trail dists))))) ; runner-trail-stop below
    (:sell
      (make-levels
        (* price (+ 1.0 (:trail dists)))         ; trail-stop above
        (* price (+ 1.0 (:stop dists)))          ; safety-stop above
        (* price (- 1.0 (:tp dists)))            ; take-profit below
        (* price (+ 1.0 (:runner-trail dists))))))) ; runner-trail-stop above
