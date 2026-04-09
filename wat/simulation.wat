;; simulation.wat — pure functions for computing optimal distances
;; Depends on: distances (Distances), enums (Direction)

(require primitives)
(require distances)
(require enums)

;; ── simulate-trail — trailing stop simulation ─────────────────────────
;; Simulate a trailing stop at the given distance percentage.
;; Returns the residue (profit/loss as fraction of entry).
(define (simulate-trail [price-history : Vec<f64>]
                        [distance : f64])
  : f64
  (let ((entry (first price-history))
        (n (length price-history)))
    (if (< n 2)
      0.0
      (let ((extreme entry)
            (exit-price entry)
            (stopped false))
        (for-each (lambda (i)
          (when (not stopped)
            (let ((price (nth price-history i)))
              ;; Track the extreme (best price)
              (set! extreme (max extreme price))
              ;; Check if trail stop fires
              (let ((stop-level (* extreme (- 1.0 distance))))
                (when (<= price stop-level)
                  (set! exit-price price)
                  (set! stopped true))))))
          (range 1 n))
        (when (not stopped)
          (set! exit-price (last price-history)))
        (/ (- exit-price entry) entry)))))

;; ── simulate-stop — safety stop simulation ────────────────────────────
;; Returns residue if safety stop fires before trail.
(define (simulate-stop [price-history : Vec<f64>]
                       [distance : f64])
  : f64
  (let ((entry (first price-history))
        (stop-level (* entry (- 1.0 distance)))
        (n (length price-history))
        (exit-price (last price-history))
        (stopped false))
    (for-each (lambda (i)
      (when (not stopped)
        (let ((price (nth price-history i)))
          (when (<= price stop-level)
            (set! exit-price price)
            (set! stopped true)))))
      (range 1 n))
    (/ (- exit-price entry) entry)))

;; ── simulate-tp — take-profit simulation ──────────────────────────────
;; Returns residue if take-profit fires.
(define (simulate-tp [price-history : Vec<f64>]
                     [distance : f64])
  : f64
  (let ((entry (first price-history))
        (tp-level (* entry (+ 1.0 distance)))
        (n (length price-history))
        (exit-price (last price-history))
        (hit false))
    (for-each (lambda (i)
      (when (not hit)
        (let ((price (nth price-history i)))
          (when (>= price tp-level)
            (set! exit-price price)
            (set! hit true)))))
      (range 1 n))
    (/ (- exit-price entry) entry)))

;; ── simulate-runner-trail — runner trailing stop simulation ───────────
;; Wider than trail — zero cost basis. Simulates from after TP hit.
(define (simulate-runner-trail [price-history : Vec<f64>]
                               [distance : f64])
  : f64
  (let ((entry (first price-history))
        (n (length price-history)))
    (if (< n 2)
      0.0
      (let ((extreme entry)
            (exit-price entry)
            (stopped false))
        (for-each (lambda (i)
          (when (not stopped)
            (let ((price (nth price-history i)))
              (set! extreme (max extreme price))
              (let ((stop-level (* extreme (- 1.0 distance))))
                (when (<= price stop-level)
                  (set! exit-price price)
                  (set! stopped true))))))
          (range 1 n))
        (when (not stopped)
          (set! exit-price (last price-history)))
        (/ (- exit-price entry) entry)))))

;; ── best-distance — sweep candidates, return the best ─────────────────
;; simulate-fn: (Vec<f64>, f64) → f64 — one of the simulate-* functions.
(define (best-distance [price-history : Vec<f64>]
                       [simulate-fn : (Vec<f64>, f64) -> f64])
  : f64
  (let ((num-candidates 50)
        (min-dist 0.002)
        (max-dist 0.10)
        (step (/ (- max-dist min-dist) (+ 0.0 num-candidates)))
        (best-dist min-dist)
        (best-residue f64-neg-infinity))
    (for-each (lambda (i)
      (let ((candidate (+ min-dist (* (+ 0.0 i) step)))
            (residue (simulate-fn price-history candidate)))
        (when (> residue best-residue)
          (set! best-residue residue)
          (set! best-dist candidate))))
      (range 0 num-candidates))
    best-dist))

;; ── compute-optimal-distances — hindsight optimal for all four ────────
;; direction: Direction — :up or :down. Which way the price moved.
;; Pure. No post state. price-history in, Distances out.
(define (compute-optimal-distances [price-history : Vec<f64>]
                                   [direction : Direction])
  : Distances
  (let (;; For :down direction, invert prices so the logic is symmetric
        (effective-history
          (match direction
            (:up price-history)
            (:down (map (lambda (p)
                     (let ((entry (first price-history)))
                       ;; Mirror around entry: entry + (entry - p)
                       (- (* 2.0 entry) p)))
                   price-history))))
        (optimal-trail (best-distance effective-history simulate-trail))
        (optimal-stop (best-distance effective-history simulate-stop))
        (optimal-tp (best-distance effective-history simulate-tp))
        (optimal-runner (best-distance effective-history simulate-runner-trail)))
    (distances optimal-trail optimal-stop optimal-tp optimal-runner)))
