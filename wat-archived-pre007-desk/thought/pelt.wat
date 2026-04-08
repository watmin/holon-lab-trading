;; ── thought/pelt.wat — PELT changepoint detection ───────────────
;;
;; Finds structural breaks in scalar time series.
;; The segments between changepoints become the narrative facts
;; that experts think about.
;;
;; PELT = Pruned Exact Linear Time. Optimal segmentation with
;; O(n) average complexity via candidate pruning.

;; ── Interface ──────────────────────────────────────────────────

;; The core function. Takes a scalar series and a penalty.
;; Returns changepoint indices — boundaries between segments.
;;
;; (pelt-changepoints values penalty) -> [usize]
;;
;; values:  &[f64] — any scalar time series (close, rsi, volume, etc.)
;; penalty: f64    — controls sensitivity. Higher = fewer changepoints.
;; returns: Vec<usize> — sorted indices where the series changes character.
;;          Empty if n < 3.

(define (pelt-changepoints values penalty)
  "Optimal changepoint detection via PELT.
   Minimizes sum of segment costs + penalty per changepoint."

  ;; Segment cost: residual sum of squares after removing the mean.
  ;;   cost(s, t) = sum(x^2) - (sum(x))^2 / (t - s)
  ;; This is the Gaussian likelihood cost function.

  ;; Algorithm:
  ;;   1. Build cumulative sum and cumulative sum-of-squares
  ;;   2. For each t in [1, n]:
  ;;      a. Find best predecessor s that minimizes cost[s] + seg_cost(s,t) + penalty
  ;;      b. Prune candidates: discard s where cost[s] + seg_cost(s,t) > cost[t] + penalty
  ;;      c. Add t to candidates
  ;;   3. Backtrace from n to recover changepoints
  ;;
  ;; The pruning step is what makes PELT O(n) on average instead of O(n^2).

  ;; The PELT dynamic program is too complex for a pure wat expression
  ;; (mutable candidate set, pruning, backtrace). The wat specifies the
  ;; contract; the Rust implements the O(n) algorithm.
  ;;
  ;; cumulative-sum: prefix sums of values. cum[i+1] = cum[i] + values[i].
  ;; cumulative-sum-of-squares: prefix sums of values^2.
  ;; dynamic-program: for each t, find best predecessor s minimizing
  ;;   cost[s] + seg-cost(s,t) + penalty. Prune candidates where
  ;;   cost[s] + seg-cost(s,t) > cost[t] + penalty. The pruning
  ;;   gives O(n) average complexity.
  ;; backtrace: follow the last-change pointers from n back to 0,
  ;;   collecting changepoint indices.
  ;;
  ;; seg-cost(s, t) = sum(x^2, s..t) - (sum(x, s..t))^2 / (t - s)
  ;;   Gaussian likelihood: residual sum of squares after removing mean.

  (define (cumulative-sum values)
    (scan + 0 values))

  (define (cumulative-sum-of-squares values)
    (scan + 0 (map (lambda (x) (* x x)) values)))

  ;; The dynamic program + backtrace is a single imperative algorithm.
  ;; Contract: returns sorted changepoint indices where the series
  ;; changes character. Empty if n < 3.
  ;; See src/thought/pelt.rs for the Rust implementation.
  (let ((cum-sum (cumulative-sum values))
        (cum-sq  (cumulative-sum-of-squares values)))
    (pelt-dp-backtrace cum-sum cum-sq penalty)))

;; ── Penalty ────────────────────────────────────────────────────

;; BIC-derived penalty: 2 * variance * ln(n)
;; Adapts to the data's own scale. More variance = more penalty needed
;; to claim a changepoint is real.

(define (variance values)
  "Population variance: mean((x - mean)^2)."
  (let ((n (len values))
        (mean (/ (sum values) (len values))))
    (/ (sum (map (lambda (x) (expt (- x mean) 2)) values)) n)))

(define (bic-penalty values)
  "Bayesian Information Criterion penalty for PELT.
   Returns 1e10 for degenerate inputs (n < 2 or zero variance)."
  (let ((n (len values))
        (var (variance values)))
    (if (or (< n 2) (< var 1e-20))
        1e10
        (* 2.0 var (ln n)))))

;; ── Convenience ────────────────────────────────────────────────

;; Most recent segment direction. The thought layer's main consumer.
;; "up", "down", or None if the series is too short or flat.

(define (most-recent-segment-dir values)
  "Direction of the last PELT segment. Uses BIC penalty.
   Returns 'up', 'down', or None."
  (if (< (len values) 5) None
      (let ((cps (pelt-changepoints values (bic-penalty values)))
            (start (or (last cps) 0))
            (change (- (last values) (nth values start))))
        (cond
          ((< (abs change) 1e-10) None)
          ((> change 0.0)        (Some "up"))
          (else                  (Some "down"))))))

;; ── Magic numbers ──────────────────────────────────────────────
;;
;; Segment cost: Gaussian likelihood (sum of squared residuals).
;;   This is the standard choice. Not a tuning knob.
;;
;; BIC penalty: 2 * var * ln(n).
;;   Standard statistical penalty. Not tuned.
;;
;; Minimum length: n < 3 returns empty. n < 5 for direction check.
;;   Structural segments of 1-2 candles are noise by definition.
;;
;; Direction threshold: |change| < 1e-10 = flat.
;;   Machine epsilon guard, not a tuning parameter.

;; ── What PELT does NOT do ──────────────────────────────────────
;; - Does NOT know about candles (takes raw &[f64])
;; - Does NOT encode (returns indices, not vectors)
;; - Does NOT choose which streams to segment (that's thought/mod.rs)
;; - Does NOT assign meaning to segments (that's the vocab modules)
;; - Pure algorithm. No state. No domain knowledge.
