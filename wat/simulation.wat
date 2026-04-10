;; simulation.wat — pure functions for trailing stop simulation
;; Depends on: distances, enums
;; No post state. Vec<f64> in, f64 out.

(require primitives)
(require distances)
(require enums)

;; Simulate a trailing stop at the given distance.
;; Returns residue: how much value was captured.
;; price-history: close prices from entry to now.
;; distance: as fraction of entry price.
(define (simulate-trail [price-history : Vec<f64>] [distance : f64])
  : f64
  (let ((entry (first price-history))
        (trail-level (* entry (- 1.0 distance))))
    (fold (lambda (state price)
            (let (((extreme trail-stop) state)
                  (new-extreme (max extreme price))
                  (new-trail (max trail-stop (* new-extreme (- 1.0 distance)))))
              (if (<= price new-trail)
                ;; Stop fired — return residue
                (list new-extreme new-trail)
                (list new-extreme new-trail))))
          (list entry trail-level)
          (rest price-history))
    ;; Final residue: last trail-stop vs entry
    (let ((final-trail (second (fold (lambda (state price)
                                (let (((extreme trail-stop) state)
                                      (new-extreme (max extreme price))
                                      (new-trail (max trail-stop (* new-extreme (- 1.0 distance)))))
                                  (list new-extreme new-trail)))
                              (list entry trail-level)
                              (rest price-history)))))
      (/ (- final-trail entry) entry))))

;; Simulate a safety stop at the given distance.
;; Returns residue (negative if stop fires before end).
(define (simulate-stop [price-history : Vec<f64>] [distance : f64])
  : f64
  (let ((entry (first price-history))
        (stop-level (* entry (- 1.0 distance))))
    (fold (lambda (best price)
            (if (<= price stop-level)
              (min best (/ (- stop-level entry) entry))
              (max best (/ (- price entry) entry))))
          0.0
          (rest price-history))))

;; Simulate a take-profit at the given distance.
;; Returns residue if TP fires.
(define (simulate-tp [price-history : Vec<f64>] [distance : f64])
  : f64
  (let ((entry (first price-history))
        (tp-level (* entry (+ 1.0 distance))))
    (fold (lambda (best price)
            (if (>= price tp-level)
              (max best distance)
              best))
          0.0
          (rest price-history))))

;; Simulate a runner trailing stop at the given distance.
;; Returns residue captured by the wider trail.
(define (simulate-runner-trail [price-history : Vec<f64>] [distance : f64])
  : f64
  (let ((entry (first price-history)))
    (fold (lambda (state price)
            (let (((extreme trail-stop best) state)
                  (new-extreme (max extreme price))
                  (new-trail (max trail-stop (* new-extreme (- 1.0 distance)))))
              (if (<= price new-trail)
                (list new-extreme new-trail (max best (/ (- new-trail entry) entry)))
                (list new-extreme new-trail best))))
          (list entry (* entry (- 1.0 distance)) 0.0)
          (rest price-history))
    (let ((result (fold (lambda (state price)
                    (let (((extreme trail-stop best) state)
                          (new-extreme (max extreme price))
                          (new-trail (max trail-stop (* new-extreme (- 1.0 distance)))))
                      (list new-extreme new-trail (max best (/ (- new-trail entry) entry)))))
                  (list entry (* entry (- 1.0 distance)) 0.0)
                  (rest price-history))))
      (nth result 2))))

;; Sweep candidates and find the best distance for a given simulate function.
(define (best-distance [price-history : Vec<f64>]
                       [simulate-fn : (Vec<f64> f64 -> f64)])
  : f64
  (let ((steps 50)
        (lo 0.002)
        (hi 0.10))
    (let ((step-size (/ (- hi lo) (+ 0.0 steps))))
      (first (fold (lambda (state i)
                (let (((best-d best-r) state)
                      (candidate (+ lo (* (+ 0.0 i) step-size)))
                      (residue (simulate-fn price-history candidate)))
                  (if (> residue best-r)
                    (list candidate residue)
                    (list best-d best-r))))
              (list lo f64-neg-infinity)
              (range 0 (+ steps 1)))))))

;; Compute optimal distances for a given price history and direction.
;; Direction-aware: flips the history for :down trades.
(define (compute-optimal-distances [price-history : Vec<f64>]
                                   [dir : Direction])
  : Distances
  (let ((history (match dir
                   (:up price-history)
                   ;; For :down, invert: work with reciprocal prices
                   (:down (map (lambda (p) (/ 1.0 p)) price-history)))))
    (make-distances
      (best-distance history simulate-trail)
      (best-distance history simulate-stop)
      (best-distance history simulate-tp)
      (best-distance history simulate-runner-trail))))
