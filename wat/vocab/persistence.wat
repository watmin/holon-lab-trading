;; ── vocab/persistence.wat — trend persistence and memory ────────
;;
;; Properties of the price series, not direction.
;; "Is this market trending or mean-reverting? Persistent or random?"
;;
;; Hurst exponent, lag-1 autocorrelation, ADX zone classification.
;;
;; Expert profile: regime

(require facts)

;; ── Log returns ────────────────────────────────────────────────

(define (log-returns candles)
  "Successive log-ratios: ln(close_i / close_{i-1})."
  (map (lambda (i) (ln (/ (:close (nth candles i))
                          (:close (nth candles (- i 1))))))
       (range 1 (len candles))))

;; ── Hurst exponent ─────────────────────────────────────────────
;;
;; Rescaled range (R/S) estimate.
;; H > 0.5: persistent — trends continue.
;; H < 0.5: anti-persistent — reversals likely.
;; H = 0.5: random walk.

(define (hurst-estimate candles lookback)
  "Simplified Hurst via rescaled range. Returns None if degenerate."
  (when (and (>= (len candles) lookback) (>= lookback 10))
    (let ((returns (log-returns (last-n candles lookback))))
      (when (not (empty? returns))
        (let ((n    (len returns))
              (mean (/ (fold + 0.0 returns) n))
              (std  (sqrt (/ (fold + 0.0
                               (map (lambda (r) (* (- r mean) (- r mean))) returns))
                             n))))
          (when (> std 1e-15)
            (let ((cum-devs (fold-left
                              (lambda (acc r) (append acc (list (+ (last acc) (- r mean)))))
                              (list 0.0)
                              returns))
                  (max-cum (fold max (first cum-devs) (rest cum-devs)))
                  (min-cum (fold min (first cum-devs) (rest cum-devs)))
                  (rs (/ (- max-cum min-cum) std)))
              (when (> rs 0.0)
                (/ (ln rs) (ln n))))))))))

;; ── Autocorrelation ────────────────────────────────────────────
;;
;; Lag-1 autocorrelation of returns.
;; Positive = momentum. Negative = mean-reversion. Near zero = random.

(define (autocorrelation-lag1 candles lookback)
  "Lag-1 return autocorrelation. Returns None if degenerate."
  (when (and (>= (len candles) (+ lookback 1)) (>= lookback 5))
    (let ((window (last-n candles (+ lookback 1))))
      (let ((returns (map (lambda (i)
                            (/ (- (:close (nth window i)) (:close (nth window (- i 1))))
                               (:close (nth window (- i 1)))))
                          (range 1 (len window)))))
        (when (>= (len returns) 5)
          (let ((mean (/ (fold + 0.0 returns) (len returns)))
                (var  (fold + 0.0 (map (lambda (r) (* (- r mean) (- r mean))) returns))))
            (when (> (abs var) 1e-15)
              (let ((cov (fold + 0.0
                           (map (lambda (i)
                                  (* (- (nth returns i) mean)
                                     (- (nth returns (- i 1)) mean)))
                                (range 1 (len returns))))))
                (/ cov var)))))))))

;; ── ADX zone ───────────────────────────────────────────────────

(define (adx-zone adx)
  "Classify ADX into trend strength zone."
  (cond ((> adx 25.0) "strong-trend")
        ((< adx 20.0) "weak-trend")
        (else          "moderate-trend")))

;; ── Facts produced ─────────────────────────────────────────────

(define (eval-persistence candles)
  "Trend persistence facts."
  (let ((hurst (hurst-estimate candles (min (len candles) 100)))
        (ac    (autocorrelation-lag1 candles (min (len candles) 50)))
        (now   (last candles)))
    (append
      ;; Hurst — scalar + zone
      (if hurst
          (append
            (list (fact/scalar "hurst" (clamp hurst 0.0 1.0) 1.0))
            (cond ((> hurst 0.55) (list (fact/zone "hurst" "hurst-trending")))
                  ((< hurst 0.45) (list (fact/zone "hurst" "hurst-reverting")))
                  (else (list))))
          (list))

      ;; Autocorrelation — scalar + zone
      (if ac
          (append
            (list (fact/scalar "autocorr" (+ (* (clamp ac -1.0 1.0) 0.5) 0.5) 1.0))
            (cond ((> ac  0.1) (list (fact/zone "autocorr" "autocorr-positive")))
                  ((< ac -0.1) (list (fact/zone "autocorr" "autocorr-negative")))
                  (else (list))))
          (list))

      ;; ADX zone — pre-computed, always emitted
      (list (fact/zone "adx" (adx-zone (:adx now)))))))

;; ── What persistence does NOT do ───────────────────────────────
;; - Does NOT detect direction (it measures character of the series)
;; - Does NOT compute DFA, entropy, or fractals (that's regime.wat)
;; - Pure function. Candles in, facts out.
