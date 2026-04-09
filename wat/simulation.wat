;; simulation.wat — pure functions for trailing stop simulation
;;
;; Depends on: distances (struct)
;;
;; No post state. Vec<f64> in, Distances out.
;; These simulate trailing stop mechanics against price histories.
;; The exit observer learns to predict these values BEFORE the path completes.

(require primitives)

;; simulate-trail: simulate a trailing stop at the given distance.
;; Walk the price history, track the extreme, fire when price retraces
;; by `distance` fraction from the extreme. Returns residue (signed gain).
;;
;; price-history: Vec<f64> — close prices from entry to now.
;; distance: f64 — trailing stop distance as fraction of price.

(define (simulate-trail [price-history : Vec<f64>] [distance : f64]) : f64
  (let ((entry (first price-history))
        (extreme entry))
    (fold-left
      (lambda (state price)
        (let (((extreme settled) state))
          (if settled
            state
            (let ((new-extreme (max extreme price))
                  (stop-level (* new-extreme (- 1.0 distance))))
              (if (<= price stop-level)
                (list new-extreme (/ (- price entry) entry))
                (list new-extreme false))))))
      (list extreme false)
      (rest price-history))
    ;; If never triggered, mark-to-market at the last price
    (let (((final-extreme settled) result))
      (if settled settled
        (/ (- (last price-history) entry) entry)))))

;; simulate-stop: simulate a safety stop at the given distance.
;; Fire when price drops by `distance` fraction from entry. Returns residue.

(define (simulate-stop [price-history : Vec<f64>] [distance : f64]) : f64
  (let ((entry (first price-history))
        (stop-level (* entry (- 1.0 distance))))
    (fold-left
      (lambda (acc price)
        (if acc acc
          (if (<= price stop-level)
            (/ (- price entry) entry)
            false)))
      false
      (rest price-history))
    ;; If never triggered, mark-to-market
    (if result result
      (/ (- (last price-history) entry) entry))))

;; simulate-tp: simulate a take-profit at the given distance.
;; Fire when price rises by `distance` fraction from entry. Returns residue.

(define (simulate-tp [price-history : Vec<f64>] [distance : f64]) : f64
  (let ((entry (first price-history))
        (tp-level (* entry (+ 1.0 distance))))
    (fold-left
      (lambda (acc price)
        (if acc acc
          (if (>= price tp-level)
            (/ (- price entry) entry)
            false)))
      false
      (rest price-history))
    ;; If never triggered, mark-to-market
    (if result result
      (/ (- (last price-history) entry) entry))))

;; simulate-runner-trail: simulate a runner trailing stop.
;; Like simulate-trail but wider — for zero cost basis positions.
;; After take-profit fires, the remaining position rides with this distance.

(define (simulate-runner-trail [price-history : Vec<f64>] [distance : f64]) : f64
  (simulate-trail price-history distance))

;; best-distance: sweep candidate distances, evaluate each via simulate-fn,
;; return the distance that maximizes residue.
;;
;; simulate-fn: (Vec<f64>, f64) → f64 — one of the simulate-* functions.
;; Sweeps 100 candidates from 0.001 to 0.10.

(define (best-distance [price-history : Vec<f64>]
                       [simulate-fn : (fn Vec<f64> f64 -> f64)]) : f64
  (let ((candidates (map (lambda (i) (* 0.001 (+ i 1))) (range 100)))
        (results (map (lambda (d) (list d (simulate-fn price-history d)))
                      candidates)))
    (first (fold-left
      (lambda (best pair)
        (let (((best-d best-r) best)
              ((d r) pair))
          (if (> r best-r) pair best)))
      (first results)
      (rest results)))))

;; compute-optimal-distances: the objective function.
;; For each distance (trail, stop, tp, runner-trail), find the candidate
;; that maximizes residue against the price history.
;; price-history in, Distances out. Pure.

(define (compute-optimal-distances [price-history : Vec<f64>]
                                   [direction : Direction]) : Distances
  (make-distances
    (best-distance price-history simulate-trail)
    (best-distance price-history simulate-stop)
    (best-distance price-history simulate-tp)
    (best-distance price-history simulate-runner-trail)))
