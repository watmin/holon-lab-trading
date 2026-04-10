;; distances.wat — Distances and Levels
;; Depends on: nothing (enums for Side in distances-to-levels)
;; Distances are percentages (from exit observer — scale-free).
;; Levels are absolute prices (from the post — computed from distance x price).

(require primitives)
(require enums)

;; ── Distances — four exit values as percentages of price ───────────
(struct distances
  [trail : f64]               ; trailing stop distance
  [stop : f64]                ; safety stop distance
  [tp : f64]                  ; take-profit distance
  [runner-trail : f64])       ; runner trailing stop distance (wider than trail)

(define (make-distances [trail : f64]
                        [stop : f64]
                        [tp : f64]
                        [runner-trail : f64])
  : Distances
  (distances trail stop tp runner-trail))

;; ── Levels — absolute price levels for stops ───────────────────────
(struct levels
  [trail-stop : f64]          ; absolute price for trailing stop
  [safety-stop : f64]         ; absolute price for safety stop
  [take-profit : f64]         ; absolute price for take-profit
  [runner-trail-stop : f64])  ; absolute price for runner trailing stop

(define (make-levels [trail-stop : f64]
                     [safety-stop : f64]
                     [take-profit : f64]
                     [runner-trail-stop : f64])
  : Levels
  (levels trail-stop safety-stop take-profit runner-trail-stop))

;; ── distances-to-levels — convert percentages to absolute prices ───
;; Side-dependent: buy stops are below price, sell stops are above.
;; One place to get the signs right.
(define (distances-to-levels [d : Distances] [price : f64] [s : Side])
  : Levels
  (match s
    (:buy
      ;; Buy: price going up is good. Stops are below. TP is above.
      (make-levels
        (* price (- 1.0 (:trail d)))          ; trail-stop below
        (* price (- 1.0 (:stop d)))           ; safety-stop below
        (* price (+ 1.0 (:tp d)))             ; take-profit above
        (* price (- 1.0 (:runner-trail d))))) ; runner-trail below (wider)
    (:sell
      ;; Sell: price going down is good. Stops are above. TP is below.
      (make-levels
        (* price (+ 1.0 (:trail d)))          ; trail-stop above
        (* price (+ 1.0 (:stop d)))           ; safety-stop above
        (* price (- 1.0 (:tp d)))             ; take-profit below
        (* price (+ 1.0 (:runner-trail d)))))))  ; runner-trail above (wider)
