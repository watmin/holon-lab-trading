;; regime.wat — KAMA-ER, choppiness, DFA, variance ratio, entropy, Aroon, fractal dim
;;
;; Depends on: candle
;; Domain: market (MarketLens :regime)
;;
;; Abstract properties of the price series: is it trending or choppy?
;; Persistent or mean-reverting? Orderly or chaotic?
;; These survive window noise better than candle-level patterns.

(require primitives)
(require candle)

;; KAMA Efficiency Ratio — |net move| / sum(|step moves|) over 10 periods.
;; Range [0, 1]. 1.0 = perfectly efficient trend. 0.0 = pure noise.
;;
;; Choppiness Index — 100 * log10(ATR_sum / range) / log10(period).
;; Range ~[0, 100]. Normalized to [0, 1]. High = choppy, low = trending.
;;
;; DFA alpha — detrended fluctuation analysis. Log-log slope.
;; > 0.5: persistent. < 0.5: anti-persistent. = 0.5: random walk.
;; Range [0, 1.5]. Linear-encoded with scale 1.5.
;;
;; Variance ratio — var(k-returns) / (k * var(1-returns)).
;; > 1: momentum. < 1: mean-reversion. Log-encoded because ratio.
;;
;; Entropy rate — bigram conditional entropy of return classes.
;; Normalized by ln(3). Range [0, 1]. Low = predictable.
;;
;; Aroon — up/down indicator. Range [0, 100]. Normalized to [0, 1].
;; Both up and down emitted as separate scalars.
;;
;; Fractal dimension — Katz. Range [1, 2].
;; 1.0 = perfectly linear. 2.0 = space-filling.
;; Linear-encoded with scale 2.0.

(define (encode-regime-facts [candle : Candle]
                             [candles : Vec<Candle>])
  : Vec<ThoughtAST>
  (let* ((n      (len candles))
         (closes (map (lambda (c) (:close c)) candles))
         (facts  (list))

         ;; KAMA Efficiency Ratio
         (er    (kama-er closes))
         (facts (append facts (list (Linear "kama-er" er 1.0))))

         ;; Choppiness Index (14-period)
         (chop  (choppiness-index candles))
         (facts (append facts (list (Linear "choppiness" (/ chop 100.0) 1.0))))

         ;; DFA alpha
         (returns (map (lambda (i)
                    (ln (/ (nth closes i) (nth closes (- i 1)))))
                  (range 1 n)))
         (dfa (dfa-alpha returns))
         (facts (if dfa
                  (append facts (list (Linear "dfa-alpha" (/ dfa 1.5) 1.0)))
                  facts))

         ;; Variance ratio (k=5)
         (vr (variance-ratio returns 5))
         (facts (if vr
                  (append facts (list (Log "variance-ratio" (max vr 0.001))))
                  facts))

         ;; Entropy rate
         (ent (entropy-rate returns))
         (facts (if ent
                  (append facts (list (Linear "entropy-rate" ent 1.0)))
                  facts))

         ;; Aroon (25-period)
         (aroon-period (min 25 (- n 1)))
         (aroon-vals (aroon candles aroon-period))
         (facts (if aroon-vals
                  (let ((au (first aroon-vals))
                        (ad (second aroon-vals)))
                    (append facts
                      (list (Linear "aroon-up" (/ au 100.0) 1.0)
                            (Linear "aroon-down" (/ ad 100.0) 1.0))))
                  facts))

         ;; Fractal dimension (Katz)
         (fd (fractal-dimension closes))
         (facts (if fd
                  (append facts (list (Linear "fractal-dim" (/ fd 2.0) 1.0)))
                  facts))

         ;; Trend consistency — pre-computed on Candle
         (facts (append facts
                  (list (Linear "trend-consistency" (:trend-consistency-24 candle) 1.0))))

         ;; Range position at multiple scales — pre-computed on Candle
         (facts (append facts
                  (list (Linear "range-pos-12" (:range-pos-12 candle) 1.0)
                        (Linear "range-pos-24" (:range-pos-24 candle) 1.0)
                        (Linear "range-pos-48" (:range-pos-48 candle) 1.0)))))

    facts))

;; KAMA Efficiency Ratio: |net_move| / sum(|step_move|) over 10 periods.
(define (kama-er [closes : Vec<f64>])
  : f64
  (let* ((n         (len closes))
         (er-period (min 10 (- n 1)))
         (net-move  (abs (- (nth closes (- n 1))
                            (nth closes (- n 1 er-period)))))
         (step-sum  (fold-left + 0.0
                      (map (lambda (i)
                        (abs (- (nth closes i)
                                (nth closes (- i 1)))))
                        (range (- n er-period) n)))))
    (if (> step-sum 1e-10) (/ net-move step-sum) 0.0)))

