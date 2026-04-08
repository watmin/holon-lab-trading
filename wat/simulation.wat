;; simulation.wat — pure functions for trailing stop simulation.
;;
;; Depends on: Distances, Direction.
;;
;; Pure functions that simulate trailing stop mechanics against price
;; histories. No post state. Vec<f64> in, f64 out.
;; compute-optimal-distances + helpers.
;;
;; The objective function: for each distance (trail, stop, tp, runner-trail),
;; sweep candidate values against the price-history. For each candidate,
;; simulate the trailing stop mechanics. The candidate that produces the
;; maximum residue IS the optimal distance.

(require primitives)
(require enums)       ; Direction
(require distances)   ; Distances

;; ── compute-optimal-distances — the main entry point ────────────────────
;;
;; direction: Direction — :up or :down. Which way the price moved.
;; Takes no self. Pure. price-history in, Distances out.
;; Called by the enterprise when enriching TreasurySettlement into Settlement.

(define (compute-optimal-distances [price-history : Vec<f64>]
                                    [direction : Direction])
  : Distances
  (let* (;; Sweep trail distance
         (optimal-trail
           (best-distance price-history
             (lambda (ph d) (simulate-trail ph d direction))))
         ;; Sweep stop distance
         (optimal-stop
           (best-distance price-history
             (lambda (ph d) (simulate-stop ph d direction))))
         ;; Sweep take-profit distance
         (optimal-tp
           (best-distance price-history
             (lambda (ph d) (simulate-tp ph d direction))))
         ;; Sweep runner trail distance
         (optimal-runner
           (best-distance price-history
             (lambda (ph d) (simulate-runner-trail ph d direction)))))
    (make-distances optimal-trail optimal-stop optimal-tp optimal-runner)))

;; ── best-distance — sweep helper ────────────────────────────────────────
;;
;; Try candidates from 0.002 to 0.10 in 50 steps. Return the distance
;; that maximizes the residue (simulated by the given function).

(define (best-distance [price-history : Vec<f64>]
                        [simulate-fn : Fn])
  : f64
  (let* ((steps 50)
         (min-d 0.002)
         (max-d 0.100)
         (step-size (/ (- max-d min-d) (- steps 1)))
         (candidates (map (lambda (i) (+ min-d (* i step-size)))
                          (range steps)))
         (results (map (lambda (d)
                         (list d (simulate-fn price-history d)))
                       candidates)))
    ;; Pick the candidate with the highest residue
    (first (first (sort-by second > results)))))

;; ── simulate-trail ──────────────────────────────────────────────────────
;;
;; Given a price series, distance, and direction, simulate a trailing stop
;; and return the residue (profit or loss as fraction of entry).

(define (simulate-trail [price-history : Vec<f64>]
                         [distance : f64]
                         [direction : Direction])
  : f64
  (let* ((entry (first price-history))
         (prices (rest price-history))
         (extreme entry)
         (exit-price
           (fold (lambda (result price)
                   (if (some? result)
                       result
                       (let* ((new-extreme
                                (match direction
                                  (:up   (max extreme price))
                                  (:down (min extreme price))))
                              (trail-level
                                (match direction
                                  (:up   (* new-extreme (- 1.0 distance)))
                                  (:down (* new-extreme (+ 1.0 distance)))))
                              (triggered
                                (match direction
                                  (:up   (<= price trail-level))
                                  (:down (>= price trail-level)))))
                         (set! extreme new-extreme)
                         (if triggered
                             (Some trail-level)
                             None))))
                 None
                 prices)))
    ;; Residue: how much gained or lost
    (let ((exit (match exit-price
                  ((Some p) p)
                  (None (last price-history)))))
      (match direction
        (:up   (/ (- exit entry) entry))
        (:down (/ (- entry exit) entry))))))

;; ── simulate-stop ───────────────────────────────────────────────────────

(define (simulate-stop [price-history : Vec<f64>]
                        [distance : f64]
                        [direction : Direction])
  : f64
  (let* ((entry (first price-history))
         (prices (rest price-history))
         (stop-level (match direction
                       (:up   (* entry (- 1.0 distance)))
                       (:down (* entry (+ 1.0 distance)))))
         (hit (some? (filter (lambda (p)
                               (match direction
                                 (:up   (<= p stop-level))
                                 (:down (>= p stop-level))))
                             prices))))
    (if hit
        (- distance)   ; loss = negative residue
        ;; Never hit — use final price
        (match direction
          (:up   (/ (- (last price-history) entry) entry))
          (:down (/ (- entry (last price-history)) entry))))))

;; ── simulate-tp ─────────────────────────────────────────────────────────

(define (simulate-tp [price-history : Vec<f64>]
                      [distance : f64]
                      [direction : Direction])
  : f64
  (let* ((entry (first price-history))
         (prices (rest price-history))
         (tp-level (match direction
                     (:up   (* entry (+ 1.0 distance)))
                     (:down (* entry (- 1.0 distance)))))
         (hit (some? (filter (lambda (p)
                               (match direction
                                 (:up   (>= p tp-level))
                                 (:down (<= p tp-level))))
                             prices))))
    (if hit distance
        ;; Never hit — use final price
        (match direction
          (:up   (/ (- (last price-history) entry) entry))
          (:down (/ (- entry (last price-history)) entry))))))

;; ── simulate-runner-trail ───────────────────────────────────────────────
;;
;; Runner trail is the same mechanics as trail but wider.
;; The optimal runner distance maximizes residue beyond principal recovery.

(define (simulate-runner-trail [price-history : Vec<f64>]
                                [distance : f64]
                                [direction : Direction])
  : f64
  ;; Same trailing mechanics, different distance.
  (simulate-trail price-history distance direction))
