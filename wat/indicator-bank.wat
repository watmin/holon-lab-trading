;; indicator-bank.wat — streaming state machine for technical indicators
;; Depends on: raw-candle
;; Advances all indicators by one raw candle. Stateful.
;; One per post (one per asset pair).

(require primitives)
(require raw-candle)
(require candle)

;; ── Streaming primitives ───────────────────────────────────────────

(struct ring-buffer
  [data     : Vec<f64>]
  [capacity : usize]
  [head     : usize]
  [len      : usize])

(define (make-ring-buffer [capacity : usize])
  : RingBuffer
  (ring-buffer (zeros capacity) capacity 0 0))

(define (rb-push [rb : RingBuffer] [value : f64])
  : RingBuffer
  (begin
    (set! (:data rb) (:head rb) value)
    (update rb
      :head (mod (+ (:head rb) 1) (:capacity rb))
      :len (min (+ (:len rb) 1) (:capacity rb)))))

(define (rb-get [rb : RingBuffer] [ago : usize])
  : f64
  ;; Get value from `ago` steps back. 0 = most recent.
  (let ((idx (mod (+ (- (:head rb) 1 ago) (* (:capacity rb) 2)) (:capacity rb))))
    (nth (:data rb) idx)))

(define (rb-full? [rb : RingBuffer])
  : bool
  (= (:len rb) (:capacity rb)))

(define (rb-max [rb : RingBuffer])
  : f64
  (fold (lambda (mx i) (max mx (rb-get rb i)))
        f64-neg-infinity
        (range 0 (:len rb))))

(define (rb-min [rb : RingBuffer])
  : f64
  (fold (lambda (mn i) (min mn (rb-get rb i)))
        f64-infinity
        (range 0 (:len rb))))

(define (rb-sum [rb : RingBuffer])
  : f64
  (fold (lambda (s i) (+ s (rb-get rb i)))
        0.0
        (range 0 (:len rb))))

(define (rb-to-list [rb : RingBuffer])
  : Vec<f64>
  (map (lambda (i) (rb-get rb i)) (reverse (range 0 (:len rb)))))

;; ── EMA state ──────────────────────────────────────────────────────

(struct ema-state
  [value     : f64]
  [smoothing : f64]
  [period    : usize]
  [count     : usize]
  [accum     : f64])

(define (make-ema-state [period : usize])
  : EmaState
  (ema-state 0.0 (/ 2.0 (+ 1.0 (+ 0.0 period))) period 0 0.0))

(define (ema-update [st : EmaState] [value : f64])
  : EmaState
  (let ((new-count (+ (:count st) 1))
        (new-accum (+ (:accum st) value)))
    (if (< new-count (:period st))
      ;; Warming up — accumulate for SMA seed
      (update st :count new-count :accum new-accum)
      (if (= new-count (:period st))
        ;; First valid — use SMA as seed
        (let ((sma (/ new-accum (+ 0.0 (:period st)))))
          (update st :value sma :count new-count :accum new-accum))
        ;; Normal EMA update
        (let ((new-val (+ (* (:smoothing st) value)
                          (* (- 1.0 (:smoothing st)) (:value st)))))
          (update st :value new-val :count new-count))))))

;; ── Wilder state ───────────────────────────────────────────────────

(struct wilder-state
  [value  : f64]
  [period : usize]
  [count  : usize]
  [accum  : f64])

(define (make-wilder-state [period : usize])
  : WilderState
  (wilder-state 0.0 period 0 0.0))

(define (wilder-update [st : WilderState] [value : f64])
  : WilderState
  (let ((new-count (+ (:count st) 1))
        (new-accum (+ (:accum st) value))
        (p (+ 0.0 (:period st))))
    (if (< new-count (:period st))
      (update st :count new-count :accum new-accum)
      (if (= new-count (:period st))
        (let ((avg (/ new-accum p)))
          (update st :value avg :count new-count :accum new-accum))
        (let ((new-val (+ (/ value p)
                          (* (/ (- p 1.0) p) (:value st)))))
          (update st :value new-val :count new-count))))))

;; ── RSI state ──────────────────────────────────────────────────────

(struct rsi-state
  [gain-smoother : WilderState]
  [loss-smoother : WilderState]
  [prev-close    : f64]
  [started       : bool])

(define (make-rsi-state)
  : RsiState
  (rsi-state (make-wilder-state 14) (make-wilder-state 14) 0.0 false))

(define (rsi-update [st : RsiState] [close : f64])
  : RsiState
  (if (not (:started st))
    (update st :prev-close close :started true)
    (let ((change (- close (:prev-close st)))
          (gain (if (> change 0.0) change 0.0))
          (loss (if (< change 0.0) (abs change) 0.0)))
      (update st
        :gain-smoother (wilder-update (:gain-smoother st) gain)
        :loss-smoother (wilder-update (:loss-smoother st) loss)
        :prev-close close))))

(define (rsi-value [st : RsiState])
  : f64
  (let ((avg-gain (:value (:gain-smoother st)))
        (avg-loss (:value (:loss-smoother st))))
    (if (= avg-loss 0.0)
      (if (= avg-gain 0.0) 50.0 100.0)
      (let ((rs (/ avg-gain avg-loss)))
        (- 100.0 (/ 100.0 (+ 1.0 rs)))))))

;; ── ATR state ──────────────────────────────────────────────────────

(struct atr-state
  [wilder     : WilderState]
  [prev-close : f64]
  [started    : bool])

(define (make-atr-state)
  : AtrState
  (atr-state (make-wilder-state 14) 0.0 false))

(define (atr-update [st : AtrState] [high : f64] [low : f64] [close : f64])
  : AtrState
  (if (not (:started st))
    (update st :prev-close close :started true
      :wilder (wilder-update (:wilder st) (- high low)))
    (let ((tr (max (- high low)
                   (max (abs (- high (:prev-close st)))
                        (abs (- low (:prev-close st)))))))
      (update st
        :wilder (wilder-update (:wilder st) tr)
        :prev-close close))))

;; ── OBV state ──────────────────────────────────────────────────────

