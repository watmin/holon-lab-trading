;; distances.wat — two representations of exit thresholds
;;
;; Depends on: enums (Side)
;;
;; Distances are percentages (from the exit observer — scale-free).
;; Levels are absolute prices (from the post — computed from distance × price).
;; Observers think in Distances. Trades execute at Levels. Different types
;; because they are different concepts with the same four fields.

(require primitives)
(require enums)

;; ── Distances — percentages from the exit observer ──────────────────
(struct distances
  [trail : f64]                ; trailing stop distance (percentage of price)
  [stop : f64]                 ; safety stop distance
  [tp : f64]                   ; take-profit distance
  [runner-trail : f64])        ; runner trailing stop distance (wider than trail,
                               ; because the cost of stopping out a runner is zero)

;; ── Levels — absolute prices computed by the post ───────────────────
;; distance × current price → level
;; Trade stores Levels. Proposal carries Distances.
(struct levels
  [trail-stop : f64]           ; absolute price level for trailing stop
  [safety-stop : f64]          ; absolute price level for safety stop
  [take-profit : f64]          ; absolute price level for take-profit
  [runner-trail-stop : f64])   ; absolute price level for runner trailing stop

;; ── distances-to-levels ─────────────────────────────────────────────
;; Converts percentage distances to absolute price levels.
;; Side-dependent: buy stops are below price, sell stops are above.
;; One place to get the signs right.

(define (distances-to-levels [dist : Distances]
                             [price : f64]
                             [side : Side])
  : Levels
  (match side
    (:buy
      ;; Buy: trail/safety stops below price, take-profit above
      (levels
        (* price (- 1.0 (:trail dist)))         ; trail-stop
        (* price (- 1.0 (:stop dist)))          ; safety-stop
        (* price (+ 1.0 (:tp dist)))            ; take-profit
        (* price (- 1.0 (:runner-trail dist))))) ; runner-trail-stop
    (:sell
      ;; Sell: trail/safety stops above price, take-profit below
      (levels
        (* price (+ 1.0 (:trail dist)))         ; trail-stop
        (* price (+ 1.0 (:stop dist)))          ; safety-stop
        (* price (- 1.0 (:tp dist)))            ; take-profit
        (* price (+ 1.0 (:runner-trail dist))))))) ; runner-trail-stop
