;; simulation.wat — pure functions for trailing stop simulation
;;
;; Depends on: distances (struct), enums (Direction)
;;
;; No post state. Vec<f64> in, Distances out.
;; These simulate trailing stop mechanics against price histories.
;; The exit observer learns to predict these values BEFORE the path completes.

(require primitives)
(require distances)
(require enums)

;; simulate-trail: simulate a trailing stop at the given distance.
;; Walk the price history, track the extreme, fire when price retraces
;; by `distance` fraction from the extreme. Returns residue (signed gain).

(define (simulate-trail [price-history : Vec<f64>] [distance : f64]) : f64
  (let* ((entry (first price-history))
         (result
           (fold-left
             (lambda (state price)
               (let (((extreme settled) state))
                 (match settled
                   ((Some _) state)  ; already triggered — pass through
                   (None
                     (let* ((new-extreme (max extreme price))
                            (stop-level (* new-extreme (- 1.0 distance))))
                       (if (<= price stop-level)
                         (list new-extreme (Some (/ (- price entry) entry)))
                         (list new-extreme None)))))))
             (list entry None)
             (rest price-history)))
         ((final-extreme final-settled) result))
    (match final-settled
      ((Some residue) residue)
      (None (/ (- (last price-history) entry) entry)))))

;; simulate-stop: simulate a safety stop at the given distance.
;; Fire when price drops by `distance` fraction from entry. Returns residue.

(define (simulate-stop [price-history : Vec<f64>] [distance : f64]) : f64
  (let* ((entry (first price-history))
         (stop-level (* entry (- 1.0 distance)))
         (result
           (fold-left
             (lambda (acc price)
               (match acc
                 ((Some _) acc)
                 (None
                   (if (<= price stop-level)
                     (Some (/ (- price entry) entry))
                     None))))
             None
             (rest price-history))))
    (match result
      ((Some residue) residue)
      (None (/ (- (last price-history) entry) entry)))))

;; simulate-tp: simulate a take-profit at the given distance.
;; Fire when price rises by `distance` fraction from entry. Returns residue.

(define (simulate-tp [price-history : Vec<f64>] [distance : f64]) : f64
  (let* ((entry (first price-history))
         (tp-level (* entry (+ 1.0 distance)))
         (result
           (fold-left
             (lambda (acc price)
               (match acc
                 ((Some _) acc)
                 (None
                   (if (>= price tp-level)
                     (Some (/ (- price entry) entry))
                     None))))
             None
             (rest price-history))))
    (match result
      ((Some residue) residue)
      (None (/ (- (last price-history) entry) entry)))))

;; simulate-runner-trail: simulate a runner trailing stop.
;; Like simulate-trail but wider — for zero cost basis positions.

(define (simulate-runner-trail [price-history : Vec<f64>] [distance : f64]) : f64
  (simulate-trail price-history distance))

;; best-distance: sweep candidate distances, evaluate each via simulate-fn,
;; return the distance that maximizes residue.
;; Sweeps 100 candidates from 0.001 to 0.10.

(define (best-distance [price-history : Vec<f64>]
                       [simulate-fn : (fn Vec<f64> f64 -> f64)]) : f64
  (let* ((candidates (map (lambda (i) (* 0.001 (+ i 1))) (range 100)))
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