(struct obv-state
  [obv        : f64]
  [prev-close : f64]
  [history    : RingBuffer]
  [started    : bool])

(define (make-obv-state)
  : ObvState
  (obv-state 0.0 0.0 (make-ring-buffer 12) false))

(define (obv-update [st : ObvState] [close : f64] [volume : f64])
  : ObvState
  (if (not (:started st))
    (update st :prev-close close :started true
      :history (rb-push (:history st) 0.0))
    (let ((new-obv (cond
                     ((> close (:prev-close st)) (+ (:obv st) volume))
                     ((< close (:prev-close st)) (- (:obv st) volume))
                     (else (:obv st)))))
      (update st
        :obv new-obv
        :prev-close close
        :history (rb-push (:history st) new-obv)))))

;; ── SMA state ──────────────────────────────────────────────────────

(struct sma-state
  [buffer : RingBuffer]
  [sum    : f64])

(define (make-sma-state [period : usize])
  : SmaState
  (sma-state (make-ring-buffer period) 0.0))

(define (sma-update [st : SmaState] [value : f64])
  : SmaState
  (let ((old-val (if (rb-full? (:buffer st))
                   (rb-get (:buffer st) (- (:capacity (:buffer st)) 1))
                   0.0))
        (new-sum (+ (- (:sum st) old-val) value)))
    (update st
      :buffer (rb-push (:buffer st) value)
      :sum new-sum)))

(define (sma-value [st : SmaState])
  : f64
  (if (= (:len (:buffer st)) 0)
    0.0
    (/ (:sum st) (+ 0.0 (:len (:buffer st))))))

;; ── Rolling stddev ─────────────────────────────────────────────────

(struct rolling-stddev
  [buffer : RingBuffer]
  [sum    : f64]
  [sum-sq : f64])

(define (make-rolling-stddev [period : usize])
  : RollingStddev
  (rolling-stddev (make-ring-buffer period) 0.0 0.0))

(define (stddev-update [st : RollingStddev] [value : f64])
  : RollingStddev
  (let ((old-val (if (rb-full? (:buffer st))
                   (rb-get (:buffer st) (- (:capacity (:buffer st)) 1))
                   0.0))
        (new-sum (+ (- (:sum st) old-val) value))
        (new-sum-sq (+ (- (:sum-sq st) (* old-val old-val)) (* value value))))
    (update st
      :buffer (rb-push (:buffer st) value)
      :sum new-sum
      :sum-sq new-sum-sq)))

(define (stddev-value [st : RollingStddev])
  : f64
  (let ((n (+ 0.0 (:len (:buffer st)))))
    (if (< n 2.0) 0.0
      (let ((mean (/ (:sum st) n))
            (var (- (/ (:sum-sq st) n) (* mean mean))))
        (sqrt (max 0.0 var))))))

;; ── Stochastic state ───────────────────────────────────────────────

(struct stoch-state
  [high-buf : RingBuffer]
  [low-buf  : RingBuffer]
  [k-buf    : RingBuffer])

(define (make-stoch-state)
  : StochState
  (stoch-state (make-ring-buffer 14) (make-ring-buffer 14) (make-ring-buffer 3)))

(define (stoch-update [st : StochState] [high : f64] [low : f64] [close : f64])
  : StochState
  (let ((new-high-buf (rb-push (:high-buf st) high))
        (new-low-buf (rb-push (:low-buf st) low))
        (highest (rb-max new-high-buf))
        (lowest (rb-min new-low-buf))
        (k-raw (if (= highest lowest) 50.0
                 (* 100.0 (/ (- close lowest) (- highest lowest)))))
        (new-k-buf (rb-push (:k-buf st) k-raw)))
    (stoch-state new-high-buf new-low-buf new-k-buf)))

;; ── CCI state ──────────────────────────────────────────────────────

(struct cci-state
  [tp-buf : RingBuffer]
  [tp-sma : SmaState])

(define (make-cci-state)
  : CciState
  (cci-state (make-ring-buffer 20) (make-sma-state 20)))

(define (cci-update [st : CciState] [high : f64] [low : f64] [close : f64])
  : CciState
  (let ((tp (/ (+ high low close) 3.0)))
    (update st
      :tp-buf (rb-push (:tp-buf st) tp)
      :tp-sma (sma-update (:tp-sma st) tp))))

(define (cci-value [st : CciState])
  : f64
  (let ((tp-mean (sma-value (:tp-sma st)))
        (buf (:tp-buf st))
        (n (:len buf))
        (mean-dev (if (= n 0) 0.0
                    (/ (fold (lambda (s i) (+ s (abs (- (rb-get buf i) tp-mean))))
                             0.0 (range 0 n))
                       (+ 0.0 n)))))
    (if (= mean-dev 0.0) 0.0
      (/ (- (rb-get buf 0) tp-mean) (* 0.015 mean-dev)))))

;; ── MFI state ──────────────────────────────────────────────────────

(struct mfi-state
  [pos-flow-buf : RingBuffer]
  [neg-flow-buf : RingBuffer]
  [prev-tp      : f64]
  [started      : bool])

(define (make-mfi-state)
  : MfiState
  (mfi-state (make-ring-buffer 14) (make-ring-buffer 14) 0.0 false))

(define (mfi-update [st : MfiState] [high : f64] [low : f64] [close : f64] [volume : f64])
  : MfiState
  (let ((tp (/ (+ high low close) 3.0))
        (money-flow (* tp volume)))
    (if (not (:started st))
      (update st :prev-tp tp :started true
        :pos-flow-buf (rb-push (:pos-flow-buf st) 0.0)
        :neg-flow-buf (rb-push (:neg-flow-buf st) 0.0))
      (if (> tp (:prev-tp st))
        (update st :prev-tp tp
          :pos-flow-buf (rb-push (:pos-flow-buf st) money-flow)
          :neg-flow-buf (rb-push (:neg-flow-buf st) 0.0))
        (update st :prev-tp tp
          :pos-flow-buf (rb-push (:pos-flow-buf st) 0.0)
          :neg-flow-buf (rb-push (:neg-flow-buf st) money-flow))))))

