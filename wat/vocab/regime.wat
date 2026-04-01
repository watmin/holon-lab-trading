;; ── vocab/regime.wat — market regime characterization ────────────
;;
;; Abstract properties of the price series. Is it trending or choppy?
;; Persistent or mean-reverting? Orderly or chaotic?
;; These survive window noise better than candle-level patterns.
;;
;; The fattest module. Eight independent regime measures plus
;; pre-computed trend/volatility/range scalars.
;;
;; Lens: regime (exclusive)

(require facts)

;; ── Helpers ────────────────────────────────────────────────────

(define (log-returns closes)
  "Successive log-ratios from a close price series."
  (map (lambda (i) (ln (/ (nth closes i) (nth closes (- i 1)))))
       (range 1 (len closes))))

(define (linreg-slope xs ys)
  "Simple linear regression slope. Returns None if degenerate."
  (let ((n   (len xs))
        (sx  (fold + 0.0 xs))
        (sy  (fold + 0.0 ys))
        (sxx (fold + 0.0 (map (lambda (x) (* x x)) xs)))
        (sxy (fold + 0.0 (map * xs ys)))
        (denom (- (* n sxx) (* sx sx))))
    (when (> (abs denom) 1e-10)
      (/ (- (* n sxy) (* sx sy)) denom))))

;; ── KAMA Efficiency Ratio ──────────────────────────────────────

(define (kama-er closes)
  "ER = |net_move| / sum(|step_move|) over 10 periods."
  (let ((n  (len closes))
        (period (min 10 (- n 1)))
        (net    (abs (- (nth closes (- n 1)) (nth closes (- n 1 period)))))
        (steps  (fold + 0.0
                  (map (lambda (i) (abs (- (nth closes i) (nth closes (- i 1)))))
                       (range (- n period) n)))))
    (if (> steps 1e-10) (/ net steps) 0.0)))

;; ── Choppiness Index ───────────────────────────────────────────

(define (choppiness-index candles)
  "100 * log10(ATR_sum / range) / log10(period). Uses 14 periods."
  (let ((period (min 14 (- (len candles) 1)))
        (slice  (last-n candles period)))
    (let ((atr-sum (fold + 0.0
                     (map (lambda (i)
                            (let ((c    (nth slice i))
                                  (prev (nth slice (- i 1))))
                              (max (- (:high c) (:low c))
                                   (abs (- (:high c) (:close prev)))
                                   (abs (- (:low c) (:close prev))))))
                          (range 1 period))))
          (hi (fold max (:high (first slice)) (map :high (rest slice))))
          (lo (fold min (:low (first slice))  (map :low (rest slice))))
          (range (- hi lo)))
      (if (> range 1e-10)
          (* 100.0 (/ (ln (/ atr-sum range)) (ln period)))
          100.0))))

;; ── DFA Alpha ──────────────────────────────────────────────────

(define (dfa-alpha returns)
  "Detrended fluctuation analysis. Log-log slope at scales [4,6,8,12,16].
   Returns None if insufficient data or scales."
  (when (>= (len returns) 16)
    (let ((mean (/ (fold + 0.0 returns) (len returns)))
          (integrated (fold-left
                        (lambda (acc r) (append acc (list (+ (last acc) (- r mean)))))
                        (list 0.0)
                        returns))
          (scales (filter (lambda (s) (<= s (len integrated))) [4 6 8 12 16])))
      (when (>= (len scales) 3)
        ;; rune:scry(aspirational) — per-scale DFA fluctuation computation
        ;; For each scale: segment integrated series, detrend each segment,
        ;; compute RMS. Log-log regression of fluctuation vs scale gives alpha.
        None))))

;; ── Variance Ratio ─────────────────────────────────────────────

(define (variance-ratio returns k)
  "VR(k) = var(k-period returns) / (k * var(1-period returns)).
   VR > 1: momentum. VR < 1: mean-reversion. Returns None if degenerate."
  (when (>= (len returns) 10)
    (let ((var1 (/ (fold + 0.0 (map (lambda (r) (* r r)) returns))
                   (len returns))))
      (when (> var1 1e-20)
        (let ((k-returns (map (lambda (i)
                                (fold + 0.0 (map (lambda (j) (nth returns (+ i j)))
                                                  (range 0 k))))
                              (range 0 (+ (- (len returns) k) 1))))
              (var-k (/ (/ (fold + 0.0 (map (lambda (r) (* r r)) k-returns))
                           (len k-returns))
                        k)))
          (/ var-k var1))))))

;; ── DeMark TD Sequential ──────────────────────────────────────

