;; indicator-bank.wat — IndicatorBank (streaming primitives + tick)
;; Depends on: raw-candle, candle

(require primitives)
(require raw-candle)
(require candle)

;; ═══════════════════════════════════════════════════════════════════════
;; Streaming primitives — the building blocks of indicator state
;; ═══════════════════════════════════════════════════════════════════════

;; ── RingBuffer ────────────────────────────────────────────────────────
(struct ring-buffer
  [data     : Vec<f64>]
  [capacity : usize]
  [head     : usize]
  [len      : usize])

(define (make-ring-buffer [capacity : usize])
  : RingBuffer
  (ring-buffer (zeros capacity) capacity 0 0))

(define (rb-push [rb : RingBuffer] [value : f64])
  (set! rb :data (:head rb) value)
  (set! rb :head (mod (+ (:head rb) 1) (:capacity rb)))
  (when (< (:len rb) (:capacity rb))
    (inc! rb :len)))

(define (rb-get [rb : RingBuffer] [idx : usize])
  : f64
  ;; idx 0 = oldest, idx (len-1) = newest
  (let ((start (if (< (:len rb) (:capacity rb))
                 0
                 (:head rb)))
        (actual (mod (+ start idx) (:capacity rb))))
    (nth (:data rb) actual)))

(define (rb-newest [rb : RingBuffer])
  : f64
  (rb-get rb (- (:len rb) 1)))

(define (rb-oldest [rb : RingBuffer])
  : f64
  (rb-get rb 0))

(define (rb-full? [rb : RingBuffer])
  : bool
  (= (:len rb) (:capacity rb)))

(define (rb-max [rb : RingBuffer])
  : f64
  (fold max f64-neg-infinity
    (map (lambda (i) (rb-get rb i)) (range 0 (:len rb)))))

(define (rb-min [rb : RingBuffer])
  : f64
  (fold min f64-infinity
    (map (lambda (i) (rb-get rb i)) (range 0 (:len rb)))))

(define (rb-to-list [rb : RingBuffer])
  : Vec<f64>
  (map (lambda (i) (rb-get rb i)) (range 0 (:len rb))))

;; ── EmaState ──────────────────────────────────────────────────────────
(struct ema-state
  [value     : f64]
  [smoothing : f64]
  [period    : usize]
  [count     : usize]
  [accum     : f64])

(define (make-ema-state [period : usize])
  : EmaState
  (let ((smoothing (/ 2.0 (+ 1.0 (+ 0.0 period)))))
    (ema-state 0.0 smoothing period 0 0.0)))

(define (ema-update [ema : EmaState] [value : f64])
  : f64
  (if (< (:count ema) (:period ema))
    ;; Accumulate for SMA seed
    (begin
      (set! ema :accum (+ (:accum ema) value))
      (inc! ema :count)
      (if (= (:count ema) (:period ema))
        (let ((seed (/ (:accum ema) (+ 0.0 (:period ema)))))
          (set! ema :value seed)
          seed)
        (/ (:accum ema) (+ 0.0 (:count ema)))))
    ;; EMA formula
    (let ((new-val (+ (* (:smoothing ema) value)
                      (* (- 1.0 (:smoothing ema)) (:value ema)))))
      (set! ema :value new-val)
      (inc! ema :count)
      new-val)))

;; ── WilderState ───────────────────────────────────────────────────────
(struct wilder-state
  [value  : f64]
  [period : usize]
  [count  : usize]
  [accum  : f64])

(define (make-wilder-state [period : usize])
  : WilderState
  (wilder-state 0.0 period 0 0.0))

(define (wilder-update [ws : WilderState] [value : f64])
  : f64
  (if (< (:count ws) (:period ws))
    ;; Accumulate for seed
    (begin
      (set! ws :accum (+ (:accum ws) value))
      (inc! ws :count)
      (if (= (:count ws) (:period ws))
        (let ((seed (/ (:accum ws) (+ 0.0 (:period ws)))))
          (set! ws :value seed)
          seed)
        (/ (:accum ws) (+ 0.0 (:count ws)))))
    ;; Wilder smoothing: new = (prev × (period-1) + value) / period
    (let ((new-val (/ (+ (* (:value ws) (- (+ 0.0 (:period ws)) 1.0)) value)
                      (+ 0.0 (:period ws)))))
      (set! ws :value new-val)
      (inc! ws :count)
      new-val)))

;; ── RsiState ──────────────────────────────────────────────────────────
(struct rsi-state
  [gain-smoother : WilderState]
  [loss-smoother : WilderState]
  [prev-close    : f64]
  [started       : bool])

(define (make-rsi-state)
  : RsiState
  (let ((period 14))
    (rsi-state (make-wilder-state period) (make-wilder-state period) 0.0 false)))

(define (rsi-update [rsi : RsiState] [close : f64])
  : f64
  (if (not (:started rsi))
    (begin
      (set! rsi :prev-close close)
      (set! rsi :started true)
      50.0)
    (let ((change (- close (:prev-close rsi)))
          (gain (if (> change 0.0) change 0.0))
          (loss (if (< change 0.0) (abs change) 0.0))
          (avg-gain (wilder-update (:gain-smoother rsi) gain))
          (avg-loss (wilder-update (:loss-smoother rsi) loss)))
      (set! rsi :prev-close close)
      (if (= avg-loss 0.0)
        100.0
        (let ((rs (/ avg-gain avg-loss)))
          (- 100.0 (/ 100.0 (+ 1.0 rs))))))))

;; ── AtrState ──────────────────────────────────────────────────────────
(struct atr-state
  [wilder     : WilderState]
  [prev-close : f64]
  [started    : bool])

(define (make-atr-state)
  : AtrState
  (let ((period 14))
    (atr-state (make-wilder-state period) 0.0 false)))

(define (atr-update [atr : AtrState] [high : f64] [low : f64] [close : f64])
  : f64
  (if (not (:started atr))
    (begin
      (set! atr :prev-close close)
      (set! atr :started true)
      (let ((tr (- high low)))
        (wilder-update (:wilder atr) tr)))
    (let ((tr (max (- high low)
                   (max (abs (- high (:prev-close atr)))
                        (abs (- low (:prev-close atr)))))))
      (set! atr :prev-close close)
      (wilder-update (:wilder atr) tr))))