(define (mfi-value [st : MfiState])
  : f64
  (let ((pos-sum (rb-sum (:pos-flow-buf st)))
        (neg-sum (rb-sum (:neg-flow-buf st))))
    (if (= neg-sum 0.0) 100.0
      (let ((ratio (/ pos-sum neg-sum)))
        (- 100.0 (/ 100.0 (+ 1.0 ratio)))))))

;; ── Ichimoku state ─────────────────────────────────────────────────

(struct ichimoku-state
  [high-9  : RingBuffer]  [low-9  : RingBuffer]
  [high-26 : RingBuffer]  [low-26 : RingBuffer]
  [high-52 : RingBuffer]  [low-52 : RingBuffer])

(define (make-ichimoku-state)
  : IchimokuState
  (ichimoku-state
    (make-ring-buffer 9)  (make-ring-buffer 9)
    (make-ring-buffer 26) (make-ring-buffer 26)
    (make-ring-buffer 52) (make-ring-buffer 52)))

(define (ichimoku-update [st : IchimokuState] [high : f64] [low : f64])
  : IchimokuState
  (update st
    :high-9  (rb-push (:high-9 st) high)   :low-9  (rb-push (:low-9 st) low)
    :high-26 (rb-push (:high-26 st) high)  :low-26 (rb-push (:low-26 st) low)
    :high-52 (rb-push (:high-52 st) high)  :low-52 (rb-push (:low-52 st) low)))

;; ── MACD state ─────────────────────────────────────────────────────

(struct macd-state
  [fast-ema   : EmaState]
  [slow-ema   : EmaState]
  [signal-ema : EmaState])

(define (make-macd-state)
  : MacdState
  (macd-state (make-ema-state 12) (make-ema-state 26) (make-ema-state 9)))

(define (macd-update [st : MacdState] [close : f64])
  : MacdState
  (let ((new-fast (ema-update (:fast-ema st) close))
        (new-slow (ema-update (:slow-ema st) close))
        (macd-line (- (:value new-fast) (:value new-slow)))
        (new-signal (ema-update (:signal-ema st) macd-line)))
    (macd-state new-fast new-slow new-signal)))

;; ── DMI state ──────────────────────────────────────────────────────

(struct dmi-state
  [plus-smoother  : WilderState]
  [minus-smoother : WilderState]
  [tr-smoother    : WilderState]
  [adx-smoother   : WilderState]
  [prev-high      : f64]
  [prev-low       : f64]
  [prev-close     : f64]
  [started        : bool]
  [count          : usize])

(define (make-dmi-state)
  : DmiState
  (dmi-state
    (make-wilder-state 14) (make-wilder-state 14)
    (make-wilder-state 14) (make-wilder-state 14)
    0.0 0.0 0.0 false 0))

(define (dmi-update [st : DmiState] [high : f64] [low : f64] [close : f64])
  : DmiState
  (if (not (:started st))
    (update st :prev-high high :prev-low low :prev-close close :started true :count 1)
    (let ((up-move (- high (:prev-high st)))
          (down-move (- (:prev-low st) low))
          (plus-dm (if (and (> up-move down-move) (> up-move 0.0)) up-move 0.0))
          (minus-dm (if (and (> down-move up-move) (> down-move 0.0)) down-move 0.0))
          (tr (max (- high low)
                   (max (abs (- high (:prev-close st)))
                        (abs (- low (:prev-close st))))))
          (new-plus (wilder-update (:plus-smoother st) plus-dm))
          (new-minus (wilder-update (:minus-smoother st) minus-dm))
          (new-tr (wilder-update (:tr-smoother st) tr))
          (atr-val (:value new-tr))
          (plus-di (if (= atr-val 0.0) 0.0 (* 100.0 (/ (:value new-plus) atr-val))))
          (minus-di (if (= atr-val 0.0) 0.0 (* 100.0 (/ (:value new-minus) atr-val))))
          (di-sum (+ plus-di minus-di))
          (dx (if (= di-sum 0.0) 0.0 (* 100.0 (/ (abs (- plus-di minus-di)) di-sum))))
          (new-adx (wilder-update (:adx-smoother st) dx)))
      (update st
        :plus-smoother new-plus :minus-smoother new-minus
        :tr-smoother new-tr :adx-smoother new-adx
        :prev-high high :prev-low low :prev-close close
        :count (+ (:count st) 1)))))

;; ── Linear regression slope ────────────────────────────────────────

(define (linreg-slope [buf : RingBuffer])
  : f64
  (let ((n (:len buf)))
    (if (< n 2) 0.0
      (let ((nf (+ 0.0 n))
            (sum-x (/ (* nf (- nf 1.0)) 2.0))
            (sum-x2 (/ (* nf (- nf 1.0) (- (* 2.0 nf) 1.0)) 6.0))
            (pairs (map (lambda (i) (list (+ 0.0 i) (rb-get buf (- n 1 i)))) (range 0 n)))
            (sum-y (fold (lambda (s p) (+ s (second p))) 0.0 pairs))
            (sum-xy (fold (lambda (s p) (+ s (* (first p) (second p)))) 0.0 pairs))
            (denom (- (* nf sum-x2) (* sum-x sum-x))))
        (if (= denom 0.0) 0.0
          (/ (- (* nf sum-xy) (* sum-x sum-y)) denom))))))

;; ── OBV step (above linreg-slope) ─────────────────────────────────

(define (obv-slope-12 [st : ObvState])
  : f64
  (linreg-slope (:history st)))

;; ── Hurst exponent (R/S analysis) ──────────────────────────────────

