;; distances.wat — Distances and Levels
;; Depends on: enums.wat (Side)

(require primitives)
(require enums)

;; ── Distances ──────────────────────────────────────────────────────
;; The four exit values. Percentage of price, not absolute levels.
;; Observers think in Distances. Trades execute at Levels.

(struct distances
  [trail : f64]
  [stop : f64]
  [tp : f64]
  [runner-trail : f64])

(define (make-distances [trail : f64] [stop : f64] [tp : f64] [runner-trail : f64])
  : Distances
  (distances trail stop tp runner-trail))

;; ── Levels ─────────────────────────────────────────────────────────
;; Absolute price levels. Computed from distance x price.

(struct levels
  [trail-stop : f64]
  [safety-stop : f64]
  [take-profit : f64]
  [runner-trail-stop : f64])

(define (make-levels [trail-stop : f64] [safety-stop : f64]
                     [take-profit : f64] [runner-trail-stop : f64])
  : Levels
  (levels trail-stop safety-stop take-profit runner-trail-stop))

;; ── distances-to-levels ────────────────────────────────────────────
;; Converts percentage distances to absolute price levels.
;; Side-dependent: buy stops are below price, sell stops are above.
;; One place to get the signs right.

(define (distances-to-levels [d : Distances] [price : f64] [side : Side])
  : Levels
  (match side
    (:buy
      (make-levels
        (* price (- 1.0 (:trail d)))          ; trail-stop below
        (* price (- 1.0 (:stop d)))           ; safety-stop below
        (* price (+ 1.0 (:tp d)))             ; take-profit above
        (* price (- 1.0 (:runner-trail d))))) ; runner-trail below
    (:sell
      (make-levels
        (* price (+ 1.0 (:trail d)))          ; trail-stop above
        (* price (+ 1.0 (:stop d)))           ; safety-stop above
        (* price (- 1.0 (:tp d)))             ; take-profit below
        (* price (+ 1.0 (:runner-trail d))))))) ; runner-trail above
