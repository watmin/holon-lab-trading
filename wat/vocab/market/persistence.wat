;; persistence.wat — Hurst, autocorrelation, ADX
;;
;; Depends on: candle
;; Domain: market (MarketLens :regime)
;;
;; Properties of the price series. Not direction — character.
;; "Is this market trending or mean-reverting? Persistent or random?"

(require primitives)
(require candle)

;; Hurst exponent — H > 0.5: persistent (trends continue).
;; H < 0.5: anti-persistent (mean-reverting). H = 0.5: random walk.
;; Range [0, 1]. Linear-encoded with scale 1.0.
;;
;; Lag-1 autocorrelation — positive: momentum. Negative: mean-reversion.
;; Range [-1, 1]. Linear-encoded with scale 1.0. Signed.
;;
;; ADX — pre-computed on Candle. Range [0, 100].
;; Normalized to [0, 1]. Measures trend strength, not direction.

(define (encode-persistence-facts [candle : Candle]
                                  [candles : Vec<Candle>])
  : Vec<ThoughtAST>
  (let* ((facts (list
                  ;; ADX — normalized to [0, 1]
                  (Linear "adx" (/ (:adx candle) 100.0) 1.0)))

         ;; Hurst exponent — window-dependent
         (h (hurst-estimate candles (min (len candles) 100)))
         (facts (if h
                  (append facts (list (Linear "hurst" (clamp h 0.0 1.0) 1.0)))
                  facts))

         ;; Lag-1 autocorrelation — window-dependent
         (ac (autocorrelation-lag1 candles (min (len candles) 50)))
         (facts (if ac
                  (append facts (list (Linear "autocorr" ac 1.0)))
                  facts)))

    facts))

;; Hurst exponent via rescaled range (R/S).
;; H = log(R/S) / log(N). Returns None if insufficient data.
(define (hurst-estimate [candles : Vec<Candle>]
                        [lookback : usize])
  : Option<f64>
  (if (or (< (len candles) lookback) (< lookback 10))
    None
    (let* ((window  (last-n candles lookback))
           (returns (map (lambda (i)
                      (ln (/ (:close (nth window i))
                             (:close (nth window (- i 1))))))
                    (range 1 (len window))))
           (n    (length returns))
           (mean (/ (fold-left + 0.0 returns) n))
           (std  (sqrt (/ (fold-left + 0.0
                            (map (lambda (r) (* (- r mean) (- r mean))) returns))
                          n))))
      (if (< std 1e-15)
        None
        (let* ((cum-devs (fold-left
                           (lambda (acc r)
                             (let ((new-cum (+ (last acc) (- r mean))))
                               (append acc (list new-cum))))
                           (list 0.0) returns))
               (max-cum (fold-left max -1e308 cum-devs))
               (min-cum (fold-left min  1e308 cum-devs))
               (rs      (/ (- max-cum min-cum) std)))
          (if (<= rs 0.0)
            None
            (Some (/ (ln rs) (ln (+ n 0.0))))))))))

;; Lag-1 autocorrelation of returns.
;; Positive = momentum. Negative = mean-reversion.
(define (autocorrelation-lag1 [candles : Vec<Candle>]
                              [lookback : usize])
  : Option<f64>
  (if (or (< (len candles) (+ lookback 1)) (< lookback 5))
    None
    (let* ((window  (last-n candles (+ lookback 1)))
           (returns (map (lambda (i)
                      (/ (- (:close (nth window i))
                            (:close (nth window (- i 1))))
                         (:close (nth window (- i 1)))))
                    (range 1 (len window))))
           (mean    (/ (fold-left + 0.0 returns) (length returns)))
           (var     (fold-left + 0.0
                      (map (lambda (r) (* (- r mean) (- r mean))) returns))))
      (if (< (abs var) 1e-15)
        None
        (let ((cov (fold-left + 0.0
                     (map (lambda (i)
                       (* (- (nth returns i) mean)
                          (- (nth returns (- i 1)) mean)))
                       (range 1 (length returns))))))
          (Some (/ cov var)))))))