;; ── ObvState ──────────────────────────────────────────────────────────
(struct obv-state
  [obv        : f64]
  [prev-close : f64]
  [history    : RingBuffer]
  [started    : bool])

(define (make-obv-state)
  : ObvState
  (obv-state 0.0 0.0 (make-ring-buffer 12) false))

(define (obv-update [state : ObvState] [close : f64] [volume : f64])
  : f64
  (if (not (:started state))
    (begin
      (set! state :prev-close close)
      (set! state :started true)
      (rb-push (:history state) 0.0)
      0.0)
    (let ((delta (cond
                   ((> close (:prev-close state)) volume)
                   ((< close (:prev-close state)) (- 0.0 volume))
                   (else 0.0)))
          (new-obv (+ (:obv state) delta)))
      (set! state :obv new-obv)
      (set! state :prev-close close)
      (rb-push (:history state) new-obv)
      new-obv)))

;; ── SmaState ──────────────────────────────────────────────────────────
;; period is the buffer's capacity — one source of truth, not two.
(struct sma-state
  [buffer : RingBuffer]
  [sum    : f64])

(define (make-sma-state [period : usize])
  : SmaState
  (sma-state (make-ring-buffer period) 0.0))

(define (sma-update [sma : SmaState] [value : f64])
  : f64
  (let ((buf (:buffer sma)))
    ;; If buffer is full, subtract the oldest value
    (when (rb-full? buf)
      (set! sma :sum (- (:sum sma) (rb-oldest buf))))
    (set! sma :sum (+ (:sum sma) value))
    (rb-push buf value)
    (/ (:sum sma) (+ 0.0 (:len buf)))))

;; ── RollingStddev ─────────────────────────────────────────────────────
;; period is the buffer's capacity.
(struct rolling-stddev
  [buffer : RingBuffer]
  [sum    : f64]
  [sum-sq : f64])

(define (make-rolling-stddev [period : usize])
  : RollingStddev
  (rolling-stddev (make-ring-buffer period) 0.0 0.0))

(define (stddev-update [rs : RollingStddev] [value : f64])
  : f64
  (let ((buf (:buffer rs)))
    (when (rb-full? buf)
      (let ((old (rb-oldest buf)))
        (set! rs :sum (- (:sum rs) old))
        (set! rs :sum-sq (- (:sum-sq rs) (* old old)))))
    (set! rs :sum (+ (:sum rs) value))
    (set! rs :sum-sq (+ (:sum-sq rs) (* value value)))
    (rb-push buf value)
    (let ((n (+ 0.0 (:len buf)))
          (mean (/ (:sum rs) n))
          (var (- (/ (:sum-sq rs) n) (* mean mean))))
      (sqrt (max 0.0 var)))))

;; ── StochState ────────────────────────────────────────────────────────
(struct stoch-state
  [high-buf : RingBuffer]
  [low-buf  : RingBuffer]
  [k-buf    : RingBuffer])

(define (make-stoch-state)
  : StochState
  (let ((period 14)
        (d-period 3))
    (stoch-state (make-ring-buffer period) (make-ring-buffer period) (make-ring-buffer d-period))))

(define (stoch-update [state : StochState] [high : f64] [low : f64] [close : f64])
  : (f64, f64)
  (rb-push (:high-buf state) high)
  (rb-push (:low-buf state) low)
  (let ((highest (rb-max (:high-buf state)))
        (lowest (rb-min (:low-buf state)))
        (range (- highest lowest))
        (k (if (= range 0.0) 50.0 (* (/ (- close lowest) range) 100.0))))
    (rb-push (:k-buf state) k)
    ;; %D = SMA(3) of %K
    (let ((d (/ (fold + 0.0 (rb-to-list (:k-buf state)))
                (+ 0.0 (:len (:k-buf state))))))
      (list k d))))

;; ── CciState ──────────────────────────────────────────────────────────
(struct cci-state
  [tp-buf : RingBuffer]
  [tp-sma : SmaState])

(define (make-cci-state)
  : CciState
  (let ((period 20))
    (cci-state (make-ring-buffer period) (make-sma-state period))))

(define (cci-update [state : CciState] [high : f64] [low : f64] [close : f64])
  : f64
  (let ((tp (/ (+ high low close) 3.0))
        (tp-mean (sma-update (:tp-sma state) tp)))
    (rb-push (:tp-buf state) tp)
    ;; Mean deviation
    (let ((tp-list (rb-to-list (:tp-buf state)))
          (mean-dev (/ (fold + 0.0 (map (lambda (v) (abs (- v tp-mean))) tp-list))
                       (+ 0.0 (length tp-list))))
          (cci-constant 0.015))
      (if (= mean-dev 0.0)
        0.0
        (/ (- tp tp-mean) (* cci-constant mean-dev))))))

;; ── MfiState ──────────────────────────────────────────────────────────
(struct mfi-state
  [pos-flow-buf : RingBuffer]
  [neg-flow-buf : RingBuffer]
  [prev-tp      : f64]
  [started      : bool])

(define (make-mfi-state)
  : MfiState
  (let ((period 14))
    (mfi-state (make-ring-buffer period) (make-ring-buffer period) 0.0 false)))

(define (mfi-update [state : MfiState] [high : f64] [low : f64] [close : f64] [volume : f64])
  : f64
  (let ((tp (/ (+ high low close) 3.0))
        (money-flow (* tp volume)))
    (if (not (:started state))
      (begin
        (set! state :prev-tp tp)
        (set! state :started true)
        (rb-push (:pos-flow-buf state) 0.0)
        (rb-push (:neg-flow-buf state) 0.0)
        50.0)
      (begin
        (if (> tp (:prev-tp state))
          (begin
            (rb-push (:pos-flow-buf state) money-flow)
            (rb-push (:neg-flow-buf state) 0.0))
          (begin
            (rb-push (:pos-flow-buf state) 0.0)
            (rb-push (:neg-flow-buf state) money-flow)))
        (set! state :prev-tp tp)
        (let ((pos-sum (fold + 0.0 (rb-to-list (:pos-flow-buf state))))
              (neg-sum (fold + 0.0 (rb-to-list (:neg-flow-buf state)))))
          (if (= neg-sum 0.0)
            100.0
            (let ((mfr (/ pos-sum neg-sum)))
              (- 100.0 (/ 100.0 (+ 1.0 mfr))))))))))

