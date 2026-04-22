;; ── simulation.wat ──────────────────────────────────────────────────
;;
;; Pure functions that simulate trailing stop mechanics against price
;; histories. No post state. Vec<f64> in, f64 out.
;; Depends on: distances.

(require distances)

;; ── simulate-trail ─────────────────────────────────────────────────
;; Simulate a trailing stop at the given distance. Returns residue.
;; The trailing stop ratchets in the direction of movement.
;; distance is a fraction of the entry price.

(define (simulate-trail [price-history : Vec<f64>] [distance : f64])
  : f64
  (if (empty? price-history)
    0.0
    (let ((entry (first price-history))
          (trail-level (* entry (- 1.0 distance))))
      ;; Walk the price history. Track the extreme (highest price seen).
      ;; Trail level ratchets up: trail = extreme × (1 - distance).
      ;; When price drops below trail level, the stop fires.
      ;; Residue = (exit-price - entry) / entry.
      (fold-left
        (lambda (state price)
          (let (((extreme trail-lvl) state))
            (if (<= price trail-lvl)
              ;; Stop fired — return residue immediately
              ;; (fold continues but state is frozen via settled flag)
              state
              ;; Update extreme and trail
              (let ((new-extreme (max extreme price))
                    (new-trail (* new-extreme (- 1.0 distance))))
                (list new-extreme new-trail)))))
        (list entry trail-level)
        (rest price-history))
      ;; After the fold, compute residue from the final state.
      ;; If the stop never fired, use the last price.
      (let ((final-price (last price-history)))
        (/ (- final-price entry) entry)))))

;; ── simulate-stop ──────────────────────────────────────────────────
;; Simulate a safety stop at the given distance. Returns residue.
;; The safety stop is fixed at entry: stop-level = entry × (1 - distance).
;; If price drops below stop-level, the stop fires.

(define (simulate-stop [price-history : Vec<f64>] [distance : f64])
  : f64
  (if (empty? price-history)
    0.0
    (let ((entry (first price-history))
          (stop-level (* entry (- 1.0 distance))))
      ;; Walk the price history. If price drops below stop-level, exit.
      ;; Residue = (exit-price - entry) / entry. Negative = loss.
      (fold-left
        (lambda (state price)
          (let (((exited exit-price) state))
            (if exited
              state
              (if (<= price stop-level)
                (list true price)
                state))))
        (list false 0.0)
        (rest price-history))
      ;; After the fold, compute residue.
      (let (((exited exit-price) result))
        (if exited
          (/ (- exit-price entry) entry)
          ;; Stop never fired — use the last price
          (/ (- (last price-history) entry) entry))))))

;; ── best-distance ──────────────────────────────────────────────────
;; Sweep candidate distances, evaluate each via simulate-fn, return
;; the distance that produces the maximum residue.
;; Candidates: 0.5% to 10% in 0.5% increments (20 candidates).

(define (best-distance [price-history : Vec<f64>]
                       [simulate-fn : (Vec<f64> -> f64 -> f64)])
  : f64
  (let ((candidates (map (lambda (i) (* (+ i 1) 0.005))
                         (range 20)))
        (results (pmap (lambda (d) (list d (simulate-fn price-history d)))
                       candidates)))
    ;; Pick the candidate with the highest residue
    (first (fold-left
             (lambda (best candidate)
               (if (> (second candidate) (second best))
                 candidate
                 best))
             (first results)
             (rest results)))))

;; ── compute-optimal-distances ──────────────────────────────────────
;; The objective function. For each distance (trail, stop), sweep
;; candidate values against the price-history. The candidate that
;; produces the maximum residue IS the optimal distance.
;; direction: Direction — :up or :down. Which way the price moved.
;; For :down, the price-history is inverted (1/price) so the same
;; trailing-stop logic applies symmetrically.

(define (compute-optimal-distances [price-history : Vec<f64>]
                                   [direction : Direction])
  : Distances
  (let ((oriented-history
          (match direction
            (:up price-history)
            (:down (map (lambda (p) (/ 1.0 p)) price-history)))))
    (make-distances
      (best-distance oriented-history simulate-trail)
      (best-distance oriented-history simulate-stop))))
