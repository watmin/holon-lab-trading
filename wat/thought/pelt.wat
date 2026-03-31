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

  ; rune:gaze(phantom) — cumulative-sum is not in the wat language
  ; rune:gaze(phantom) — cumulative-sum-of-squares is not in the wat language
  ; rune:gaze(phantom) — backtrace is not in the wat language
  ; rune:gaze(phantom) — dynamic-program is not in the wat language
  (let ((cum-sum (cumulative-sum values))
        (cum-sq  (cumulative-sum-of-squares values)))
    (backtrace (dynamic-program cum-sum cum-sq penalty))))

;; ── Penalty ────────────────────────────────────────────────────

;; BIC-derived penalty: 2 * variance * ln(n)
;; Adapts to the data's own scale. More variance = more penalty needed
;; to claim a changepoint is real.

; rune:gaze(phantom) — len is not in the wat language
; rune:gaze(phantom) — variance is not in the wat language
; rune:gaze(phantom) — ln is not in the wat language
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

; rune:gaze(phantom) — last is not in the wat language
; rune:gaze(phantom) — nth is not in the wat language
; rune:gaze(phantom) — cond is not in the wat language
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