(define (td-count closes)
  "Consecutive closes above/below close[i-4]. Resets on direction change."
  (fold-left
    (lambda (count i)
      (cond ((> (nth closes i) (nth closes (- i 4)))
             (if (> count 0) (+ count 1) 1))
            ((< (nth closes i) (nth closes (- i 4)))
             (if (< count 0) (- count 1) -1))
            (else 0)))
    0
    (range 4 (len closes))))

;; ── Aroon ──────────────────────────────────────────────────────

(define (aroon candles period)
  "Aroon up/down as (up, down) pair. Returns None if insufficient data."
  (when (> (len candles) period)
    (let ((slice (last-n candles (+ period 1))))
      (let ((hi-idx (fold-left (lambda (best i)
                                 (if (>= (:high (nth slice i)) (:high (nth slice best))) i best))
                               0 (range 0 (+ period 1))))
            (lo-idx (fold-left (lambda (best i)
                                 (if (<= (:low (nth slice i)) (:low (nth slice best))) i best))
                               0 (range 0 (+ period 1)))))
        (list (* 100.0 (/ hi-idx period))
              (* 100.0 (/ lo-idx period)))))))

;; ── Fractal Dimension (Katz) ───────────────────────────────────

(define (fractal-dimension closes)
  "FD = ln(N) / (ln(N) + ln(max_dist/path_len)). Returns None if degenerate."
  (let ((n (len closes))
        (path-len (fold + 0.0
                    (map (lambda (i) (sqrt (+ (* (- (nth closes i) (nth closes (- i 1)))
                                                 (- (nth closes i) (nth closes (- i 1))))
                                              1.0)))
                         (range 1 n))))
        (max-dist (fold max 0.0
                    (map (lambda (c) (abs (- c (first closes)))) closes))))
    (when (and (> path-len 1e-10) (> max-dist 1e-10))
      (clamp (/ (ln n) (+ (ln n) (ln (/ max-dist path-len)))) 1.0 2.0))))

;; ── Entropy Rate ───────────────────────────────────────────────

(define (entropy-rate returns)
  "Bigram conditional entropy of return classes (up/flat/down).
   Normalized by ln(3). Returns None if < 20 returns."
  (when (>= (len returns) 20)
    (let ((classes (map (lambda (r)
                          (cond ((> r 0.0001) 2)
                                ((< r -0.0001) 0)
                                (else 1)))
                        returns)))
      ;; rune:scry(aspirational) — bigram transition matrix accumulation
      ;; Build 3x3 transition count matrix, compute conditional entropy.
      None)))

;; ── Gutenberg-Richter b-value ──────────────────────────────────

(define (gr-bvalue returns)
  "Seismology: frequency-magnitude relationship. b < 1 = heavy tails.
   Returns None if < 20 returns or insufficient thresholds."
  (when (>= (len returns) 20)
    (let ((abs-returns (sort (map abs returns)))
          (nr (len abs-returns))
          (thresholds (map (lambda (i) (nth abs-returns (/ (* nr i) 5)))
                           (range 1 5))))
      ;; Log-log regression of exceedance count vs threshold
      (let ((points (filter-map
                      (lambda (t)
                        (when (> t 1e-10)
                          (let ((count (len (filter (lambda (r) (>= r t)) abs-returns))))
                            (when (> count 0)
                              (list (ln t) (ln count))))))
                      thresholds)))
        (when (>= (len points) 3)
          (let ((log-m (map first points))
                (log-n (map second points)))
            (when-let ((slope (linreg-slope log-m log-n)))
              (- slope))))))))

;; ── Facts produced ─────────────────────────────────────────────