;; Choppiness Index: 100 * log10(ATR_sum / range) / log10(period).
(define (choppiness-index [candles : Vec<Candle>])
  : f64
  (let* ((n           (len candles))
         (chop-period (min 14 (- n 1)))
         (slice       (last-n candles chop-period))
         (atr-sum     (fold-left + 0.0
                        (map (lambda (i)
                          (let ((hl (- (:high (nth slice i)) (:low (nth slice i))))
                                (hc (abs (- (:high (nth slice i))
                                            (:close (nth slice (- i 1))))))
                                (lc (abs (- (:low (nth slice i))
                                            (:close (nth slice (- i 1)))))))
                            (max hl (max hc lc))))
                          (range 1 (len slice)))))
         (hi          (fold-left max -1e308 (map (lambda (c) (:high c)) slice)))
         (lo          (fold-left min  1e308 (map (lambda (c) (:low c)) slice)))
         (rng         (- hi lo)))
    (if (> rng 1e-10)
      (* 100.0 (/ (log10 (/ atr-sum rng))
                  (log10 (+ chop-period 0.0))))
      100.0)))

;; DFA alpha — detrended fluctuation analysis.
;; Log-log slope of fluctuation vs scale at scales [4,6,8,12,16].
(define (dfa-alpha [returns : Vec<f64>])
  : Option<f64>
  (if (< (length returns) 16)
    None
    (let* ((ret-mean   (/ (fold-left + 0.0 returns) (length returns)))
           (integrated (fold-left
                         (lambda (acc r)
                           (append acc (list (+ (last acc) (- r ret-mean)))))
                         (list 0.0) returns))
           (scales     (filter (lambda (s) (<= s (length integrated)))
                         (list 4 6 8 12 16))))
      (if (< (length scales) 3)
        None
        (let* ((log-points
                 (filter-map
                   (lambda (s)
                     (let ((f (fluctuation-at-scale integrated s)))
                       (if (> f 1e-10)
                         (Some (list (ln (+ s 0.0)) (ln f)))
                         None)))
                   scales)))
          (if (< (length log-points) 3)
            None
            (let ((log-s (map first log-points))
                  (log-f (map second log-points)))
              (linreg-slope log-s log-f))))))))

;; Fluctuation at a given scale (RMS of detrended segments).
(define (fluctuation-at-scale [integrated : Vec<f64>]
                              [s : usize])
  : f64
  (let* ((num-segs (/ (length integrated) s))
         (f2-sum   (fold-left + 0.0
                     (map (lambda (seg)
                       (let* ((start    (* seg s))
                              (seg-data (take (last-n integrated
                                               (- (length integrated) start)) s))
                              (trend    (linreg-fit (range 0 s) seg-data))
                              (rms      (/ (fold-left + 0.0
                                             (map (lambda (i)
                                               (let ((resid (- (nth seg-data i)
                                                               (nth trend i))))
                                                 (* resid resid)))
                                               (range 0 s)))
                                           (+ s 0.0))))
                         rms))
                       (range 0 num-segs)))))
    (sqrt (/ f2-sum (max num-segs 1)))))

;; Variance ratio: var(k-period returns) / (k * var(1-period returns)).
(define (variance-ratio [returns : Vec<f64>]
                        [k : usize])
  : Option<f64>
  (if (< (length returns) 10)
    None
    (let* ((var1      (/ (fold-left + 0.0
                           (map (lambda (r) (* r r)) returns))
                         (length returns)))
           (k-returns (map (lambda (i)
                        (fold-left + 0.0
                          (take (last-n returns (- (length returns) i)) k)))
                      (range 0 (+ 1 (- (length returns) k)))))
           (var-k     (/ (fold-left + 0.0
                           (map (lambda (r) (* r r)) k-returns))
                         (* (length k-returns) k))))
      (if (<= var1 1e-20)
        None
        (Some (/ var-k var1))))))

;; Aroon up/down. Returns (aroon-up, aroon-down) or None.
(define (aroon [candles : Vec<Candle>]
               [period : usize])
  : Option<(f64 f64)>
  (let ((n (len candles)))
    (if (<= n period)
      None
      (let* ((slice  (last-n candles (+ period 1)))
             (hi-idx (fold-left (lambda (best i)
                       (if (>= (:high (nth slice i)) (:high (nth slice best))) i best))
                     0 (range 0 (+ period 1))))
             (lo-idx (fold-left (lambda (best i)
                       (if (<= (:low (nth slice i)) (:low (nth slice best))) i best))
                     0 (range 0 (+ period 1)))))
        (Some (list (* 100.0 (/ (+ hi-idx 0.0) (+ period 0.0)))
                    (* 100.0 (/ (+ lo-idx 0.0) (+ period 0.0)))))))))