(define (hurst-exponent [buf : RingBuffer])
  : f64
  (let ((n (:len buf)))
    (if (< n 8) 0.5
      (let ((values (rb-to-list buf))
            (m (/ (fold + 0.0 values) (+ 0.0 n)))
            (deviations (map (lambda (v) (- v m)) values))
            (cum-dev (fold-left (lambda (acc d)
                       (append acc (list (+ (if (empty? acc) 0.0 (last acc)) d))))
                     '() deviations))
            (r (- (fold max f64-neg-infinity cum-dev)
                  (fold min f64-infinity cum-dev)))
            (s (sqrt (/ (fold (lambda (s d) (+ s (* d d))) 0.0 deviations) (+ 0.0 n)))))
        (if (= s 0.0) 0.5
          (/ (ln (/ r s)) (ln (+ 0.0 n))))))))

;; ── Autocorrelation (lag-1) ────────────────────────────────────────

(define (autocorrelation-lag1 [buf : RingBuffer])
  : f64
  (let ((n (:len buf)))
    (if (< n 3) 0.0
      (let ((values (rb-to-list buf))
            (m (/ (fold + 0.0 values) (+ 0.0 n)))
            (var (/ (fold (lambda (s v) (+ s (* (- v m) (- v m)))) 0.0 values) (+ 0.0 n))))
        (if (= var 0.0) 0.0
          (let ((cov (fold (lambda (s i)
                      (+ s (* (- (nth values i) m) (- (nth values (+ i 1)) m))))
                    0.0 (range 0 (- n 1)))))
            (/ (/ cov (+ 0.0 (- n 1))) var)))))))

;; ── DFA alpha ──────────────────────────────────────────────────────

(define (dfa-alpha [buf : RingBuffer])
  : f64
  (let ((n (:len buf)))
    (if (< n 16) 0.5
      ;; Simplified: use R/S as proxy for DFA exponent
      (hurst-exponent buf))))

;; ── Variance ratio ─────────────────────────────────────────────────

(define (variance-ratio [buf : RingBuffer])
  : f64
  (let ((n (:len buf)))
    (if (< n 4) 1.0
      (let ((values (rb-to-list buf))
            (returns-1 (map (lambda (i) (- (nth values (+ i 1)) (nth values i)))
                            (range 0 (- n 1))))
            (var-1 (variance returns-1))
            ;; Scale 2 returns
            (returns-2 (filter-map (lambda (i)
                         (if (< (+ i 2) n)
                           (Some (- (nth values (+ i 2)) (nth values i)))
                           None))
                         (range 0 (- n 2))))
            (var-2 (variance returns-2)))
        (if (= var-1 0.0) 1.0
          (/ var-2 (* 2.0 var-1)))))))

;; ── Entropy rate ───────────────────────────────────────────────────

(define (entropy-rate [buf : RingBuffer])
  : f64
  (let ((n (:len buf)))
    (if (< n 4) 0.0
      (let ((values (rb-to-list buf))
            ;; Discretize returns into bins: negative, zero, positive
            (returns (map (lambda (i)
                      (let ((r (- (nth values (+ i 1)) (nth values i))))
                        (cond ((> r 0.0) 1)
                              ((< r 0.0) -1)
                              (else 0))))
                    (range 0 (- n 1))))
            (total (+ 0.0 (length returns)))
            ;; Count transitions for conditional entropy
            (pos-count (+ 0.0 (count (lambda (r) (= r 1)) returns)))
            (neg-count (+ 0.0 (count (lambda (r) (= r -1)) returns)))
            (zero-count (+ 0.0 (count (lambda (r) (= r 0)) returns)))
            (p-pos (/ pos-count total))
            (p-neg (/ neg-count total))
            (p-zero (/ zero-count total)))
        ;; Shannon entropy
        (let ((h (lambda (p) (if (= p 0.0) 0.0 (* (- 0.0 p) (ln p))))))
          (+ (h p-pos) (h p-neg) (h p-zero)))))))

;; ── Fractal dimension ──────────────────────────────────────────────

(define (fractal-dimension [buf : RingBuffer])
  : f64
  (let ((n (:len buf)))
    (if (< n 4) 1.5
      ;; Higuchi method simplified
      (let ((values (rb-to-list buf))
            ;; k=1: sum of |x[i+1] - x[i]|
            (l1 (/ (fold (lambda (s i)
                    (+ s (abs (- (nth values (+ i 1)) (nth values i)))))
                  0.0 (range 0 (- n 1)))
                 (+ 0.0 (- n 1))))
            ;; k=2: sum of |x[i+2] - x[i]|
            (l2 (/ (fold (lambda (s i)
                    (+ s (abs (- (nth values (+ i 2)) (nth values i)))))
                  0.0 (range 0 (- n 2)))
                 (+ 0.0 (- n 2)))))
        (if (or (= l1 0.0) (= l2 0.0)) 1.5
          (+ 1.0 (/ (ln (/ l1 l2)) (ln 2.0))))))))

;; ── KAMA Efficiency Ratio ──────────────────────────────────────────

(define (kama-efficiency-ratio [buf : RingBuffer])
  : f64
  (let ((n (:len buf)))
    (if (< n 2) 0.0
      (let ((values (rb-to-list buf))
            (direction (abs (- (last values) (first values))))
            (volatility (fold (lambda (s i)
                         (+ s (abs (- (nth values (+ i 1)) (nth values i)))))
                       0.0 (range 0 (- n 1)))))
        (if (= volatility 0.0) 0.0
          (/ direction volatility))))))

;; ── Choppiness Index ───────────────────────────────────────────────

(define (choppiness-index [atr-sum : f64] [high-buf : RingBuffer] [low-buf : RingBuffer])
  : f64
  (let ((highest (rb-max high-buf))
        (lowest (rb-min low-buf))
        (range-val (- highest lowest))
        (period (+ 0.0 (:len high-buf))))
    (if (or (= range-val 0.0) (= period 0.0)) 50.0
      (* 100.0 (/ (ln (/ atr-sum range-val)) (ln period))))))

;; ── Aroon ──────────────────────────────────────────────────────────

(define (aroon-up [buf : RingBuffer])
  : f64
  (let ((n (:len buf)))
    (if (= n 0) 50.0
      (let ((max-idx (fold (lambda (best i)
                       (if (>= (rb-get buf i) (rb-get buf best)) i best))
                     0 (range 0 n))))
        (* 100.0 (/ (+ 0.0 (- n 1 max-idx)) (+ 0.0 (- n 1))))))))

(define (aroon-down [buf : RingBuffer])
  : f64
  (let ((n (:len buf)))
    (if (= n 0) 50.0
      (let ((min-idx (fold (lambda (best i)
                       (if (<= (rb-get buf i) (rb-get buf best)) i best))
                     0 (range 0 n))))
        (* 100.0 (/ (+ 0.0 (- n 1 min-idx)) (+ 0.0 (- n 1))))))))

;; ── Time parsing ───────────────────────────────────────────────────

(define (parse-minute [ts : String]) : f64
  ;; ts format: "YYYY-MM-DDTHH:MM:SS"
  ;; minute is chars 14-15
  (+ 0.0 (parse-int (substring ts 14 16))))

(define (parse-hour [ts : String]) : f64
  (+ 0.0 (parse-int (substring ts 11 13))))

(define (parse-day-of-week [ts : String]) : f64
  ;; Zeller's congruence simplified — returns 0-6
  (let ((y (parse-int (substring ts 0 4)))
        (m (parse-int (substring ts 5 7)))
        (d (parse-int (substring ts 8 10))))
    (+ 0.0 (mod (+ d (round (- (* 2.6 (+ (mod (- m 3) 12) 1)) 0.2))
                    (mod y 100) (round (/ (mod y 100) 4))
                    (round (/ (round (/ y 100)) 4))
                    (* -2 (round (/ y 100))))
                7))))

(define (parse-day-of-month [ts : String]) : f64
  (+ 0.0 (parse-int (substring ts 8 10))))

(define (parse-month-of-year [ts : String]) : f64
  (+ 0.0 (parse-int (substring ts 5 7))))

;; ── Divergence detection (PELT peaks) ──────────────────────────────

(define (detect-divergence [price-buf : RingBuffer] [rsi-buf : RingBuffer])
  : (f64 f64)
  ;; Returns (bull-divergence-magnitude, bear-divergence-magnitude)
  (let ((n (min (:len price-buf) (:len rsi-buf))))
    (if (< n 4) (list 0.0 0.0)
      (let ((prices (map (lambda (i) (rb-get price-buf i)) (range 0 n)))
            (rsis (map (lambda (i) (rb-get rsi-buf i)) (range 0 n)))
            ;; Recent vs older: compare first half to second half peaks
            (mid (round (/ n 2)))
            (recent-price-low (fold min f64-infinity (take prices mid)))
            (older-price-low (fold min f64-infinity (last-n prices (- n mid))))
            (recent-rsi-low (fold min f64-infinity (take rsis mid)))
            (older-rsi-low (fold min f64-infinity (last-n rsis (- n mid))))
            (recent-price-high (fold max f64-neg-infinity (take prices mid)))
            (older-price-high (fold max f64-neg-infinity (last-n prices (- n mid))))
            (recent-rsi-high (fold max f64-neg-infinity (take rsis mid)))
            (older-rsi-high (fold max f64-neg-infinity (last-n rsis (- n mid))))
            ;; Bull: price lower low, RSI higher low
            (bull (if (and (< recent-price-low older-price-low)
                          (> recent-rsi-low older-rsi-low))
                    (abs (- recent-rsi-low older-rsi-low))
                    0.0))
            ;; Bear: price higher high, RSI lower high
            (bear (if (and (> recent-price-high older-price-high)
                          (< recent-rsi-high older-rsi-high))
                    (abs (- older-rsi-high recent-rsi-high))
                    0.0)))
        (list bull bear)))))

;; ── The IndicatorBank ──────────────────────────────────────────────

(struct indicator-bank
  ;; Moving averages
  [sma20  : SmaState] [sma50  : SmaState] [sma200 : SmaState]
  [ema20  : EmaState]
  ;; Bollinger
  [bb-stddev : RollingStddev]
  ;; Oscillators
  [rsi  : RsiState] [macd : MacdState] [dmi  : DmiState] [atr  : AtrState]
  [stoch : StochState] [cci  : CciState] [mfi  : MfiState] [obv  : ObvState]
  [volume-sma20 : SmaState]
  ;; ROC
  [roc-buf : RingBuffer]
  ;; Range position
  [range-high-12 : RingBuffer] [range-low-12 : RingBuffer]
  [range-high-24 : RingBuffer] [range-low-24 : RingBuffer]
  [range-high-48 : RingBuffer] [range-low-48 : RingBuffer]
  ;; Trend consistency
  [trend-buf-24 : RingBuffer]
  ;; ATR history
  [atr-history : RingBuffer]
  ;; Multi-timeframe
  [tf-1h-buf : RingBuffer] [tf-1h-high : RingBuffer] [tf-1h-low : RingBuffer]
  [tf-4h-buf : RingBuffer] [tf-4h-high : RingBuffer] [tf-4h-low : RingBuffer]
  ;; Ichimoku
  [ichimoku : IchimokuState]
  ;; Persistence
  [close-buf-48 : RingBuffer]
  ;; VWAP
  [vwap-cum-vol : f64] [vwap-cum-pv  : f64]
  ;; Regime
  [kama-er-buf : RingBuffer]
  [chop-atr-sum : f64] [chop-buf : RingBuffer]
  [dfa-buf : RingBuffer] [var-ratio-buf : RingBuffer]
  [entropy-buf : RingBuffer]
  [aroon-high-buf : RingBuffer] [aroon-low-buf : RingBuffer]
  [fractal-buf : RingBuffer]
  ;; Divergence
  [rsi-peak-buf : RingBuffer] [price-peak-buf : RingBuffer]
  ;; Cross deltas
  [prev-tk-spread : f64] [prev-stoch-kd : f64]
  ;; Price action
  [prev-range : f64]
  [consecutive-up-count : usize] [consecutive-down-count : usize]
  ;; Timeframe agreement
  [prev-tf-1h-ret : f64] [prev-tf-4h-ret : f64]
  ;; Previous values
  [prev-close : f64]
  ;; Counter
  [count : usize])

(define (make-indicator-bank)
  : IndicatorBank
  (indicator-bank
    (make-sma-state 20) (make-sma-state 50) (make-sma-state 200)
    (make-ema-state 20)
    (make-rolling-stddev 20)
    (make-rsi-state) (make-macd-state) (make-dmi-state) (make-atr-state)
    (make-stoch-state) (make-cci-state) (make-mfi-state) (make-obv-state)
    (make-sma-state 20)
    (make-ring-buffer 12)
    (make-ring-buffer 12) (make-ring-buffer 12)
    (make-ring-buffer 24) (make-ring-buffer 24)
    (make-ring-buffer 48) (make-ring-buffer 48)
    (make-ring-buffer 24)
    (make-ring-buffer 14)
    (make-ring-buffer 12) (make-ring-buffer 12) (make-ring-buffer 12)
    (make-ring-buffer 48) (make-ring-buffer 48) (make-ring-buffer 48)
    (make-ichimoku-state)
    (make-ring-buffer 48)
    0.0 0.0
    (make-ring-buffer 10)
    0.0 (make-ring-buffer 14)
    (make-ring-buffer 48) (make-ring-buffer 30)
    (make-ring-buffer 30)
    (make-ring-buffer 25) (make-ring-buffer 25)
    (make-ring-buffer 30)
    (make-ring-buffer 20) (make-ring-buffer 20)
    0.0 0.0
    0.0
    0 0
    0.0 0.0
    0.0
    0))

;; ── The full tick ──────────────────────────────────────────────────
;; One raw candle in, one enriched Candle out.

(define (tick [bank : IndicatorBank] [rc : RawCandle])
  : (Candle IndicatorBank)
  (let ((o (:open rc)) (h (:high rc)) (l (:low rc)) (c (:close rc)) (v (:volume rc))
        (ts (:ts rc))

        ;; Update all streaming state
        (new-sma20 (sma-update (:sma20 bank) c))
        (new-sma50 (sma-update (:sma50 bank) c))
        (new-sma200 (sma-update (:sma200 bank) c))
        (new-ema20 (ema-update (:ema20 bank) c))
        (new-bb-stddev (stddev-update (:bb-stddev bank) c))
        (new-rsi (rsi-update (:rsi bank) c))
        (new-macd (macd-update (:macd bank) c))
        (new-dmi (dmi-update (:dmi bank) h l c))
        (new-atr (atr-update (:atr bank) h l c))
        (new-stoch (stoch-update (:stoch bank) h l c))
        (new-cci (cci-update (:cci bank) h l c))
        (new-mfi (mfi-update (:mfi bank) h l c v))
        (new-obv (obv-update (:obv bank) c v))
        (new-vol-sma20 (sma-update (:volume-sma20 bank) v))
        (new-roc-buf (rb-push (:roc-buf bank) c))
        (new-rh12 (rb-push (:range-high-12 bank) h))
        (new-rl12 (rb-push (:range-low-12 bank) l))
        (new-rh24 (rb-push (:range-high-24 bank) h))
        (new-rl24 (rb-push (:range-low-24 bank) l))
        (new-rh48 (rb-push (:range-high-48 bank) h))
        (new-rl48 (rb-push (:range-low-48 bank) l))
        (new-trend-24 (rb-push (:trend-buf-24 bank)
                        (if (> c (:prev-close bank)) 1.0 0.0)))
        (atr-val (:value (:wilder new-atr)))
        (new-atr-hist (rb-push (:atr-history bank) atr-val))
        (new-tf-1h-buf (rb-push (:tf-1h-buf bank) c))
        (new-tf-1h-h (rb-push (:tf-1h-high bank) h))
        (new-tf-1h-l (rb-push (:tf-1h-low bank) l))
        (new-tf-4h-buf (rb-push (:tf-4h-buf bank) c))
        (new-tf-4h-h (rb-push (:tf-4h-high bank) h))
        (new-tf-4h-l (rb-push (:tf-4h-low bank) l))
        (new-ichimoku (ichimoku-update (:ichimoku bank) h l))
        (new-close-48 (rb-push (:close-buf-48 bank) c))
        (new-vwap-vol (+ (:vwap-cum-vol bank) v))
        (new-vwap-pv (+ (:vwap-cum-pv bank) (* c v)))
        (new-kama-buf (rb-push (:kama-er-buf bank) c))
        (new-chop-buf (rb-push (:chop-buf bank) atr-val))
        (new-chop-sum (rb-sum new-chop-buf))
        (new-dfa-buf (rb-push (:dfa-buf bank) c))
        (new-var-buf (rb-push (:var-ratio-buf bank) c))
        (new-entropy-buf (rb-push (:entropy-buf bank) c))
        (new-aroon-h (rb-push (:aroon-high-buf bank) h))
        (new-aroon-l (rb-push (:aroon-low-buf bank) l))
        (new-fractal-buf (rb-push (:fractal-buf bank) c))
        (rsi-val (/ (rsi-value new-rsi) 100.0))
        (new-rsi-peak-buf (rb-push (:rsi-peak-buf bank) rsi-val))
        (new-price-peak-buf (rb-push (:price-peak-buf bank) c))
        (new-count (+ (:count bank) 1))

        ;; ── Compute derived values ──
        (sma20-val (sma-value new-sma20))
        (sma50-val (sma-value new-sma50))
        (sma200-val (sma-value new-sma200))

        ;; Bollinger
        (bb-std (stddev-value new-bb-stddev))
        (bb-upper-val (+ sma20-val (* 2.0 bb-std)))
        (bb-lower-val (- sma20-val (* 2.0 bb-std)))
        (bb-width-val (if (= c 0.0) 0.0 (/ (- bb-upper-val bb-lower-val) c)))
        (bb-pos-val (if (= (- bb-upper-val bb-lower-val) 0.0) 0.5
                      (/ (- c bb-lower-val) (- bb-upper-val bb-lower-val))))

        ;; MACD
        (macd-val (- (:value (:fast-ema new-macd)) (:value (:slow-ema new-macd))))
        (macd-sig ((:value (:signal-ema new-macd))))
        (macd-hist-val (- macd-val macd-sig))

        ;; DMI
        (tr-val (:value (:tr-smoother new-dmi)))
        (plus-di-val (if (= tr-val 0.0) 0.0
                       (* 100.0 (/ (:value (:plus-smoother new-dmi)) tr-val))))
        (minus-di-val (if (= tr-val 0.0) 0.0
                        (* 100.0 (/ (:value (:minus-smoother new-dmi)) tr-val))))
        (adx-val (:value (:adx-smoother new-dmi)))
        (atr-r-val (if (= c 0.0) 0.0 (/ atr-val c)))

        ;; Stochastic
        (stoch-k-val (if (= (:len (:k-buf new-stoch)) 0) 50.0
                       (rb-get (:k-buf new-stoch) 0)))
        (stoch-d-val (/ (rb-sum (:k-buf new-stoch))
                        (max 1.0 (+ 0.0 (:len (:k-buf new-stoch))))))

        ;; Williams %R
        (high14-val (rb-max (:high-buf new-stoch)))
        (low14-val (rb-min (:low-buf new-stoch)))
        (williams-val (if (= high14-val low14-val) -50.0
                        (* -100.0 (/ (- high14-val c) (- high14-val low14-val)))))

        ;; CCI, MFI
        (cci-val (cci-value new-cci))
        (mfi-val (/ (mfi-value new-mfi) 100.0))

        ;; OBV
        (obv-slope (obv-slope-12 new-obv))

        ;; Volume accel
        (vol-sma-val (sma-value new-vol-sma20))
        (vol-accel (if (= vol-sma-val 0.0) 1.0 (/ v vol-sma-val)))

        ;; Keltner
        (ema20-val (:value new-ema20))
        (kelt-upper-val (+ ema20-val (* 1.5 atr-val)))
        (kelt-lower-val (- ema20-val (* 1.5 atr-val)))
        (kelt-width (- kelt-upper-val kelt-lower-val))
        (kelt-pos-val (if (= kelt-width 0.0) 0.5
                        (/ (- c kelt-lower-val) kelt-width)))
        (squeeze-val (if (= kelt-width 0.0) 1.0
                       (/ (- bb-upper-val bb-lower-val) kelt-width)))

        ;; ROC
        (roc-fn (lambda (ago)
                  (if (< (:len new-roc-buf) (+ ago 1)) 0.0
                    (let ((old-c (rb-get new-roc-buf ago)))
                      (if (= old-c 0.0) 0.0 (/ (- c old-c) old-c))))))
        (roc-1-val (roc-fn 1))
        (roc-3-val (roc-fn 3))
        (roc-6-val (roc-fn 6))
        (roc-12-val (roc-fn 11))

        ;; ATR ROC
        (atr-roc-fn (lambda (ago)
                      (if (< (:len new-atr-hist) (+ ago 1)) 0.0
                        (let ((old-atr (rb-get new-atr-hist ago)))
                          (if (= old-atr 0.0) 0.0 (/ (- atr-val old-atr) old-atr))))))
        (atr-roc-6-val (atr-roc-fn 6))
        (atr-roc-12-val (atr-roc-fn 12))

        ;; Trend consistency
        (tc-fn (lambda (period)
                 (let ((n (min period (:len new-trend-24))))
                   (if (= n 0) 0.5
                     (/ (fold (lambda (s i) (+ s (rb-get new-trend-24 i))) 0.0 (range 0 n))
                        (+ 0.0 n))))))
        (tc-6 (tc-fn 6))
        (tc-12 (tc-fn 12))
        (tc-24 (tc-fn 24))

        ;; Range position
        (rp-fn (lambda (h-buf l-buf)
                 (let ((highest (rb-max h-buf))
                       (lowest (rb-min l-buf))
                       (rng (- highest lowest)))
                   (if (= rng 0.0) 0.5 (/ (- c lowest) rng)))))
        (rp-12 (rp-fn new-rh12 new-rl12))
        (rp-24 (rp-fn new-rh24 new-rl24))
        (rp-48 (rp-fn new-rh48 new-rl48))

        ;; Multi-timeframe
        (tf-close (lambda (buf) (if (= (:len buf) 0) c (rb-get buf 0))))
        (tf-hi (lambda (buf) (rb-max buf)))
        (tf-lo (lambda (buf) (rb-min buf)))
        (tf-ret (lambda (buf)
                  (if (< (:len buf) 2) 0.0
                    (let ((oldest (rb-get buf (- (:len buf) 1))))
                      (if (= oldest 0.0) 0.0 (/ (- (rb-get buf 0) oldest) oldest))))))
        (tf-body (lambda (buf)
                   (if (< (:len buf) 2) 0.0
                     (let ((open-v (rb-get buf (- (:len buf) 1)))
                           (close-v (rb-get buf 0))
                           (range-v (- (rb-max buf) (rb-min buf))))
                       (if (= range-v 0.0) 0.0
                         (/ (abs (- close-v open-v)) range-v))))))
        (tf-1h-close-val (tf-close new-tf-1h-buf))
        (tf-1h-high-val (tf-hi new-tf-1h-h))
        (tf-1h-low-val (tf-lo new-tf-1h-l))
        (tf-1h-ret-val (tf-ret new-tf-1h-buf))
        (tf-1h-body-val (tf-body new-tf-1h-buf))
        (tf-4h-close-val (tf-close new-tf-4h-buf))
        (tf-4h-high-val (tf-hi new-tf-4h-h))
        (tf-4h-low-val (tf-lo new-tf-4h-l))
        (tf-4h-ret-val (tf-ret new-tf-4h-buf))
        (tf-4h-body-val (tf-body new-tf-4h-buf))

        ;; Ichimoku
        (tenkan (let ((h9 (rb-max (:high-9 new-ichimoku)))
                      (l9 (rb-min (:low-9 new-ichimoku))))
                  (/ (+ h9 l9) 2.0)))
        (kijun (let ((h26 (rb-max (:high-26 new-ichimoku)))
                     (l26 (rb-min (:low-26 new-ichimoku))))
                 (/ (+ h26 l26) 2.0)))
        (span-a (/ (+ tenkan kijun) 2.0))
        (span-b (let ((h52 (rb-max (:high-52 new-ichimoku)))
                      (l52 (rb-min (:low-52 new-ichimoku))))
                  (/ (+ h52 l52) 2.0)))
        (cloud-top-val (max span-a span-b))
        (cloud-bottom-val (min span-a span-b))

        ;; Persistence
        (hurst-val (hurst-exponent new-close-48))
        (autocorr-val (autocorrelation-lag1 new-close-48))
        (vwap-val (if (= new-vwap-vol 0.0) 0.0
                    (let ((vwap-price (/ new-vwap-pv new-vwap-vol)))
                      (if (= c 0.0) 0.0 (/ (- c vwap-price) c)))))

        ;; Regime
        (kama-er-val (kama-efficiency-ratio new-kama-buf))
        (chop-val (choppiness-index new-chop-sum new-rh12 new-rl12))
        (dfa-val (dfa-alpha new-dfa-buf))
        (var-ratio-val (variance-ratio new-var-buf))
        (entropy-val (entropy-rate new-entropy-buf))
        (aroon-up-val (aroon-up new-aroon-h))
        (aroon-down-val (aroon-down new-aroon-l))
        (fractal-val (fractal-dimension new-fractal-buf))

        ;; Divergence
        ((div-bull div-bear) (detect-divergence new-price-peak-buf new-rsi-peak-buf))

        ;; Cross deltas
        (tk-spread (- tenkan kijun))
        (tk-delta (- tk-spread (:prev-tk-spread bank)))
        (stoch-kd (- stoch-k-val stoch-d-val))
        (stoch-delta (- stoch-kd (:prev-stoch-kd bank)))

        ;; Price action
        (current-range (- h l))
        (range-ratio-val (if (= (:prev-range bank) 0.0) 1.0
                           (/ current-range (:prev-range bank))))
        (gap-val (if (= (:prev-close bank) 0.0) 0.0
                   (/ (- o (:prev-close bank)) (:prev-close bank))))
        (new-cons-up (if (> c (:prev-close bank)) (+ (:consecutive-up-count bank) 1) 0))
        (new-cons-down (if (< c (:prev-close bank)) (+ (:consecutive-down-count bank) 1) 0))

        ;; Timeframe agreement
        (five-min-dir (signum roc-1-val))
        (one-h-dir (signum tf-1h-ret-val))
        (four-h-dir (signum tf-4h-ret-val))
        (agreement (/ (+ (if (= five-min-dir one-h-dir) 1.0 0.0)
                        (if (= five-min-dir four-h-dir) 1.0 0.0)
                        (if (= one-h-dir four-h-dir) 1.0 0.0))
                     3.0))

        ;; Time
        (minute-val (parse-minute ts))
        (hour-val (parse-hour ts))
        (dow-val (parse-day-of-week ts))
        (dom-val (parse-day-of-month ts))
        (moy-val (parse-month-of-year ts))

        ;; ── Build Candle ──
        (enriched (candle
          ts o h l c v
          sma20-val sma50-val sma200-val
          bb-upper-val bb-lower-val bb-width-val bb-pos-val
          (/ (rsi-value new-rsi) 100.0) macd-val macd-sig macd-hist-val
          plus-di-val minus-di-val adx-val atr-val atr-r-val
          (/ stoch-k-val 100.0) (/ stoch-d-val 100.0) (/ williams-val -100.0)
          cci-val mfi-val
          obv-slope vol-accel
          kelt-upper-val kelt-lower-val kelt-pos-val squeeze-val
          roc-1-val roc-3-val roc-6-val roc-12-val
          atr-roc-6-val atr-roc-12-val
          tc-6 tc-12 tc-24
          rp-12 rp-24 rp-48
          tf-1h-close-val tf-1h-high-val tf-1h-low-val tf-1h-ret-val tf-1h-body-val
          tf-4h-close-val tf-4h-high-val tf-4h-low-val tf-4h-ret-val tf-4h-body-val
          tenkan kijun span-a span-b cloud-top-val cloud-bottom-val
          hurst-val autocorr-val vwap-val
          kama-er-val chop-val dfa-val var-ratio-val entropy-val
          aroon-up-val aroon-down-val fractal-val
          div-bull div-bear
          tk-delta stoch-delta
          range-ratio-val gap-val (+ 0.0 new-cons-up) (+ 0.0 new-cons-down)
          agreement
          minute-val hour-val dow-val dom-val moy-val))

        ;; ── Update bank state ──
        (new-bank (update bank
          :sma20 new-sma20 :sma50 new-sma50 :sma200 new-sma200
          :ema20 new-ema20 :bb-stddev new-bb-stddev
          :rsi new-rsi :macd new-macd :dmi new-dmi :atr new-atr
          :stoch new-stoch :cci new-cci :mfi new-mfi :obv new-obv
          :volume-sma20 new-vol-sma20
          :roc-buf new-roc-buf
          :range-high-12 new-rh12 :range-low-12 new-rl12
          :range-high-24 new-rh24 :range-low-24 new-rl24
          :range-high-48 new-rh48 :range-low-48 new-rl48
          :trend-buf-24 new-trend-24
          :atr-history new-atr-hist
          :tf-1h-buf new-tf-1h-buf :tf-1h-high new-tf-1h-h :tf-1h-low new-tf-1h-l
          :tf-4h-buf new-tf-4h-buf :tf-4h-high new-tf-4h-h :tf-4h-low new-tf-4h-l
          :ichimoku new-ichimoku
          :close-buf-48 new-close-48
          :vwap-cum-vol new-vwap-vol :vwap-cum-pv new-vwap-pv
          :kama-er-buf new-kama-buf
          :chop-atr-sum new-chop-sum :chop-buf new-chop-buf
          :dfa-buf new-dfa-buf :var-ratio-buf new-var-buf
          :entropy-buf new-entropy-buf
          :aroon-high-buf new-aroon-h :aroon-low-buf new-aroon-l
          :fractal-buf new-fractal-buf
          :rsi-peak-buf new-rsi-peak-buf :price-peak-buf new-price-peak-buf
          :prev-tk-spread tk-spread :prev-stoch-kd stoch-kd
          :prev-range current-range
          :consecutive-up-count new-cons-up :consecutive-down-count new-cons-down
          :prev-tf-1h-ret tf-1h-ret-val :prev-tf-4h-ret tf-4h-ret-val
          :prev-close c
          :count new-count)))

    (list enriched new-bank)))
