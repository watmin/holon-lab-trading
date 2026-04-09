;; simulation.wat — pure functions for trailing stop simulation
;; Depends on: distances (Distances), enums (Direction)
;; No post state. Vec<f64> in, f64 out.

(require primitives)
(require enums)
(require distances)

;; Simulate a trailing stop at the given distance percentage.
;; price-history: close prices from entry to now.
;; Returns residue (positive = profit, negative = loss).
;; direction: :up means tracking buy-side (trailing from above), :down means sell-side.
(define (simulate-trail [price-history : Vec<f64>] [distance : f64] [direction : Direction])
  : f64
  (let ((entry (first price-history))
        (n     (length price-history)))
    (if (< n 2)
      0.0
      (match direction
        (:up
          ;; Buy-side: price should rise. Trail below the peak.
          (let ((peak entry)
                (trail-stop (* entry (- 1.0 distance)))
                (exit-price entry))
            (for-each (lambda (i)
              (let ((price (nth price-history i)))
                (when (> price peak)
                  (set! peak price)
                  (set! trail-stop (* peak (- 1.0 distance))))
                (when (<= price trail-stop)
                  (set! exit-price price))))
              (range 1 n))
            ;; If never stopped, exit at last price
            (let ((final (if (= exit-price entry) (last price-history) exit-price)))
              (/ (- final entry) entry))))
        (:down
          ;; Sell-side: price should fall. Trail above the trough.
          (let ((trough entry)
                (trail-stop (* entry (+ 1.0 distance)))
                (exit-price entry))
            (for-each (lambda (i)
              (let ((price (nth price-history i)))
                (when (< price trough)
                  (set! trough price)
                  (set! trail-stop (* trough (+ 1.0 distance))))
                (when (>= price trail-stop)
                  (set! exit-price price))))
              (range 1 n))
            (let ((final (if (= exit-price entry) (last price-history) exit-price)))
              (/ (- entry final) entry))))))))

;; Simulate a safety stop at the given distance.
(define (simulate-stop [price-history : Vec<f64>] [distance : f64] [direction : Direction])
  : f64
  (let ((entry (first price-history))
        (n     (length price-history)))
    (if (< n 2)
      0.0
      (match direction
        (:up
          (let ((stop-level (* entry (- 1.0 distance)))
                (exit-price (last price-history)))
            (for-each (lambda (i)
              (let ((price (nth price-history i)))
                (when (<= price stop-level)
                  (set! exit-price price))))
              (range 1 n))
            (/ (- exit-price entry) entry)))
        (:down
          (let ((stop-level (* entry (+ 1.0 distance)))
                (exit-price (last price-history)))
            (for-each (lambda (i)
              (let ((price (nth price-history i)))
                (when (>= price stop-level)
                  (set! exit-price price))))
              (range 1 n))
            (/ (- entry exit-price) entry)))))))

;; Simulate a take-profit at the given distance.
(define (simulate-tp [price-history : Vec<f64>] [distance : f64] [direction : Direction])
  : f64
  (let ((entry (first price-history))
        (n     (length price-history)))
    (if (< n 2)
      0.0
      (match direction
        (:up
          (let ((tp-level (* entry (+ 1.0 distance)))
                (exit-price (last price-history)))
            (for-each (lambda (i)
              (let ((price (nth price-history i)))
                (when (>= price tp-level)
                  (set! exit-price price))))
              (range 1 n))
            (/ (- exit-price entry) entry)))
        (:down
          (let ((tp-level (* entry (- 1.0 distance)))
                (exit-price (last price-history)))
            (for-each (lambda (i)
              (let ((price (nth price-history i)))
                (when (<= price tp-level)
                  (set! exit-price price))))
              (range 1 n))
            (/ (- entry exit-price) entry)))))))

;; Simulate a runner trailing stop at the given distance.
(define (simulate-runner-trail [price-history : Vec<f64>] [distance : f64] [direction : Direction])
  : f64
  ;; Same mechanics as trail but wider distance — used after principal recovery.
  (simulate-trail price-history distance direction))

;; Sweep candidates, evaluate each via simulate-fn, return the best.
(define (best-distance [price-history : Vec<f64>] [simulate-fn : fn] [direction : Direction])
  : f64
  (let ((steps 50)
        (lo    0.005)
        (hi    0.10)
        (step-size (/ (- hi lo) (+ 0.0 steps)))
        (best-val lo)
        (best-res f64-neg-infinity))
    (for-each (lambda (i)
      (let ((candidate (+ lo (* (+ 0.0 i) step-size)))
            (residue   (simulate-fn price-history candidate direction)))
        (when (> residue best-res)
          (set! best-val candidate)
          (set! best-res residue))))
      (range 0 (+ steps 1)))
    best-val))

;; Compute optimal distances for a completed price history.
;; The objective: maximize residue for each distance independently.
(define (compute-optimal-distances [price-history : Vec<f64>] [direction : Direction])
  : Distances
  (let ((opt-trail        (best-distance price-history simulate-trail direction))
        (opt-stop         (best-distance price-history simulate-stop direction))
        (opt-tp           (best-distance price-history simulate-tp direction))
        (opt-runner-trail (best-distance price-history simulate-runner-trail direction)))
    (make-distances opt-trail opt-stop opt-tp opt-runner-trail)))