;; Fractal dimension (Katz): ln(N) / (ln(N) + ln(max_dist / path_len)).
(define (fractal-dimension [closes : Vec<f64>])
  : Option<f64>
  (let* ((n        (length closes))
         (path-len (fold-left + 0.0
                     (map (lambda (i)
                       (sqrt (+ (* (- (nth closes i) (nth closes (- i 1)))
                                   (- (nth closes i) (nth closes (- i 1))))
                                1.0)))
                       (range 1 n))))
         (max-dist (fold-left max 0.0
                     (map (lambda (i) (abs (- (nth closes i) (first closes))))
                       (range 1 n)))))
    (if (and (> path-len 1e-10) (> max-dist 1e-10))
      (Some (clamp (/ (ln (+ n 0.0))
                      (+ (ln (+ n 0.0)) (ln (/ max-dist path-len))))
                   1.0 2.0))
      None)))

;; Bigram conditional entropy of return classes (up/flat/down).
;; Normalized by ln(3).
(define (entropy-rate [returns : Vec<f64>])
  : Option<f64>
  (if (< (length returns) 20)
    None
    (let* ((classes (map (lambda (r)
                      (cond ((> r 0.0001)  2)
                            ((< r -0.0001) 0)
                            (true          1)))
                    returns))
           ;; Count bigrams and unigrams
           (counts (fold-left
                     (lambda (acc i)
                       (let ((prev (nth classes (- i 1)))
                             (curr (nth classes i)))
                         (assoc acc
                           (list prev curr)
                           (+ 1 (get acc (list prev curr) 0)))))
                     (map-of) (range 1 (length classes))))
           (unigrams (fold-left
                       (lambda (acc i)
                         (let ((c (nth classes i)))
                           (assoc acc c (+ 1 (get acc c 0)))))
                       (map-of) (range 0 (- (length classes) 1))))
           (total (- (length classes) 1))
           (h-cond (fold-left + 0.0
                     (filter-map
                       (lambda (i)
                         (let ((u (get unigrams i 0)))
                           (if (= u 0) None
                             (let ((p-i (/ (+ u 0.0) total)))
                               (Some (fold-left + 0.0
                                       (filter-map
                                         (lambda (j)
                                           (let ((b (get counts (list i j) 0)))
                                             (if (= b 0) None
                                               (let ((p-j (/ (+ b 0.0) (+ u 0.0))))
                                                 (Some (* -1.0 p-i p-j (ln p-j)))))))
                                         (list 0 1 2))))))))
                       (list 0 1 2)))))
      (Some (/ h-cond (ln 3.0))))))

;; Linear regression slope.
(define (linreg-slope [xs : Vec<f64>]
                      [ys : Vec<f64>])
  : Option<f64>
  (let* ((n   (+ (length xs) 0.0))
         (sx  (fold-left + 0.0 xs))
         (sy  (fold-left + 0.0 ys))
         (sxx (fold-left + 0.0 (map (lambda (x) (* x x)) xs)))
         (sxy (fold-left + 0.0 (map (lambda (i) (* (nth xs i) (nth ys i)))
                                 (range 0 (length xs)))))
         (denom (- (* n sxx) (* sx sx))))
    (if (> (abs denom) 1e-10)
      (Some (/ (- (* n sxy) (* sx sy)) denom))
      None)))

;; Linear regression fit — returns predicted values.
(define (linreg-fit [xs : Vec<usize>]
                    [ys : Vec<f64>])
  : Vec<f64>
  (let* ((xf (map (lambda (x) (+ x 0.0)) xs))
         (slope (linreg-slope xf ys)))
    (if (not slope)
      (map (lambda (_) 0.0) xs)
      (let* ((n    (+ (length xf) 0.0))
             (mean-x (/ (fold-left + 0.0 xf) n))
             (mean-y (/ (fold-left + 0.0 ys) n))
             (intercept (- mean-y (* slope mean-x))))
        (map (lambda (x) (+ intercept (* slope (+ x 0.0)))) xs)))))

;; log10 helper
(define (log10 [x : f64]) : f64
  (/ (ln x) (ln 10.0)))