(define (eval-regime candles)
  "Market regime facts. Minimum 20 candles."
  (when (>= (len candles) 20)
    (let ((n       (len candles))
          (now     (last candles))
          (closes  (map :close candles))
          (returns (log-returns closes)))
      (append
        ;; KAMA Efficiency Ratio
        (let ((er (kama-er closes)))
          (list (fact/zone "kama-er"
                  (cond ((> er 0.6) "efficient-trend")
                        ((< er 0.3) "inefficient-chop")
                        (else       "moderate-efficiency")))))

        ;; Choppiness Index
        (let ((chop (choppiness-index candles)))
          (list (fact/zone "chop"
                  (cond ((< chop 38.2) "chop-trending")
                        ((> chop 75.0) "chop-extreme")
                        ((> chop 61.8) "chop-choppy")
                        (else          "chop-transition")))))

        ;; DFA Alpha
        (when-let ((alpha (dfa-alpha returns)))
          (list (fact/zone "dfa-alpha"
                  (cond ((> alpha 0.6) "persistent-dfa")
                        ((< alpha 0.4) "anti-persistent-dfa")
                        (else          "random-walk-dfa")))))

        ;; Variance Ratio (k=5)
        (when-let ((vr (variance-ratio returns 5)))
          (list (fact/zone "variance-ratio"
                  (cond ((> vr 1.3) "vr-momentum")
                        ((< vr 0.7) "vr-mean-revert")
                        (else       "vr-neutral")))))

        ;; DeMark TD Sequential
        (if (>= n 5)
            (let ((count (td-count closes)))
              (list (fact/zone "td-count"
                      (cond ((>= (abs count) 9) "td-exhausted")
                            ((>= (abs count) 7) "td-mature")
                            ((>= (abs count) 4) "td-building")
                            (else               "td-inactive")))))
            (list))

        ;; Aroon (25-period)
        (when-let ((ar (aroon candles (min 25 (- n 1)))))
          (let ((aroon-up   (first ar))
                (aroon-down (second ar)))
            (list (fact/zone "aroon-up"
                    (cond ((and (> aroon-up 80) (< aroon-down 30)) "aroon-strong-up")
                          ((and (> aroon-down 80) (< aroon-up 30)) "aroon-strong-down")
                          ((and (< aroon-up 20) (< aroon-down 20)) "aroon-stale")
                          (else                                     "aroon-consolidating"))))))

        ;; Fractal Dimension (Katz)
        (when-let ((fd (fractal-dimension closes)))
          (list (fact/zone "fractal-dim"
                  (cond ((< fd 1.3) "trending-geometry")
                        ((> fd 1.7) "mean-reverting-geometry")
                        (else       "random-walk-geometry")))))

        ;; Entropy Rate
        (when-let ((h-norm (entropy-rate returns)))
          (list (fact/zone "entropy-rate"
                  (cond ((< h-norm 0.7) "low-entropy-rate")
                        (else           "high-entropy-rate")))))

        ;; Gutenberg-Richter b-value
        (when-let ((b (gr-bvalue returns)))
          (list (fact/zone "gr-bvalue"
                  (cond ((< b 1.0) "heavy-tails")
                        (else      "light-tails")))))

        ;; ── Pre-computed scalars from Candle ──────────────────

        ;; Trend consistency at multiple scales
        (list (fact/scalar "trend-consistency-6"  (:trend-consistency-6 now)  1.0)
              (fact/scalar "trend-consistency-12" (:trend-consistency-12 now) 1.0)
              (fact/scalar "trend-consistency-24" (:trend-consistency-24 now) 1.0))

        ;; Trend agreement across scales
        (cond
          ((and (> (:trend-consistency-6 now) 0.8) (> (:trend-consistency-12 now) 0.7))
           (list (fact/zone "trend" "trend-strong")))
          ((and (< (:trend-consistency-6 now) 0.35) (< (:trend-consistency-12 now) 0.4))
           (list (fact/zone "trend" "trend-choppy")))
          (else (list)))

        ;; Volatility acceleration — ATR rate of change
        (list (fact/scalar "atr-roc-6"
                (+ (* (clamp (:atr-roc-6 now) -1.0 1.0) 0.5) 0.5)  1.0)
              (fact/scalar "atr-roc-12"
                (+ (* (clamp (:atr-roc-12 now) -1.0 1.0) 0.5) 0.5) 1.0))

        (cond
          ((> (:atr-roc-6 now) 0.2)   (list (fact/zone "volatility" "vol-expanding")))
          ((< (:atr-roc-6 now) -0.15)  (list (fact/zone "volatility" "vol-contracting")))
          (else (list)))

        ;; Range position at multiple scales
        (list (fact/scalar "range-pos-12" (:range-pos-12 now) 1.0)
              (fact/scalar "range-pos-24" (:range-pos-24 now) 1.0)
              (fact/scalar "range-pos-48" (:range-pos-48 now) 1.0))))))

;; ── Magic numbers (honest accounting) ──────────────────────────
;;
;; KAMA ER: 0.6/0.3           — empirical, no theoretical basis
;; Choppiness: 38.2/61.8/75   — Fibonacci-derived tradition
;; DFA alpha: 0.6/0.4         — modest separation from 0.5
;; Variance ratio: 1.3/0.7    — empirical
;; TD Sequential: 9/7/4       — DeMark's standard levels
;; Aroon: 80/30/20            — standard Aroon interpretation
;; Fractal dim: 1.3/1.7       — geometric intuition
;; Entropy: 0.7               — empirical
;; GR b-value: 1.0            — theoretical (power law boundary)
;; Trend consistency: 0.8/0.7/0.35/0.4 — empirical
;; ATR-ROC: 0.2/-0.15         — empirical, asymmetric
;; Return class: 0.01%        — machine epsilon for crypto returns

;; ── What regime does NOT do ────────────────────────────────────
;; - Does NOT predict direction (it measures character)
;; - Does NOT compute Hurst or autocorrelation (that's persistence.wat)
;; - The fattest module. Eight independent measurements.
;; - Pure function. Candles in, facts out.
