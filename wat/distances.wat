;; distances.wat — Distances, Levels, distances-to-levels
;; Depends on: enums (Side)

(require primitives)
(require enums)

;; ── Distances — percentage of price ───────────────────────────────────
;; From the exit observer. Scale-free. Observers think in Distances.
(struct distances
  [trail : f64]
  [stop : f64]
  [tp : f64]
  [runner-trail : f64])

;; ── Levels — absolute price levels ────────────────────────────────────
;; From the post. Computed from distance x price. Trades execute at Levels.
(struct levels
  [trail-stop : f64]
  [safety-stop : f64]
  [take-profit : f64]
  [runner-trail-stop : f64])

;; ── distances-to-levels — convert percentages to prices ───────────────
;; Side-dependent: buy stops are below price, sell stops are above.
;; One place to get the signs right.
(define (distances-to-levels [d : Distances]
                             [price : f64]
                             [side : Side])
  : Levels
  (match side
    (:buy
      ;; Buy: price goes up is good. Stops are below, TP above.
      (levels
        (* price (- 1.0 (:trail d)))         ; trail-stop below
        (* price (- 1.0 (:stop d)))          ; safety-stop below
        (* price (+ 1.0 (:tp d)))            ; take-profit above
        (* price (- 1.0 (:runner-trail d))))) ; runner-trail below
    (:sell
      ;; Sell: price goes down is good. Stops are above, TP below.
      (levels
        (* price (+ 1.0 (:trail d)))         ; trail-stop above
        (* price (+ 1.0 (:stop d)))          ; safety-stop above
        (* price (- 1.0 (:tp d)))            ; take-profit below
        (* price (+ 1.0 (:runner-trail d))))))) ; runner-trail above