;; ── IchimokuState ─────────────────────────────────────────────────────
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

;; ── MacdState ─────────────────────────────────────────────────────────
(struct macd-state
  [fast-ema   : EmaState]
  [slow-ema   : EmaState]
  [signal-ema : EmaState])

(define (make-macd-state)
  : MacdState
  (macd-state (make-ema-state 12) (make-ema-state 26) (make-ema-state 9)))

(define (macd-update [state : MacdState] [close : f64])
  : (f64, f64, f64)
  (let ((fast (ema-update (:fast-ema state) close))
        (slow (ema-update (:slow-ema state) close))
        (macd-val (- fast slow))
        (signal (ema-update (:signal-ema state) macd-val))
        (hist (- macd-val signal)))
    (list macd-val signal hist)))

;; ── DmiState ──────────────────────────────────────────────────────────
;; period is implicit in the WilderState smoothers.
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
  (let ((period 14))
    (dmi-state
      (make-wilder-state period) (make-wilder-state period)
      (make-wilder-state period) (make-wilder-state period)
      0.0 0.0 0.0 false 0)))

(define (dmi-update [state : DmiState] [high : f64] [low : f64] [close : f64])
  : (f64, f64, f64)
  (if (not (:started state))
    (begin
      (set! state :prev-high high)
      (set! state :prev-low low)
      (set! state :prev-close close)
      (set! state :started true)
      (list 0.0 0.0 0.0))
    (let ((up-move (- high (:prev-high state)))
          (down-move (- (:prev-low state) low))
          (plus-dm (if (and (> up-move down-move) (> up-move 0.0)) up-move 0.0))
          (minus-dm (if (and (> down-move up-move) (> down-move 0.0)) down-move 0.0))
          (tr (max (- high low)
                   (max (abs (- high (:prev-close state)))
                        (abs (- low (:prev-close state))))))
          (smoothed-tr (wilder-update (:tr-smoother state) tr))
          (smoothed-plus (wilder-update (:plus-smoother state) plus-dm))
          (smoothed-minus (wilder-update (:minus-smoother state) minus-dm))
          (plus-di (if (= smoothed-tr 0.0) 0.0 (* (/ smoothed-plus smoothed-tr) 100.0)))
          (minus-di (if (= smoothed-tr 0.0) 0.0 (* (/ smoothed-minus smoothed-tr) 100.0)))
          (di-sum (+ plus-di minus-di))
          (dx (if (= di-sum 0.0) 0.0 (* (/ (abs (- plus-di minus-di)) di-sum) 100.0)))
          (adx (wilder-update (:adx-smoother state) dx)))
      (set! state :prev-high high)
      (set! state :prev-low low)
      (set! state :prev-close close)
      (inc! state :count)
      (list plus-di minus-di adx))))

;; ═══════════════════════════════════════════════════════════════════════
;; IndicatorBank — composed from streaming primitives
;; ═══════════════════════════════════════════════════════════════════════

(struct indicator-bank
  ;; Moving averages
  [sma20  : SmaState]
  [sma50  : SmaState]
  [sma200 : SmaState]
  [ema20  : EmaState]
  ;; Bollinger
  [bb-stddev : RollingStddev]
  ;; Oscillators
  [rsi  : RsiState]
  [macd : MacdState]
  [dmi  : DmiState]
  [atr  : AtrState]
  [stoch : StochState]
  [cci  : CciState]
  [mfi  : MfiState]
  [obv  : ObvState]
  [volume-sma20 : SmaState]
  ;; ROC
  [roc-buf : RingBuffer]
  ;; Range position
  [range-high-12 : RingBuffer]  [range-low-12 : RingBuffer]
  [range-high-24 : RingBuffer]  [range-low-24 : RingBuffer]
  [range-high-48 : RingBuffer]  [range-low-48 : RingBuffer]
  ;; Trend consistency
  [trend-buf-24 : RingBuffer]
  ;; ATR history
  [atr-history : RingBuffer]
  ;; Multi-timeframe
  [tf-1h-buf  : RingBuffer]  [tf-1h-high : RingBuffer]  [tf-1h-low : RingBuffer]
  [tf-4h-buf  : RingBuffer]  [tf-4h-high : RingBuffer]  [tf-4h-low : RingBuffer]
  ;; Ichimoku
  [ichimoku : IchimokuState]
  ;; Persistence
  [close-buf-48 : RingBuffer]
  ;; VWAP
  [vwap-cum-vol : f64]
  [vwap-cum-pv  : f64]
  ;; Regime
  [kama-er-buf : RingBuffer]
  [chop-atr-sum : f64]
  [chop-buf : RingBuffer]
  [dfa-buf : RingBuffer]
  [var-ratio-buf : RingBuffer]
  [entropy-buf : RingBuffer]
  [aroon-high-buf : RingBuffer]
  [aroon-low-buf : RingBuffer]
  [fractal-buf : RingBuffer]
  ;; Divergence
  [rsi-peak-buf : RingBuffer]
  [price-peak-buf : RingBuffer]
  ;; Cross deltas
  [prev-tk-spread : f64]
  [prev-stoch-kd : f64]
  ;; Price action
  [prev-range : f64]
  [consecutive-up-count : usize]
  [consecutive-down-count : usize]
  ;; Timeframe agreement
  [prev-tf-1h-ret : f64]
  [prev-tf-4h-ret : f64]
  ;; Previous values
  [prev-close : f64]
  ;; Counter
  [count : usize])

