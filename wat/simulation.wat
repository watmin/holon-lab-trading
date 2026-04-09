;; simulation.wat — pure functions for optimal distance computation
;; Depends on: distances.wat

(require primitives)
(require distances)
(require enums)

;; ── simulate-trail ─────────────────────────────────────────────────
;; Simulate a trailing stop at the given distance percentage.
;; Returns residue (positive = profit, negative = loss).
;; price-history: Vec<f64> — close prices from entry to now.
;; direction: implicit in the price-history (up = buy side).

(define (simulate-trail [price-history : Vec<f64>] [distance : f64])
  : f64
  (let ((entry (first price-history))
        (extreme entry)
        (stopped false)
        (stop-price 0.0))
    (for-each (lambda (price)
      (when (not stopped)
        (if (> price extreme)
          (set! extreme price)
          nil)
        (let ((trail-level (* extreme (- 1.0 distance))))
          (when (<= price trail-level)
            (set! stopped true)
            (set! stop-price price)))))
      (rest price-history))
    (if stopped
      (/ (- stop-price entry) entry)
      (/ (- (last price-history) entry) entry))))

;; ── simulate-stop ──────────────────────────────────────────────────
;; Simulate a safety stop (fixed from entry).

(define (simulate-stop [price-history : Vec<f64>] [distance : f64])
  : f64
  (let ((entry (first price-history))
        (stop-level (* entry (- 1.0 distance)))
        (stopped false)
        (stop-price 0.0))
    (for-each (lambda (price)
      (when (not stopped)
        (when (<= price stop-level)
          (set! stopped true)
          (set! stop-price price))))
      (rest price-history))
    (if stopped
      (/ (- stop-price entry) entry)
      (/ (- (last price-history) entry) entry))))

;; ── simulate-tp ────────────────────────────────────────────────────
;; Simulate take-profit at the given distance.

(define (simulate-tp [price-history : Vec<f64>] [distance : f64])
  : f64
  (let ((entry (first price-history))
        (tp-level (* entry (+ 1.0 distance)))
        (hit false)
        (hit-price 0.0))
    (for-each (lambda (price)
      (when (not hit)
        (when (>= price tp-level)
          (set! hit true)
          (set! hit-price price))))
      (rest price-history))
    (if hit
      (/ (- hit-price entry) entry)
      (/ (- (last price-history) entry) entry))))

;; ── simulate-runner-trail ──────────────────────────────────────────
;; Simulate a runner trailing stop (wider than normal trail).
;; Starts after take-profit is hit.

(define (simulate-runner-trail [price-history : Vec<f64>] [distance : f64])
  : f64
  (let ((entry (first price-history))
        (extreme (last price-history))
        (stopped false)
        (stop-price 0.0))
    ;; The runner starts from the peak — simulate trailing from highest
    (for-each (lambda (price)
      (when (not stopped)
        (if (> price extreme)
          (set! extreme price)
          nil)
        (let ((trail-level (* extreme (- 1.0 distance))))
          (when (<= price trail-level)
            (set! stopped true)
            (set! stop-price price)))))
      (rest price-history))
    (if stopped
      (/ (- stop-price entry) entry)
      (/ (- (last price-history) entry) entry))))

;; ── best-distance ──────────────────────────────────────────────────
;; Sweep candidates, evaluate each via simulate-fn, return the best.

(define (best-distance [price-history : Vec<f64>] [simulate-fn : (Vec<f64>, f64) -> f64])
  : f64
  (let ((n-candidates 50)
        (min-dist 0.002)
        (max-dist 0.10)
        (step (/ (- max-dist min-dist) n-candidates))
        (best-val min-dist)
        (best-residue f64-neg-infinity))
    (for-each (lambda (i)
      (let ((candidate (+ min-dist (* i step)))
            (residue (simulate-fn price-history candidate)))
        (when (> residue best-residue)
          (set! best-val candidate)
          (set! best-residue residue))))
      (range 0 (+ n-candidates 1)))
    best-val))

;; ── compute-optimal-distances ──────────────────────────────────────
;; The objective: for each distance, find the candidate that maximizes
;; residue. Pure function — price-history in, Distances out.

(define (compute-optimal-distances [price-history : Vec<f64>]
                                   [direction : Direction])
  : Distances
  (let (;; For sell-side, invert the price history (mirror)
        (prices (match direction
                  (:up price-history)
                  (:down (map (lambda (p) (- (* 2.0 (first price-history)) p))
                              price-history))))
        (opt-trail (best-distance prices simulate-trail))
        (opt-stop (best-distance prices simulate-stop))
        (opt-tp (best-distance prices simulate-tp))
        (opt-runner (best-distance prices simulate-runner-trail)))
    (make-distances opt-trail opt-stop opt-tp opt-runner)))
