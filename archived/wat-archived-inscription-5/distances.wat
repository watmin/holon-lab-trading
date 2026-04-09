;; distances.wat — Distances and Levels
;; Depends on: enums (Side)
;; Distances are percentages (from exit observer — scale-free).
;; Levels are absolute prices (computed by the post from distance × price).
;; Observers think in Distances. Trades execute at Levels.

(require primitives)
(require enums)

(struct distances
  [trail : f64]                ; trailing stop distance (percentage of price)
  [stop : f64]                 ; safety stop distance
  [tp : f64]                   ; take-profit distance
  [runner-trail : f64])        ; runner trailing stop distance (wider than trail)

(define (make-distances [trail : f64] [stop : f64] [tp : f64] [runner-trail : f64])
  : Distances
  (distances trail stop tp runner-trail))

(struct levels
  [trail-stop : f64]           ; absolute price level for trailing stop
  [safety-stop : f64]          ; absolute price level for safety stop
  [take-profit : f64]          ; absolute price level for take-profit
  [runner-trail-stop : f64])   ; absolute price level for runner trailing stop

(define (make-levels [trail : f64] [safety : f64] [tp : f64] [runner : f64])
  : Levels
  (levels trail safety tp runner))

;; Convert percentage distances to absolute price levels.
;; Side-dependent: buy stops are below price, sell stops are above.
;; One place to get the signs right.
(define (distances-to-levels [dist : Distances] [price : f64] [side : Side])
  : Levels
  (match side
    (:buy
      ;; Buy: trail below, safety below, take-profit above, runner-trail below
      (levels
        (* price (- 1.0 (:trail dist)))
        (* price (- 1.0 (:stop dist)))
        (* price (+ 1.0 (:tp dist)))
        (* price (- 1.0 (:runner-trail dist)))))
    (:sell
      ;; Sell: trail above, safety above, take-profit below, runner-trail above
      (levels
        (* price (+ 1.0 (:trail dist)))
        (* price (+ 1.0 (:stop dist)))
        (* price (- 1.0 (:tp dist)))
        (* price (+ 1.0 (:runner-trail dist)))))))