(define (make-indicator-bank)
  : IndicatorBank
  (indicator-bank
    ;; Moving averages
    (make-sma-state 20) (make-sma-state 50) (make-sma-state 200)
    (make-ema-state 20)
    ;; Bollinger
    (make-rolling-stddev 20)
    ;; Oscillators
    (make-rsi-state) (make-macd-state) (make-dmi-state) (make-atr-state)
    (make-stoch-state) (make-cci-state) (make-mfi-state) (make-obv-state)
    (make-sma-state 20)
    ;; ROC — 12-period close buffer
    (make-ring-buffer 12)
    ;; Range position
    (make-ring-buffer 12) (make-ring-buffer 12)
    (make-ring-buffer 24) (make-ring-buffer 24)
    (make-ring-buffer 48) (make-ring-buffer 48)
    ;; Trend consistency — 24-period return direction buffer
    (make-ring-buffer 24)
    ;; ATR history — for atr-r and ATR ROC
    (make-ring-buffer 12)
    ;; Multi-timeframe: 1h = 12 × 5min, 4h = 48 × 5min
    (make-ring-buffer 12) (make-ring-buffer 12) (make-ring-buffer 12)
    (make-ring-buffer 48) (make-ring-buffer 48) (make-ring-buffer 48)
    ;; Ichimoku
    (make-ichimoku-state)
    ;; Persistence
    (make-ring-buffer 48)
    ;; VWAP
    0.0 0.0
    ;; Regime
    (make-ring-buffer 10)    ; kama-er-buf (10 periods)
    0.0                       ; chop-atr-sum
    (make-ring-buffer 14)    ; chop-buf (14 periods)
    (make-ring-buffer 48)    ; dfa-buf
    (make-ring-buffer 30)    ; var-ratio-buf
    (make-ring-buffer 30)    ; entropy-buf
    (make-ring-buffer 25)    ; aroon-high-buf
    (make-ring-buffer 25)    ; aroon-low-buf
    (make-ring-buffer 30)    ; fractal-buf
    ;; Divergence
    (make-ring-buffer 30)    ; rsi-peak-buf
    (make-ring-buffer 30)    ; price-peak-buf
    ;; Cross deltas
    0.0 0.0
    ;; Price action
    0.0 0 0
    ;; Timeframe agreement
    0.0 0.0
    ;; Previous values
    0.0
    ;; Counter
    0))

;; ═══════════════════════════════════════════════════════════════════════
;; Helper functions for tick
;; ═══════════════════════════════════════════════════════════════════════

;; Linear regression slope over a ring buffer
(define (linreg-slope [rb : RingBuffer])
  : f64
  (let ((n (:len rb)))
    (if (< n 2)
      0.0
      (let ((nf (+ 0.0 n))
            (sum-x (/ (* nf (- nf 1.0)) 2.0))
            (sum-x2 (/ (* nf (- nf 1.0) (- (* 2.0 nf) 1.0)) 6.0))
            (values (rb-to-list rb))
            (sum-y (fold + 0.0 values))
            (sum-xy (fold + 0.0
                      (map (lambda (i) (* (+ 0.0 i) (nth values i)))
                           (range 0 n))))
            (denom (- (* nf sum-x2) (* sum-x sum-x))))
        (if (= denom 0.0)
          0.0
          (/ (- (* nf sum-xy) (* sum-x sum-y)) denom))))))

;; Range position: (close - lowest) / (highest - lowest)
(define (compute-range-pos [high-buf : RingBuffer]
                           [low-buf : RingBuffer]
                           [close : f64])
  : f64
  (let ((highest (rb-max high-buf))
        (lowest (rb-min low-buf))
        (range (- highest lowest)))
    (if (= range 0.0) 0.5 (/ (- close lowest) range))))

;; Trend consistency: fraction of positive returns in buffer
(define (compute-trend-consistency [buf : RingBuffer] [n : usize])
  : f64
  (let ((values (rb-to-list buf))
        (len (length values))
        (start (max 0 (- len n)))
        (window (take-last (min n len) values))
        (positive (count (lambda (v) (> v 0.0)) window)))
    (if (= (length window) 0) 0.5 (/ (+ 0.0 positive) (+ 0.0 (length window))))))

