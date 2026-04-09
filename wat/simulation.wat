;; simulation.wat — pure functions for trailing stop simulation
;; Depends on: distances, enums (Direction)

(require primitives)
(require distances)
(require enums)

;; Simulate a trailing stop at the given distance percentage.
;; Returns residue (positive = profit, negative = loss).
(define (simulate-trail [price-history : Vec<f64>] [distance : f64])
  : f64
  (let ((entry (first price-history))
        (extreme entry)
        (stop (* entry (- 1.0 distance))))
    (fold (lambda (result price)
      (if (not (= result None))
        result
        (begin
          (when (> price extreme)
            (set! extreme price)
            (set! stop (* extreme (- 1.0 distance))))
          (if (<= price stop)
            (/ (- price entry) entry)
            None))))
      None
      (rest price-history))
    ;; If never stopped, use last price
    (if (= result None)
      (/ (- (last price-history) entry) entry)
      result)))

;; Simulate a safety stop (fixed stop-loss).
(define (simulate-stop [price-history : Vec<f64>] [distance : f64])
  : f64
  (let ((entry (first price-history))
        (stop (* entry (- 1.0 distance))))
    (fold-left (lambda (result price)
      (if (some? result) result
        (if (<= price stop)
          (Some (/ (- stop entry) entry))
          None)))
      None
      (rest price-history))
    ;; Residue from hitting stop or holding
    (match result
      ((Some r) r)
      (None (/ (- (last price-history) entry) entry)))))

;; Simulate a take-profit level.
(define (simulate-tp [price-history : Vec<f64>] [distance : f64])
  : f64
  (let ((entry (first price-history))
        (target (* entry (+ 1.0 distance))))
    (fold-left (lambda (result price)
      (if (some? result) result
        (if (>= price target)
          (Some (/ (- target entry) entry))
          None)))
      None
      (rest price-history))
    (match result
      ((Some r) r)
      (None (/ (- (last price-history) entry) entry)))))

;; Simulate a runner trailing stop (wider trail after principal recovery).
(define (simulate-runner-trail [price-history : Vec<f64>] [distance : f64])
  : f64
  ;; Same mechanics as trail but with wider distance (for runners)
  (simulate-trail price-history distance))

;; Sweep candidates to find best distance for a given simulate-fn.
(define (best-distance [price-history : Vec<f64>] [simulate-fn : fn] [steps : usize])
  : f64
  (let ((candidates (map (lambda (i) (* (+ i 1.0) (/ 0.1 (+ steps 0.0))))
                         (range 0 steps)))
        (results (map (lambda (d) (list d (simulate-fn price-history d))) candidates))
        (best (fold (lambda (best pair)
                (if (> (second pair) (second best)) pair best))
              (first results)
              (rest results))))
    (first best)))

;; Compute optimal distances by sweeping candidates against price history.
;; Direction-aware: for :up, use buy-side simulation; for :down, sell-side.
(define (compute-optimal-distances [price-history : Vec<f64>] [direction : Direction])
  : Distances
  (let ((history (match direction
                   (:up price-history)
                   ;; For sell-side: invert the price series
                   (:down (map (lambda (p) (/ 1.0 p)) price-history))))
        (steps 50)  ; sweep resolution
        (opt-trail (best-distance history simulate-trail steps))
        (opt-stop (best-distance history simulate-stop steps))
        (opt-tp (best-distance history simulate-tp steps))
        (opt-runner (best-distance history simulate-runner-trail steps)))
    (make-distances opt-trail opt-stop opt-tp opt-runner)))
