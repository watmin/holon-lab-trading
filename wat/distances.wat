;; distances.wat — Distances (percentages) and Levels (absolute prices)
;; Depends on: enums (Side)

(require primitives)
(require enums)

;; Distances — percentage of price. From exit observers. Scale-free.
(struct distances
  [trail : f64]                ; trailing stop distance
  [stop : f64]                 ; safety stop distance
  [tp : f64]                   ; take-profit distance
  [runner-trail : f64])        ; runner trailing stop distance (wider than trail)

(define (make-distances [trail : f64] [stop : f64] [tp : f64] [runner-trail : f64])
  : Distances
  (distances trail stop tp runner-trail))

;; Levels — absolute price levels. Computed from distance * price.
;; Trades execute at Levels. Observers think in Distances.
(struct levels
  [trail-stop : f64]           ; absolute price level for trailing stop
  [safety-stop : f64]          ; absolute price level for safety stop
  [take-profit : f64]          ; absolute price level for take-profit
  [runner-trail-stop : f64])   ; absolute price level for runner trailing stop

(define (make-levels [trail-stop : f64] [safety-stop : f64]
                     [take-profit : f64] [runner-trail-stop : f64])
  : Levels
  (levels trail-stop safety-stop take-profit runner-trail-stop))

;; Convert percentage distances to absolute price levels.
;; Side-dependent: buy stops are below price, sell stops are above.
;; One place to get the signs right.
(define (distances-to-levels [d : Distances] [price : f64] [side : Side])
  : Levels
  (match side
    (:buy
      ;; Buy: trail/stop below price, take-profit above
      (make-levels
        (* price (- 1.0 (:trail d)))            ; trail-stop
        (* price (- 1.0 (:stop d)))             ; safety-stop
        (* price (+ 1.0 (:tp d)))               ; take-profit
        (* price (- 1.0 (:runner-trail d)))))   ; runner-trail-stop
    (:sell
      ;; Sell: trail/stop above price, take-profit below
      (make-levels
        (* price (+ 1.0 (:trail d)))            ; trail-stop
        (* price (+ 1.0 (:stop d)))             ; safety-stop
        (* price (- 1.0 (:tp d)))               ; take-profit
        (* price (+ 1.0 (:runner-trail d)))))))  ; runner-trail-stop