;; Hurst exponent via R/S analysis
(define (compute-hurst [values : Vec<f64>])
  : f64
  (let ((n (length values)))
    (if (< n 8)
      0.5
      (let ((returns (map (lambda (i) (- (nth values i) (nth values (- i 1))))
                          (range 1 n)))
            (mean-ret (/ (fold + 0.0 returns) (+ 0.0 (length returns))))
            (deviations (map (lambda (r) (- r mean-ret)) returns))
            ;; Cumulative deviations
            (cum-devs (fold-left (lambda (acc d)
                        (append acc (list (+ (if (empty? acc) 0.0 (last acc)) d))))
                      '() deviations))
            (range-rs (- (fold max f64-neg-infinity cum-devs)
                         (fold min f64-infinity cum-devs)))
            (std-dev (sqrt (/ (fold + 0.0 (map (lambda (r) (* r r)) returns))
                              (+ 0.0 (length returns))))))
        (if (= std-dev 0.0)
          0.5
          ;; H ≈ log(R/S) / log(n)
          (let ((rs (/ range-rs std-dev)))
            (if (<= rs 0.0)
              0.5
              (/ (ln rs) (ln (+ 0.0 (length returns)))))))))))

;; Lag-1 autocorrelation
(define (compute-autocorrelation [values : Vec<f64>])
  : f64
  (let ((n (length values)))
    (if (< n 3)
      0.0
      (let ((mean-val (/ (fold + 0.0 values) (+ 0.0 n)))
            (demeaned (map (lambda (v) (- v mean-val)) values))
            (var (/ (fold + 0.0 (map (lambda (d) (* d d)) demeaned)) (+ 0.0 n)))
            (cov (/ (fold + 0.0
                      (map (lambda (i) (* (nth demeaned i) (nth demeaned (- i 1))))
                           (range 1 n)))
                    (+ 0.0 (- n 1)))))
        (if (= var 0.0) 0.0 (/ cov var))))))

;; KAMA Efficiency Ratio
(define (compute-kama-er [buf : RingBuffer])
  : f64
  (let ((values (rb-to-list buf))
        (n (length values)))
    (if (< n 2)
      0.0
      (let ((direction (abs (- (last values) (first values))))
            (volatility (fold + 0.0
                          (map (lambda (i) (abs (- (nth values i) (nth values (- i 1)))))
                               (range 1 n)))))
        (if (= volatility 0.0) 0.0 (/ direction volatility))))))

;; Choppiness Index: 100 * log(sum(ATR, 14) / range(14)) / log(14)
(define (compute-choppiness [atr-sum : f64]
                            [high-buf : RingBuffer]
                            [low-buf : RingBuffer])
  : f64
  (let ((highest (rb-max high-buf))
        (lowest (rb-min low-buf))
        (range (- highest lowest))
        (period 14.0))
    (if (<= range 0.0)
      50.0
      (* 100.0 (/ (ln (/ atr-sum range)) (ln period))))))

;; DFA-alpha (simplified detrended fluctuation analysis)
(define (compute-dfa-alpha [values : Vec<f64>])
  : f64
  (let ((n (length values)))
    (if (< n 16)
      0.5
      ;; Simplified: compute variance of detrended segments at two scales
      (let ((returns (map (lambda (i) (- (nth values i) (nth values (- i 1))))
                          (range 1 n)))
            ;; Cumulative profile
            (mean-ret (/ (fold + 0.0 returns) (+ 0.0 (length returns))))
            (profile (fold-left (lambda (acc r)
                       (append acc (list (+ (if (empty? acc) 0.0 (last acc)) (- r mean-ret)))))
                     '() returns))
            ;; Variance at scale 4
            (var-4 (/ (fold + 0.0 (map (lambda (v) (* v v)) (take 4 profile))) 4.0))
            ;; Variance at scale 16
            (var-16 (/ (fold + 0.0 (map (lambda (v) (* v v)) (take (min 16 (length profile)) profile)))
                       (+ 0.0 (min 16 (length profile))))))
        (if (or (<= var-4 0.0) (<= var-16 0.0))
          0.5
          ;; alpha ≈ log(F(16)/F(4)) / log(16/4)
          (/ (ln (/ (sqrt var-16) (sqrt var-4))) (ln 4.0)))))))

;; Variance ratio
(define (compute-variance-ratio [values : Vec<f64>])
  : f64
  (let ((n (length values)))
    (if (< n 4)
      1.0
      (let ((returns (map (lambda (i) (- (nth values i) (nth values (- i 1))))
                          (range 1 n)))
            ;; Variance at scale 1
            (var-1 (variance returns))
            ;; Variance at scale 2 (sum of pairs)
            (pairs (filter-map
                     (lambda (i) (if (< (+ i 1) (length returns))
                                   (Some (+ (nth returns i) (nth returns (+ i 1))))
                                   None))
                     (range 0 (length returns))))
            (var-2 (if (empty? pairs) 0.0 (variance pairs))))
        (if (= var-1 0.0) 1.0 (/ var-2 (* 2.0 var-1)))))))

;; Conditional entropy of discretized returns
(define (compute-entropy-rate [values : Vec<f64>])
  : f64
  (let ((n (length values)))
    (if (< n 4)
      0.5
      (let ((returns (map (lambda (i) (- (nth values i) (nth values (- i 1))))
                          (range 1 n)))
            ;; Discretize into 3 bins: negative, zero, positive
            (bins (map (lambda (r) (cond ((< r -0.0001) -1)
                                         ((> r  0.0001)  1)
                                         (else 0)))
                       returns))
            ;; Count transitions
            (total-transitions (- (length bins) 1))
            ;; Simple entropy estimate from transition frequencies
            (transitions (map (lambda (i) (list (nth bins i) (nth bins (+ i 1))))
                              (range 0 total-transitions)))
            ;; Count unique transitions
            (n-trans (+ 0.0 total-transitions)))
        (if (<= n-trans 0.0)
          0.0
          ;; Normalized entropy [0, 1]
          (let ((unique-count (+ 0.0 (min 9 total-transitions))))
            (/ (ln unique-count) (ln 9.0))))))))

;; Aroon indicator
(define (compute-aroon [buf : RingBuffer])
  : f64
  (let ((values (rb-to-list buf))
        (n (length values))
        (period 25.0))
    (if (= n 0)
      50.0
      (let ((max-idx (fold-left (lambda (best i)
                       (if (>= (nth values i) (nth values best)) i best))
                     0 (range 0 n)))
            (periods-since (- n 1 max-idx)))
        (* (/ (- period (+ 0.0 periods-since)) period) 100.0)))))

(define (compute-aroon-down [buf : RingBuffer])
  : f64
  (let ((values (rb-to-list buf))
        (n (length values))
        (period 25.0))
    (if (= n 0)
      50.0
      (let ((min-idx (fold-left (lambda (best i)
                       (if (<= (nth values i) (nth values best)) i best))
                     0 (range 0 n)))
            (periods-since (- n 1 min-idx)))
        (* (/ (- period (+ 0.0 periods-since)) period) 100.0)))))

;; Fractal dimension (simplified box-counting)
(define (compute-fractal-dim [values : Vec<f64>])
  : f64
  (let ((n (length values)))
    (if (< n 4)
      1.5
      (let ((range-val (- (fold max f64-neg-infinity values)
                          (fold min f64-infinity values))))
        (if (= range-val 0.0)
          1.0
          (let ((path-length (fold + 0.0
                               (map (lambda (i) (abs (- (nth values i) (nth values (- i 1)))))
                                    (range 1 n)))))
            ;; D ≈ log(path-length/range) / log(n) + 1
            (if (<= path-length 0.0)
              1.0
              (+ 1.0 (/ (ln (/ path-length range-val))
                         (ln (+ 0.0 n)))))))))))

;; RSI divergence (simplified PELT-like peak detection)
(define (compute-rsi-divergence [price-buf : RingBuffer]
                                [rsi-buf : RingBuffer])
  : (f64, f64)
  (let ((prices (rb-to-list price-buf))
        (rsis (rb-to-list rsi-buf))
        (n (min (length prices) (length rsis))))
    (if (< n 10)
      (list 0.0 0.0)
      ;; Compare first half and second half peaks/troughs
      (let ((half (/ n 2))
            (p-first (take half prices))
            (p-second (take-last (- n half) prices))
            (r-first (take half rsis))
            (r-second (take-last (- n half) rsis))
            (p-min-1 (fold min f64-infinity p-first))
            (p-min-2 (fold min f64-infinity p-second))
            (r-min-1 (fold min f64-infinity r-first))
            (r-min-2 (fold min f64-infinity r-second))
            (p-max-1 (fold max f64-neg-infinity p-first))
            (p-max-2 (fold max f64-neg-infinity p-second))
            (r-max-1 (fold max f64-neg-infinity r-first))
            (r-max-2 (fold max f64-neg-infinity r-second))
            ;; Bullish: price lower low, RSI higher low
            (bull-mag (if (and (< p-min-2 p-min-1) (> r-min-2 r-min-1))
                       (abs (- r-min-2 r-min-1))
                       0.0))
            ;; Bearish: price higher high, RSI lower high
            (bear-mag (if (and (> p-max-2 p-max-1) (< r-max-2 r-max-1))
                       (abs (- r-max-1 r-max-2))
                       0.0)))
        (list bull-mag bear-mag)))))

;; Williams %R
(define (compute-williams-r [high-buf : RingBuffer]
                            [low-buf : RingBuffer]
                            [close : f64])
  : f64
  (let ((highest (rb-max high-buf))
        (lowest (rb-min low-buf))
        (range (- highest lowest)))
    (if (= range 0.0) -50.0 (* (/ (- highest close) range) -100.0))))

;; Parse time from timestamp string
(define (parse-minute [ts : String]) : f64
  ;; Extract minute from ISO format "YYYY-MM-DDTHH:MM:SS"
  (let ((min-str (substring ts 14 16)))
    (+ 0.0 min-str)))

(define (parse-hour [ts : String]) : f64
  (let ((hour-str (substring ts 11 13)))
    (+ 0.0 hour-str)))

(define (parse-day-of-week [ts : String]) : f64
  ;; Simplified — the Rust implementation uses chrono
  0.0)

(define (parse-day-of-month [ts : String]) : f64
  (let ((day-str (substring ts 8 10)))
    (+ 0.0 day-str)))

(define (parse-month [ts : String]) : f64
  (let ((month-str (substring ts 5 7)))
    (+ 0.0 month-str)))

;; ═══════════════════════════════════════════════════════════════════════
;; tick — the full enrichment pipeline
;; ═══════════════════════════════════════════════════════════════════════

(define (tick [bank : IndicatorBank] [raw : RawCandle])
  : Candle
  (let ((open (:open raw))
        (high (:high raw))
        (low (:low raw))
        (close (:close raw))
        (volume (:volume raw))
        (ts (:ts raw)))

    ;; ── Moving averages ───────────────────────────────────────────
    (let ((sma20-val (sma-update (:sma20 bank) close))
          (sma50-val (sma-update (:sma50 bank) close))
          (sma200-val (sma-update (:sma200 bank) close))
          (ema20-val (ema-update (:ema20 bank) close)))

    ;; ── Bollinger ─────────────────────────────────────────────────
    (let ((bb-std (stddev-update (:bb-stddev bank) close))
          (bb-mult 2.0)
          (bb-upper-val (+ sma20-val (* bb-mult bb-std)))
          (bb-lower-val (- sma20-val (* bb-mult bb-std)))
          (bb-width-val (if (= close 0.0) 0.0 (/ (- bb-upper-val bb-lower-val) close)))
          (bb-range (- bb-upper-val bb-lower-val))
          (bb-pos-val (if (= bb-range 0.0) 0.5 (/ (- close bb-lower-val) bb-range))))

    ;; ── Oscillators ───────────────────────────────────────────────
    (let ((rsi-val (rsi-update (:rsi bank) close))
          ((macd-val macd-signal-val macd-hist-val) (macd-update (:macd bank) close))
          ((plus-di-val minus-di-val adx-val) (dmi-update (:dmi bank) high low close))
          (atr-val (atr-update (:atr bank) high low close))
          (atr-r-val (if (= close 0.0) 0.0 (/ atr-val close)))
          ((stoch-k-val stoch-d-val) (stoch-update (:stoch bank) high low close))
          (cci-val (cci-update (:cci bank) high low close))
          (mfi-val (mfi-update (:mfi bank) high low close volume))
          (williams-r-val (compute-williams-r (:high-buf (:stoch bank)) (:low-buf (:stoch bank)) close))
          (obv-val (obv-update (:obv bank) close volume))
          (obv-slope-12-val (linreg-slope (:history (:obv bank))))
          (vol-sma-val (sma-update (:volume-sma20 bank) volume))
          (volume-accel-val (if (= vol-sma-val 0.0) 1.0 (/ volume vol-sma-val))))

    ;; ── ROC ───────────────────────────────────────────────────────
    (let ((roc-buf (:roc-buf bank)))
      (let ((roc-1-val  (if (< (:len roc-buf) 1) 0.0
                          (let ((prev (rb-get roc-buf (- (:len roc-buf) 1))))
                            (if (= prev 0.0) 0.0 (/ (- close prev) prev)))))
            (roc-3-val  (if (< (:len roc-buf) 3) 0.0
                          (let ((prev (rb-get roc-buf (- (:len roc-buf) 3))))
                            (if (= prev 0.0) 0.0 (/ (- close prev) prev)))))
            (roc-6-val  (if (< (:len roc-buf) 6) 0.0
                          (let ((prev (rb-get roc-buf (- (:len roc-buf) 6))))
                            (if (= prev 0.0) 0.0 (/ (- close prev) prev)))))
            (roc-12-val (if (< (:len roc-buf) 12) 0.0
                          (let ((prev (rb-get roc-buf 0)))
                            (if (= prev 0.0) 0.0 (/ (- close prev) prev))))))
      (rb-push roc-buf close)

    ;; ── ATR history and ROC ───────────────────────────────────────
    (let ((atr-hist-buf (:atr-history bank)))
      (rb-push atr-hist-buf atr-val)
      (let ((atr-roc-6-val (if (< (:len atr-hist-buf) 6) 0.0
                             (let ((prev (rb-get atr-hist-buf (- (:len atr-hist-buf) 6))))
                               (if (= prev 0.0) 0.0 (/ (- atr-val prev) prev)))))
            (atr-roc-12-val (if (< (:len atr-hist-buf) 12) 0.0
                              (let ((prev (rb-get atr-hist-buf 0)))
                                (if (= prev 0.0) 0.0 (/ (- atr-val prev) prev))))))

    ;; ── Keltner ───────────────────────────────────────────────────
    (let ((kelt-mult 1.5)
          (kelt-upper-val (+ ema20-val (* kelt-mult atr-val)))
          (kelt-lower-val (- ema20-val (* kelt-mult atr-val)))
          (kelt-range (- kelt-upper-val kelt-lower-val))
          (kelt-pos-val (if (= kelt-range 0.0) 0.5 (/ (- close kelt-lower-val) kelt-range)))
          (kelt-width (if (= close 0.0) 0.0 (/ kelt-range close)))
          (squeeze-val (if (= kelt-width 0.0) 1.0 (/ bb-width-val kelt-width))))

    ;; ── Range position ────────────────────────────────────────────
    (begin
      (rb-push (:range-high-12 bank) high) (rb-push (:range-low-12 bank) low)
      (rb-push (:range-high-24 bank) high) (rb-push (:range-low-24 bank) low)
      (rb-push (:range-high-48 bank) high) (rb-push (:range-low-48 bank) low))
    (let ((range-pos-12-val (compute-range-pos (:range-high-12 bank) (:range-low-12 bank) close))
          (range-pos-24-val (compute-range-pos (:range-high-24 bank) (:range-low-24 bank) close))
          (range-pos-48-val (compute-range-pos (:range-high-48 bank) (:range-low-48 bank) close)))

    ;; ── Trend consistency ─────────────────────────────────────────
    (let ((trend-dir (if (> close (:prev-close bank)) 1.0 0.0)))
      (rb-push (:trend-buf-24 bank) trend-dir)
      (let ((trend-consistency-6-val (compute-trend-consistency (:trend-buf-24 bank) 6))
            (trend-consistency-12-val (compute-trend-consistency (:trend-buf-24 bank) 12))
            (trend-consistency-24-val (compute-trend-consistency (:trend-buf-24 bank) 24)))

    ;; ── Multi-timeframe ───────────────────────────────────────────
    (begin
      (rb-push (:tf-1h-buf bank) close)
      (rb-push (:tf-1h-high bank) high)
      (rb-push (:tf-1h-low bank) low)
      (rb-push (:tf-4h-buf bank) close)
      (rb-push (:tf-4h-high bank) high)
      (rb-push (:tf-4h-low bank) low))
    (let ((tf-1h-close-val (if (rb-full? (:tf-1h-buf bank))
                             (rb-newest (:tf-1h-buf bank)) close))
          (tf-1h-high-val (rb-max (:tf-1h-high bank)))
          (tf-1h-low-val (rb-min (:tf-1h-low bank)))
          (tf-1h-open (rb-oldest (:tf-1h-buf bank)))
          (tf-1h-ret-val (if (= tf-1h-open 0.0) 0.0 (/ (- tf-1h-close-val tf-1h-open) tf-1h-open)))
          (tf-1h-range (- tf-1h-high-val tf-1h-low-val))
          (tf-1h-body-val (if (= tf-1h-range 0.0) 0.0
                            (/ (abs (- tf-1h-close-val tf-1h-open)) tf-1h-range)))
          (tf-4h-close-val (if (rb-full? (:tf-4h-buf bank))
                             (rb-newest (:tf-4h-buf bank)) close))
          (tf-4h-high-val (rb-max (:tf-4h-high bank)))
          (tf-4h-low-val (rb-min (:tf-4h-low bank)))
          (tf-4h-open (rb-oldest (:tf-4h-buf bank)))
          (tf-4h-ret-val (if (= tf-4h-open 0.0) 0.0 (/ (- tf-4h-close-val tf-4h-open) tf-4h-open)))
          (tf-4h-range (- tf-4h-high-val tf-4h-low-val))
          (tf-4h-body-val (if (= tf-4h-range 0.0) 0.0
                            (/ (abs (- tf-4h-close-val tf-4h-open)) tf-4h-range))))

    ;; ── Timeframe agreement ───────────────────────────────────────
    (let ((five-min-dir (signum (- close (:prev-close bank))))
          (one-h-dir (signum tf-1h-ret-val))
          (four-h-dir (signum tf-4h-ret-val))
          ;; Agreement: +1 if all same sign, -1 if mixed, 0 if neutral
          (agreement-sum (+ five-min-dir one-h-dir four-h-dir))
          (tf-agreement-val (/ agreement-sum 3.0)))

    ;; ── Ichimoku ──────────────────────────────────────────────────
    (let ((ichi (:ichimoku bank)))
      (begin
        (rb-push (:high-9 ichi) high)  (rb-push (:low-9 ichi) low)
        (rb-push (:high-26 ichi) high) (rb-push (:low-26 ichi) low)
        (rb-push (:high-52 ichi) high) (rb-push (:low-52 ichi) low))
      (let ((tenkan-val (/ (+ (rb-max (:high-9 ichi)) (rb-min (:low-9 ichi))) 2.0))
            (kijun-val (/ (+ (rb-max (:high-26 ichi)) (rb-min (:low-26 ichi))) 2.0))
            (senkou-a-val (/ (+ tenkan-val kijun-val) 2.0))
            (senkou-b-val (/ (+ (rb-max (:high-52 ichi)) (rb-min (:low-52 ichi))) 2.0))
            (cloud-top-val (max senkou-a-val senkou-b-val))
            (cloud-bottom-val (min senkou-a-val senkou-b-val))
            ;; TK cross delta
            (tk-spread (- tenkan-val kijun-val))
            (tk-cross-delta-val (- tk-spread (:prev-tk-spread bank))))
      (set! bank :prev-tk-spread tk-spread)

    ;; ── Stochastic cross delta ────────────────────────────────────
    (let ((stoch-kd (- stoch-k-val stoch-d-val))
          (stoch-cross-delta-val (- stoch-kd (:prev-stoch-kd bank))))
      (set! bank :prev-stoch-kd stoch-kd)

    ;; ── Persistence ───────────────────────────────────────────────
    (rb-push (:close-buf-48 bank) close)
    (let ((close-values (rb-to-list (:close-buf-48 bank)))
          (hurst-val (compute-hurst close-values))
          (autocorrelation-val (compute-autocorrelation close-values)))

    ;; ── VWAP ──────────────────────────────────────────────────────
    (set! bank :vwap-cum-vol (+ (:vwap-cum-vol bank) volume))
    (set! bank :vwap-cum-pv (+ (:vwap-cum-pv bank) (* close volume)))
    (let ((vwap (if (= (:vwap-cum-vol bank) 0.0) close
                  (/ (:vwap-cum-pv bank) (:vwap-cum-vol bank))))
          (vwap-distance-val (if (= close 0.0) 0.0 (/ (- close vwap) close))))

    ;; ── Regime ────────────────────────────────────────────────────
    (rb-push (:kama-er-buf bank) close)
    (let ((kama-er-val (compute-kama-er (:kama-er-buf bank))))

    ;; Choppiness
    (let ((old-chop-atr (if (rb-full? (:chop-buf bank))
                          (rb-oldest (:chop-buf bank))
                          0.0)))
      (set! bank :chop-atr-sum (+ (- (:chop-atr-sum bank) old-chop-atr) atr-val))
      (rb-push (:chop-buf bank) atr-val)
      (let ((choppiness-val (compute-choppiness (:chop-atr-sum bank)
                              (:range-high-12 bank) (:range-low-12 bank))))

    ;; DFA, variance ratio, entropy
    (rb-push (:dfa-buf bank) close)
    (rb-push (:var-ratio-buf bank) close)
    (rb-push (:entropy-buf bank) close)
    (let ((dfa-alpha-val (compute-dfa-alpha (rb-to-list (:dfa-buf bank))))
          (variance-ratio-val (compute-variance-ratio (rb-to-list (:var-ratio-buf bank))))
          (entropy-rate-val (compute-entropy-rate (rb-to-list (:entropy-buf bank)))))

    ;; Aroon
    (rb-push (:aroon-high-buf bank) high)
    (rb-push (:aroon-low-buf bank) low)
    (let ((aroon-up-val (compute-aroon (:aroon-high-buf bank)))
          (aroon-down-val (compute-aroon-down (:aroon-low-buf bank))))

    ;; Fractal dimension
    (rb-push (:fractal-buf bank) close)
    (let ((fractal-dim-val (compute-fractal-dim (rb-to-list (:fractal-buf bank)))))

    ;; ── Divergence ────────────────────────────────────────────────
    (rb-push (:rsi-peak-buf bank) rsi-val)
    (rb-push (:price-peak-buf bank) close)
    (let (((rsi-div-bull rsi-div-bear) (compute-rsi-divergence
                                          (:price-peak-buf bank)
                                          (:rsi-peak-buf bank))))

    ;; ── Price action ──────────────────────────────────────────────
    (let ((current-range (- high low))
          (range-ratio-val (if (= (:prev-range bank) 0.0) 1.0
                            (/ current-range (:prev-range bank))))
          (gap-val (if (= (:prev-close bank) 0.0) 0.0
                    (/ (- open (:prev-close bank)) (:prev-close bank)))))
      (set! bank :prev-range current-range)
      ;; Consecutive runs
      (if (> close open)
        (begin
          (inc! bank :consecutive-up-count)
          (set! bank :consecutive-down-count 0))
        (if (< close open)
          (begin
            (set! bank :consecutive-up-count 0)
            (inc! bank :consecutive-down-count))
          (begin)))
      (let ((consecutive-up-val (+ 0.0 (:consecutive-up-count bank)))
            (consecutive-down-val (+ 0.0 (:consecutive-down-count bank))))

    ;; ── Time ──────────────────────────────────────────────────────
    (let ((minute-val (parse-minute ts))
          (hour-val (parse-hour ts))
          (dow-val (parse-day-of-week ts))
          (dom-val (parse-day-of-month ts))
          (moy-val (parse-month ts)))

    ;; ── Update bank state ─────────────────────────────────────────
    (set! bank :prev-close close)
    (set! bank :prev-tf-1h-ret tf-1h-ret-val)
    (set! bank :prev-tf-4h-ret tf-4h-ret-val)
    (inc! bank :count)

    ;; ── Construct the enriched candle ─────────────────────────────
    (candle
      ts open high low close volume
      sma20-val sma50-val sma200-val
      bb-upper-val bb-lower-val bb-width-val bb-pos-val
      rsi-val macd-val macd-signal-val macd-hist-val
      plus-di-val minus-di-val adx-val atr-val atr-r-val
      stoch-k-val stoch-d-val williams-r-val cci-val mfi-val
      obv-slope-12-val volume-accel-val
      kelt-upper-val kelt-lower-val kelt-pos-val squeeze-val
      roc-1-val roc-3-val roc-6-val roc-12-val
      atr-roc-6-val atr-roc-12-val
      trend-consistency-6-val trend-consistency-12-val trend-consistency-24-val
      range-pos-12-val range-pos-24-val range-pos-48-val
      tf-1h-close-val tf-1h-high-val tf-1h-low-val tf-1h-ret-val tf-1h-body-val
      tf-4h-close-val tf-4h-high-val tf-4h-low-val tf-4h-ret-val tf-4h-body-val
      tenkan-val kijun-val senkou-a-val senkou-b-val cloud-top-val cloud-bottom-val
      hurst-val autocorrelation-val vwap-distance-val
      kama-er-val choppiness-val dfa-alpha-val variance-ratio-val entropy-rate-val
      aroon-up-val aroon-down-val fractal-dim-val
      rsi-div-bull rsi-div-bear
      tk-cross-delta-val stoch-cross-delta-val
      range-ratio-val gap-val consecutive-up-val consecutive-down-val
      tf-agreement-val
      minute-val hour-val dow-val dom-val moy-val)

    )))))))))))))))))))))))))))
