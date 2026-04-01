;; -- sizing.wat -- the economic decision functions ---------------------------
;;
;; Two functions. No state. Pure arithmetic.
;; Kelly sizes from the conviction-accuracy curve.
;; Signal weight scales learning by move magnitude.

(require core/primitives)

;; -- Kelly fraction ---------------------------------------------------------

;; Uses the fitted curve: accuracy = 0.50 + a * exp(b * conviction)
;; Estimated via log-linear regression on binned resolved predictions.
;; The curve generalizes from ALL resolved predictions -- no per-level
;; sample minimum.
;;
;; Preconditions:
;;   - At least 500 resolved predictions
;;   - At least 10 predictions per bin (20 bins)
;;   - At least 3 bins with accuracy > 0.505 (for log-linear fit)
;;   - Positive edge (2 * win_rate - 1 > 0)
;;
;; Returns (position-frac, curve-a, curve-b) or nothing.

(define (bin resolved n-bins)
  "Sort resolved predictions by conviction, split into n equal-size bins.
   Returns list of (mean-conviction, accuracy) per bin."
  (let ((sorted (sort-by first resolved))
        (size   (/ (len sorted) n-bins)))
    (map (lambda (i)
           (let ((chunk (map (lambda (j) (nth sorted j))
                             (range (* i size) (min (* (+ i 1) size) (len sorted))))))
             (list (mean (map first chunk))
                   (/ (count (lambda (x) (second x)) chunk) (len chunk)))))
         (range 0 n-bins))))

(define (log-linear-regression points)
  "Fit accuracy = 0.50 + a * exp(b * conviction) via OLS on log-transformed bins.
   Keeps only bins with accuracy > 0.505. Returns (a, b) or #f.
   The log transform: ln(accuracy - 0.50) = ln(a) + b * conviction."
  (let ((valid (filter (lambda (p) (> (second p) 0.505)) points)))
    (when (>= (len valid) 3)
      (let* ((xs  (map first valid))
             (ys  (map (lambda (p) (ln (- (second p) 0.50))) valid))
             (mx  (mean xs))
             (my  (mean ys))
             (cov (fold + 0.0 (map (lambda (x y) (* (- x mx) (- y my))) xs ys)))
             (var (fold + 0.0 (map (lambda (x) (* (- x mx) (- x mx))) xs)))
             (b   (/ cov var))
             (a   (exp (- my (* b mx)))))
        (list a b)))))

(define (kelly-frac conviction resolved n-bins move-threshold)
  "Half-Kelly position fraction from exponential conviction-accuracy curve.
   Returns (position-frac, a, b) or #f."
  (when (>= (len resolved) 500)
    (when-let ((curve (log-linear-regression (bin resolved n-bins))))
      (let* ((a        (first curve))
             (b        (second curve))
             (win-rate (min 0.95 (+ 0.50 (* a (exp (* b conviction))))))
             (edge     (- (* 2.0 win-rate) 1.0)))
        (when (> edge 0.0)
          (list (/ (/ edge 2.0) move-threshold) a b))))))

;; The curve fitting:
;;   1. Sort resolved by conviction
;;   2. Bin into 20 equal-size bins
;;   3. For each bin: mean conviction, accuracy
;;   4. Keep bins where accuracy > 0.505
;;   5. ln(accuracy - 0.50) = ln(a) + b * conviction
;;   6. Ordinary least squares on the log-transformed points

;; -- Signal weight ----------------------------------------------------------

(define (signal-weight abs-pct move-sum move-count)
  "Scale an observation by how large the triggering move was vs running average.
   Bigger moves teach more strongly than typical moves.
   Mutates move-sum and move-count (running accumulators)."
  (set! move-sum (+ move-sum abs-pct))
  (set! move-count (+ move-count 1))
  (/ abs-pct (/ move-sum move-count)))

;; -- What sizing does NOT do ------------------------------------------------
;; - Does NOT decide direction (that's the manager)
;; - Does NOT cap position size (that's position-frac on portfolio)
;; - Does NOT apply risk modulation (that's the risk branches)
;; - Does NOT track resolved predictions (that's the observer)
;; - Pure functions. No state. No side effects (except signal-weight accumulators).
