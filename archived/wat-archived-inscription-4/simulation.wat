;; simulation.wat — pure functions for trailing stop simulation
;;
;; Depends on: distances (struct), enums (Direction)
;;
;; No post state. Vec<f64> in, Distances out.
;; These simulate trailing stop mechanics against price histories.
;; The exit observer learns to predict these values BEFORE the path completes.
;; Direction-aware: :up tracks max/trails below, :down tracks min/trails above.

(require primitives)
(require distances)
(require enums)

;; simulate-trail: simulate a trailing stop at the given distance.
;; Walk the price history, track the extreme, fire when price retraces
;; by `distance` fraction from the extreme. Returns residue (signed gain).
;;
;; :up — extreme is max, stop trails below, fires when price drops through
;; :down — extreme is min, stop trails above, fires when price rises through

(define (simulate-trail [price-history : Vec<f64>]
                        [distance : f64]
                        [direction : Direction]) : f64
  (let* ((entry (first price-history))
         (result
           (fold-left
             (lambda (state price)
               (let (((extreme settled) state))
                 (match settled
                   ((Some _) state)
                   (None
                     (let* ((new-extreme (match direction
                                           (:up   (max extreme price))
                                           (:down (min extreme price))))
                            (stop-level (match direction
                                          (:up   (* new-extreme (- 1.0 distance)))
                                          (:down (* new-extreme (+ 1.0 distance)))))
                            (triggered (match direction
                                         (:up   (<= price stop-level))
                                         (:down (>= price stop-level)))))
                       (if triggered
                         (list new-extreme (Some (match direction
                                                   (:up   (/ (- price entry) entry))
                                                   (:down (/ (- entry price) entry)))))
                         (list new-extreme None)))))))
             (list entry None)
             (rest price-history)))
         ((final-extreme final-settled) result))
    (match final-settled
      ((Some residue) residue)
      (None (match direction
              (:up   (/ (- (last price-history) entry) entry))
              (:down (/ (- entry (last price-history)) entry)))))))

;; simulate-stop: simulate a safety stop at the given distance.
;; :up — stop below entry, fires when price drops
;; :down — stop above entry, fires when price rises

(define (simulate-stop [price-history : Vec<f64>]
                       [distance : f64]
                       [direction : Direction]) : f64
  (let* ((entry (first price-history))
         (stop-level (match direction
                       (:up   (* entry (- 1.0 distance)))
                       (:down (* entry (+ 1.0 distance)))))
         (result
           (fold-left
             (lambda (acc price)
               (match acc
                 ((Some _) acc)
                 (None
                   (let ((triggered (match direction
                                      (:up   (<= price stop-level))
                                      (:down (>= price stop-level)))))
                     (if triggered
                       (Some (- distance))  ; loss = negative residue
                       None)))))
             None
             (rest price-history))))
    (match result
      ((Some residue) residue)
      (None (match direction
              (:up   (/ (- (last price-history) entry) entry))
              (:down (/ (- entry (last price-history)) entry)))))))

;; simulate-tp: simulate a take-profit at the given distance.
;; :up — tp above entry, fires when price rises
;; :down — tp below entry, fires when price drops

(define (simulate-tp [price-history : Vec<f64>]
                     [distance : f64]
                     [direction : Direction]) : f64
  (let* ((entry (first price-history))
         (tp-level (match direction
                     (:up   (* entry (+ 1.0 distance)))
                     (:down (* entry (- 1.0 distance)))))
         (result
           (fold-left
             (lambda (acc price)
               (match acc
                 ((Some _) acc)
                 (None
                   (let ((triggered (match direction
                                      (:up   (>= price tp-level))
                                      (:down (<= price tp-level)))))
                     (if triggered
                       (Some distance)  ; gain = positive residue
                       None)))))
             None
             (rest price-history))))
    (match result
      ((Some residue) residue)
      (None (match direction
              (:up   (/ (- (last price-history) entry) entry))
              (:down (/ (- entry (last price-history)) entry)))))))

;; simulate-runner-trail: simulate a runner trailing stop.
;; Like simulate-trail but wider — for zero cost basis positions.

(define (simulate-runner-trail [price-history : Vec<f64>]
                               [distance : f64]
                               [direction : Direction]) : f64
  (simulate-trail price-history distance direction))

;; best-distance: sweep candidate distances, evaluate each via simulate-fn,
;; return the distance that maximizes residue.
;; Sweeps 100 candidates from 0.001 to 0.10.

(define (best-distance [price-history : Vec<f64>]
                       [direction : Direction]
                       [simulate-fn : (fn Vec<f64> f64 Direction -> f64)]) : f64
  (let* ((candidates (map (lambda (i) (* 0.001 (+ i 1))) (range 100)))
         (results (map (lambda (d) (list d (simulate-fn price-history d direction)))
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
;; Direction-aware. price-history in, Distances out. Pure.

(define (compute-optimal-distances [price-history : Vec<f64>]
                                   [direction : Direction]) : Distances
  (make-distances
    (best-distance price-history direction simulate-trail)
    (best-distance price-history direction simulate-stop)
    (best-distance price-history direction simulate-tp)
    (best-distance price-history direction simulate-runner-trail)))
