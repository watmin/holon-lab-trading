;; indicator-bank.wat — streaming state machine. Advances all indicators by one raw candle.
;; Depends on: raw-candle, candle

(require primitives)
(require raw-candle)
(require candle)

;; ── Streaming primitives ────────────────────────────────────────────

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
  ;; idx 0 is the oldest element
  (let ((pos (mod (+ (- (:head rb) (:len rb)) idx (:capacity rb)) (:capacity rb))))
    (nth (:data rb) pos)))

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
  (fold (lambda (acc i) (max acc (rb-get rb i)))
        f64-neg-infinity
        (range 0 (:len rb))))

(define (rb-min [rb : RingBuffer])
  : f64
  (fold (lambda (acc i) (min acc (rb-get rb i)))
        f64-infinity
        (range 0 (:len rb))))

(define (rb-to-list [rb : RingBuffer])
  : Vec<f64>
  (map (lambda (i) (rb-get rb i)) (range 0 (:len rb))))

;; ── EMA state ───────────────────────────────────────────────────────

(struct ema-state
  [value     : f64]
  [smoothing : f64]
  [period    : usize]
  [count     : usize]
  [accum     : f64])

(define (make-ema-state [period : usize])
  : EmaState
  (ema-state 0.0 (/ 2.0 (+ period 1.0)) period 0 0.0))

(define (ema-update [ema : EmaState] [value : f64])
  : f64
  (inc! ema :count)
  (if (<= (:count ema) (:period ema))
    ;; Accumulate for initial SMA seed
    (begin
      (set! ema :accum (+ (:accum ema) value))
      (if (= (:count ema) (:period ema))
        (let ((seed (/ (:accum ema) (+ (:period ema) 0.0))))
          (set! ema :value seed)
          seed)
        (begin
          (set! ema :value value)
          value)))
    ;; Standard EMA
    (let ((new-val (+ (* (:smoothing ema) value)
                      (* (- 1.0 (:smoothing ema)) (:value ema)))))
      (set! ema :value new-val)
      new-val)))

;; ── Wilder state ────────────────────────────────────────────────────

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
  (inc! ws :count)
  (if (<= (:count ws) (:period ws))
    ;; Accumulate for initial average
    (begin
      (set! ws :accum (+ (:accum ws) value))
      (if (= (:count ws) (:period ws))
        (let ((seed (/ (:accum ws) (+ (:period ws) 0.0))))
          (set! ws :value seed)
          seed)
        (begin
          (set! ws :value 0.0)
          0.0)))
    ;; Wilder smoothing: prev × (period - 1) / period + value / period
    (let ((p (+ (:period ws) 0.0))
          (new-val (+ (/ (* (:value ws) (- p 1.0)) p) (/ value p))))
      (set! ws :value new-val)
      new-val)))

;; ── RSI state ───────────────────────────────────────────────────────

(struct rsi-state
  [gain-smoother : WilderState]
  [loss-smoother : WilderState]
  [prev-close    : f64]
  [started       : bool])

(define (make-rsi-state)
  : RsiState
  (rsi-state (make-wilder-state 14) (make-wilder-state 14) 0.0 false))

(define (rsi-update [rsi : RsiState] [close : f64])
  : f64
  (if (not (:started rsi))
    (begin
      (set! rsi :prev-close close)
      (set! rsi :started true)
      50.0)  ; neutral until we have data
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

;; ── ATR state ───────────────────────────────────────────────────────

(struct atr-state
  [wilder     : WilderState]
  [prev-close : f64]
  [started    : bool])

(define (make-atr-state)
  : AtrState
  (atr-state (make-wilder-state 14) 0.0 false))

(define (atr-update [atr : AtrState] [high : f64] [low : f64] [close : f64])
  : f64
  (if (not (:started atr))
    (begin
      (set! atr :prev-close close)
      (set! atr :started true)
      (- high low))
    (let ((tr (max (- high low)
                   (max (abs (- high (:prev-close atr)))
                        (abs (- low (:prev-close atr))))))
          (result (wilder-update (:wilder atr) tr)))
      (set! atr :prev-close close)
      result)))

;; ── OBV state ───────────────────────────────────────────────────────

(struct obv-state
  [obv        : f64]
  [prev-close : f64]
  [history    : RingBuffer]
  [started    : bool])

(define (make-obv-state)
  : ObvState
  (obv-state 0.0 0.0 (make-ring-buffer 12) false))

(define (obv-update [obv-st : ObvState] [close : f64] [volume : f64])
  : f64
  (if (not (:started obv-st))
    (begin
      (set! obv-st :prev-close close)
      (set! obv-st :started true)
      (rb-push (:history obv-st) 0.0)
      0.0)
    (let ((new-obv (cond
                     ((> close (:prev-close obv-st)) (+ (:obv obv-st) volume))
                     ((< close (:prev-close obv-st)) (- (:obv obv-st) volume))
                     (else (:obv obv-st)))))
      (set! obv-st :obv new-obv)
      (set! obv-st :prev-close close)
      (rb-push (:history obv-st) new-obv)
      new-obv)))

;; ── SMA state ───────────────────────────────────────────────────────
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
    (when (rb-full? buf)
      (set! sma :sum (- (:sum sma) (rb-oldest buf))))
    (set! sma :sum (+ (:sum sma) value))
    (rb-push buf value)
    (/ (:sum sma) (+ (:len buf) 0.0))))

;; ── Rolling stddev ──────────────────────────────────────────────────
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
    (let ((n (+ (:len buf) 0.0))
          (mean (/ (:sum rs) n))
          (variance (- (/ (:sum-sq rs) n) (* mean mean))))
      (sqrt (max variance 0.0)))))

;; ── Stochastic state ────────────────────────────────────────────────

(struct stoch-state
  [high-buf : RingBuffer]
  [low-buf  : RingBuffer]
  [k-buf    : RingBuffer])

(define (make-stoch-state)
  : StochState
  (stoch-state (make-ring-buffer 14) (make-ring-buffer 14) (make-ring-buffer 3)))

(define (stoch-update [st : StochState] [high : f64] [low : f64] [close : f64])
  : (f64, f64)  ; (%K, %D)
  (rb-push (:high-buf st) high)
  (rb-push (:low-buf st) low)
  (let ((highest (rb-max (:high-buf st)))
        (lowest (rb-min (:low-buf st)))
        (range (- highest lowest))
        (k (if (= range 0.0) 50.0 (* (/ (- close lowest) range) 100.0))))
    (rb-push (:k-buf st) k)
    ;; %D = SMA(3) of %K
    (let ((d (/ (fold + 0.0 (rb-to-list (:k-buf st)))
                (+ (:len (:k-buf st)) 0.0))))
      (list k d))))

;; ── CCI state ───────────────────────────────────────────────────────

(struct cci-state
  [tp-buf : RingBuffer]
  [tp-sma : SmaState])

(define (make-cci-state)
  : CciState
  (cci-state (make-ring-buffer 20) (make-sma-state 20)))

(define (cci-update [cci : CciState] [high : f64] [low : f64] [close : f64])
  : f64
  (let ((tp (/ (+ high low close) 3.0))
        (sma-val (sma-update (:tp-sma cci) tp)))
    (rb-push (:tp-buf cci) tp)
    ;; Mean deviation
    (let ((values (rb-to-list (:tp-buf cci)))
          (mean-dev (/ (fold (lambda (acc v) (+ acc (abs (- v sma-val)))) 0.0 values)
                       (+ (length values) 0.0))))
      (if (= mean-dev 0.0)
        0.0
        (/ (- tp sma-val) (* 0.015 mean-dev))))))

;; ── MFI state ───────────────────────────────────────────────────────

(struct mfi-state
  [pos-flow-buf : RingBuffer]
  [neg-flow-buf : RingBuffer]
  [prev-tp      : f64]
  [started      : bool])

(define (make-mfi-state)
  : MfiState
  (mfi-state (make-ring-buffer 14) (make-ring-buffer 14) 0.0 false))

(define (mfi-update [mfi : MfiState] [high : f64] [low : f64] [close : f64] [volume : f64])
  : f64
  (let ((tp (/ (+ high low close) 3.0))
        (raw-mf (* tp volume)))
    (if (not (:started mfi))
      (begin
        (set! mfi :prev-tp tp)
        (set! mfi :started true)
        (rb-push (:pos-flow-buf mfi) 0.0)
        (rb-push (:neg-flow-buf mfi) 0.0)
        50.0)
      (begin
        (if (> tp (:prev-tp mfi))
          (begin
            (rb-push (:pos-flow-buf mfi) raw-mf)
            (rb-push (:neg-flow-buf mfi) 0.0))
          (begin
            (rb-push (:pos-flow-buf mfi) 0.0)
            (rb-push (:neg-flow-buf mfi) raw-mf)))
        (set! mfi :prev-tp tp)
        (let ((pos-sum (fold + 0.0 (rb-to-list (:pos-flow-buf mfi))))
              (neg-sum (fold + 0.0 (rb-to-list (:neg-flow-buf mfi)))))
          (if (= neg-sum 0.0)
            100.0
            (let ((mfr (/ pos-sum neg-sum)))
              (- 100.0 (/ 100.0 (+ 1.0 mfr))))))))))

;; ── Ichimoku state ──────────────────────────────────────────────────

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

(define (ichimoku-update [ich : IchimokuState] [high : f64] [low : f64])
  : (f64, f64, f64, f64, f64, f64)  ; tenkan, kijun, span-a, span-b, cloud-top, cloud-bottom
  (rb-push (:high-9 ich) high)   (rb-push (:low-9 ich) low)
  (rb-push (:high-26 ich) high)  (rb-push (:low-26 ich) low)
  (rb-push (:high-52 ich) high)  (rb-push (:low-52 ich) low)
  (let ((tenkan (/ (+ (rb-max (:high-9 ich)) (rb-min (:low-9 ich))) 2.0))
        (kijun  (/ (+ (rb-max (:high-26 ich)) (rb-min (:low-26 ich))) 2.0))
        (span-a (/ (+ tenkan kijun) 2.0))
        (span-b (/ (+ (rb-max (:high-52 ich)) (rb-min (:low-52 ich))) 2.0))
        (ct (max span-a span-b))
        (cb (min span-a span-b)))
    (list tenkan kijun span-a span-b ct cb)))

;; ── MACD state ──────────────────────────────────────────────────────

(struct macd-state
  [fast-ema   : EmaState]
  [slow-ema   : EmaState]
  [signal-ema : EmaState])

(define (make-macd-state)
  : MacdState
  (macd-state (make-ema-state 12) (make-ema-state 26) (make-ema-state 9)))

(define (macd-update [m : MacdState] [close : f64])
  : (f64, f64, f64)  ; macd, signal, histogram
  (let ((fast (ema-update (:fast-ema m) close))
        (slow (ema-update (:slow-ema m) close))
        (macd-val (- fast slow))
        (signal (ema-update (:signal-ema m) macd-val))
        (hist (- macd-val signal)))
    (list macd-val signal hist)))

;; ── DMI state ───────────────────────────────────────────────────────
;; period is implicit in the WilderState smoothers — one source of truth.

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

(define (dmi-update [dmi : DmiState] [high : f64] [low : f64] [close : f64])
  : (f64, f64, f64)  ; +DI, -DI, ADX
  (if (not (:started dmi))
    (begin
      (set! dmi :prev-high high)
      (set! dmi :prev-low low)
      (set! dmi :prev-close close)
      (set! dmi :started true)
      (list 0.0 0.0 0.0))
    (let ((up-move (- high (:prev-high dmi)))
          (down-move (- (:prev-low dmi) low))
          (plus-dm (if (and (> up-move down-move) (> up-move 0.0)) up-move 0.0))
          (minus-dm (if (and (> down-move up-move) (> down-move 0.0)) down-move 0.0))
          (tr (max (- high low)
                   (max (abs (- high (:prev-close dmi)))
                        (abs (- low (:prev-close dmi))))))
          (smoothed-plus (wilder-update (:plus-smoother dmi) plus-dm))
          (smoothed-minus (wilder-update (:minus-smoother dmi) minus-dm))
          (smoothed-tr (wilder-update (:tr-smoother dmi) tr))
          (plus-di (if (= smoothed-tr 0.0) 0.0 (* 100.0 (/ smoothed-plus smoothed-tr))))
          (minus-di (if (= smoothed-tr 0.0) 0.0 (* 100.0 (/ smoothed-minus smoothed-tr))))
          (di-sum (+ plus-di minus-di))
          (dx (if (= di-sum 0.0) 0.0 (* 100.0 (/ (abs (- plus-di minus-di)) di-sum)))))
      (set! dmi :prev-high high)
      (set! dmi :prev-low low)
      (set! dmi :prev-close close)
      (inc! dmi :count)
      (let ((adx-val (wilder-update (:adx-smoother dmi) dx)))
        (list plus-di minus-di adx-val)))))

;; ── Indicator Bank ──────────────────────────────────────────────────

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
  ;; Ichimoku cross delta
  [prev-tk-spread : f64]
  ;; Stochastic cross delta
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
    ;; Trend consistency
    (make-ring-buffer 24)
    ;; ATR history
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
    (make-ring-buffer 10)    ; kama-er: 10-period
    0.0                      ; chop-atr-sum
    (make-ring-buffer 14)    ; chop: 14-period
    (make-ring-buffer 48)    ; dfa: 48-period
    (make-ring-buffer 30)    ; variance-ratio: 30-period
    (make-ring-buffer 30)    ; entropy: 30-period
    (make-ring-buffer 25)    ; aroon-high: 25-period
    (make-ring-buffer 25)    ; aroon-low: 25-period
    (make-ring-buffer 30)    ; fractal: 30-period
    ;; Divergence
    (make-ring-buffer 14)    ; rsi-peak
    (make-ring-buffer 14)    ; price-peak
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

;; ── Linear regression slope ─────────────────────────────────────────

(define (linreg-slope [values : Vec<f64>])
  : f64
  (let ((n (length values)))
    (if (< n 2) 0.0
      (let ((n-f (+ n 0.0))
            (sum-x (/ (* n-f (- n-f 1.0)) 2.0))
            (sum-y (fold + 0.0 values))
            (sum-xy (fold (lambda (acc i) (+ acc (* (+ i 0.0) (nth values i))))
                          0.0 (range 0 n)))
            (sum-xx (/ (* n-f (- n-f 1.0) (- (* 2.0 n-f) 1.0)) 6.0))
            (denom (- (* n-f sum-xx) (* sum-x sum-x))))
        (if (= denom 0.0) 0.0
          (/ (- (* n-f sum-xy) (* sum-x sum-y)) denom))))))

;; ── Hurst exponent (R/S analysis) ───────────────────────────────────

(define (compute-hurst [values : Vec<f64>])
  : f64
  (let ((n (length values)))
    (if (< n 8) 0.5
      (let ((returns (map (lambda (i) (- (nth values i) (nth values (- i 1))))
                          (range 1 n)))
            (m (/ (fold + 0.0 returns) (+ (length returns) 0.0)))
            (devs (map (lambda (r) (- r m)) returns))
            ;; Cumulative deviations
            (cum-devs (fold-left (lambda (acc d)
                        (let ((prev (if (empty? acc) 0.0 (last acc))))
                          (append acc (list (+ prev d)))))
                        '() devs))
            (range-val (- (fold max f64-neg-infinity cum-devs)
                          (fold min f64-infinity cum-devs)))
            (s (sqrt (/ (fold (lambda (a d) (+ a (* d d))) 0.0 devs)
                        (+ (length devs) 0.0)))))
        (if (= s 0.0) 0.5
          ;; Simplified: H ≈ log(R/S) / log(n)
          (let ((rs (/ range-val s)))
            (/ (ln (max rs 1.0)) (ln (+ n 0.0)))))))))

;; ── Autocorrelation (lag-1) ─────────────────────────────────────────

(define (compute-autocorrelation [values : Vec<f64>])
  : f64
  (let ((n (length values)))
    (if (< n 3) 0.0
      (let ((m (/ (fold + 0.0 values) (+ n 0.0)))
            (var (/ (fold (lambda (a v) (+ a (* (- v m) (- v m)))) 0.0 values)
                    (+ n 0.0))))
        (if (= var 0.0) 0.0
          (let ((cov (/ (fold (lambda (a i)
                          (+ a (* (- (nth values i) m) (- (nth values (- i 1)) m))))
                        0.0 (range 1 n))
                        (+ n 0.0))))
            (/ cov var)))))))

;; ── KAMA Efficiency Ratio ───────────────────────────────────────────

(define (compute-kama-er [values : Vec<f64>])
  : f64
  (let ((n (length values)))
    (if (< n 2) 0.0
      (let ((direction (abs (- (last values) (first values))))
            (volatility (fold (lambda (a i)
                          (+ a (abs (- (nth values i) (nth values (- i 1))))))
                        0.0 (range 1 n))))
        (if (= volatility 0.0) 0.0
          (/ direction volatility))))))

;; ── Choppiness Index ────────────────────────────────────────────────

(define (compute-choppiness [atr-sum : f64] [high-buf : RingBuffer] [low-buf : RingBuffer] [n : usize])
  : f64
  (if (< n 2) 50.0
    (let ((highest (rb-max high-buf))
          (lowest (rb-min low-buf))
          (range-val (- highest lowest)))
      (if (= range-val 0.0) 50.0
        (* 100.0 (/ (ln (/ atr-sum range-val)) (ln (+ n 0.0))))))))

;; ── DFA alpha ───────────────────────────────────────────────────────

(define (compute-dfa-alpha [values : Vec<f64>])
  : f64
  ;; Simplified detrended fluctuation analysis
  (let ((n (length values)))
    (if (< n 8) 0.5
      (let ((m (/ (fold + 0.0 values) (+ n 0.0)))
            ;; Integrate
            (integrated (fold-left (lambda (acc v)
                          (let ((prev (if (empty? acc) 0.0 (last acc))))
                            (append acc (list (+ prev (- v m))))))
                        '() values))
            ;; Detrend and compute fluctuation at scale n/4
            (scale (max 4 (/ n 4)))
            (n-segments (/ n scale))
            (fluctuations
              (map (lambda (seg)
                (let ((start (* seg scale))
                      (segment (take (last-n integrated (- n start)) scale))
                      ;; Linear detrend: subtract line from first to last
                      (y0 (first segment))
                      (y1 (last segment))
                      (detrended (map (lambda (i)
                                   (let ((trend (+ y0 (* (/ (- y1 y0) (+ scale 0.0)) (+ i 0.0)))))
                                     (- (nth segment i) trend)))
                                 (range 0 (min scale (length segment))))))
                  (sqrt (/ (fold (lambda (a d) (+ a (* d d))) 0.0 detrended)
                           (+ (length detrended) 0.0)))))
              (range 0 (max 1 n-segments)))))
        ;; Alpha ~ mean fluctuation ratio
        (let ((mean-f (/ (fold + 0.0 fluctuations) (+ (length fluctuations) 0.0))))
          (if (= mean-f 0.0) 0.5
            (/ (ln (max mean-f 0.001)) (ln (+ scale 0.0)))))))))

;; ── Variance ratio ──────────────────────────────────────────────────

(define (compute-variance-ratio [values : Vec<f64>])
  : f64
  (let ((n (length values)))
    (if (< n 4) 1.0
      (let ((returns-1 (map (lambda (i) (- (nth values i) (nth values (- i 1))))
                            (range 1 n)))
            (var-1 (/ (fold (lambda (a r) (+ a (* r r))) 0.0 returns-1)
                      (+ (length returns-1) 0.0)))
            ;; Scale 2
            (returns-2 (map (lambda (i) (- (nth values i) (nth values (- i 2))))
                            (range 2 n)))
            (var-2 (/ (fold (lambda (a r) (+ a (* r r))) 0.0 returns-2)
                      (+ (length returns-2) 0.0))))
        (if (= var-1 0.0) 1.0
          (/ var-2 (* 2.0 var-1)))))))

;; ── Entropy rate ────────────────────────────────────────────────────

(define (compute-entropy-rate [values : Vec<f64>])
  : f64
  (let ((n (length values)))
    (if (< n 3) 0.0
      ;; Discretize returns into bins: -2, -1, 0, +1, +2
      (let ((returns (map (lambda (i) (- (nth values i) (nth values (- i 1))))
                          (range 1 n)))
            (std (sqrt (/ (fold (lambda (a r) (+ a (* r r))) 0.0 returns)
                          (+ (length returns) 0.0))))
            (bins (map (lambda (r)
                    (if (= std 0.0) 0
                      (clamp (round (/ r (max std 0.0001))) -2 2)))
                  returns))
            ;; Count transitions
            (n-trans (- (length bins) 1))
            (pairs (map (lambda (i) (list (nth bins i) (nth bins (+ i 1))))
                        (range 0 n-trans))))
        ;; Conditional entropy: H(X_t | X_{t-1})
        ;; Simplified: count unique pairs / total
        (let ((unique-count (length (sort (filter-map (lambda (p)
                              (Some (+ (* (+ (first p) 3) 10) (+ (second p) 3))))
                            pairs)))))
          ;; Normalize
          (if (= n-trans 0) 0.0
            (/ (ln (max (+ unique-count 0.0) 1.0)) (ln (+ n-trans 0.0)))))))))

;; ── Fractal dimension ───────────────────────────────────────────────

(define (compute-fractal-dim [values : Vec<f64>])
  : f64
  (let ((n (length values)))
    (if (< n 4) 1.5
      ;; Higuchi method simplified
      (let ((k-max (min 4 (/ n 2)))
            (lengths (map (lambda (k)
              (let ((num-segments (/ (- n 1) k))
                    (seg-length (if (= num-segments 0) 0.0
                      (/ (fold (lambda (a m)
                           (+ a (abs (- (nth values (min (+ m k) (- n 1)))
                                        (nth values m)))))
                         0.0
                         (range 0 (* num-segments k) k))
                         (* num-segments (+ k 0.0))))))
                (list (ln (+ k 0.0)) (ln (max seg-length 0.0001)))))
            (range 1 (+ k-max 1)))))
        ;; Slope of log-log plot ≈ -D
        (let ((slope (linreg-slope (map second lengths))))
          (clamp (abs slope) 1.0 2.0))))))

;; ── RSI divergence (PELT peak detection) ────────────────────────────

(define (compute-rsi-divergence [price-buf : RingBuffer] [rsi-buf : RingBuffer])
  : (f64, f64)  ; (bull-magnitude, bear-magnitude)
  (let ((n (min (:len price-buf) (:len rsi-buf))))
    (if (< n 4) (list 0.0 0.0)
      (let ((prices (map (lambda (i) (rb-get price-buf i)) (range 0 n)))
            (rsis (map (lambda (i) (rb-get rsi-buf i)) (range 0 n)))
            ;; Find local extremes (simplified peak detection)
            (price-slope (linreg-slope prices))
            (rsi-slope (linreg-slope rsis))
            ;; Bull divergence: price going down, RSI going up
            (bull-mag (if (and (< price-slope 0.0) (> rsi-slope 0.0))
                       (abs (- rsi-slope price-slope))
                       0.0))
            ;; Bear divergence: price going up, RSI going down
            (bear-mag (if (and (> price-slope 0.0) (< rsi-slope 0.0))
                       (abs (- price-slope rsi-slope))
                       0.0)))
        (list bull-mag bear-mag)))))

;; ── Trend consistency ───────────────────────────────────────────────

(define (compute-trend-consistency [buf : RingBuffer] [window : usize])
  : f64
  (let ((n (min (:len buf) window)))
    (if (< n 2) 0.5
      (let ((up-count (fold (lambda (acc i)
                        (if (> (rb-get buf i) (rb-get buf (- i 1)))
                          (+ acc 1)
                          acc))
                      0 (range 1 n))))
        (/ (+ up-count 0.0) (+ (- n 1) 0.0))))))

;; ── Range position ──────────────────────────────────────────────────

(define (compute-range-pos [close : f64] [high-buf : RingBuffer] [low-buf : RingBuffer])
  : f64
  (let ((highest (rb-max high-buf))
        (lowest (rb-min low-buf))
        (range-val (- highest lowest)))
    (if (= range-val 0.0) 0.5
      (/ (- close lowest) range-val))))

;; ── ROC (Rate of Change) ────────────────────────────────────────────

(define (compute-roc [buf : RingBuffer] [period : usize])
  : f64
  (let ((n (:len buf)))
    (if (< n (+ period 1)) 0.0
      (let ((current (rb-newest buf))
            (past (rb-get buf (- n 1 period))))
        (if (= past 0.0) 0.0
          (/ (- current past) (abs past)))))))

;; ── Multi-timeframe aggregation ─────────────────────────────────────

(define (compute-tf-aggregate [buf : RingBuffer] [high-buf : RingBuffer] [low-buf : RingBuffer])
  : (f64, f64, f64, f64, f64)  ; close, high, low, return, body-ratio
  (if (< (:len buf) 2)
    (list 0.0 0.0 0.0 0.0 0.0)
    (let ((tf-close (rb-newest buf))
          (tf-high (rb-max high-buf))
          (tf-low (rb-min low-buf))
          (tf-open (rb-oldest buf))
          (tf-ret (if (= tf-open 0.0) 0.0 (/ (- tf-close tf-open) tf-open)))
          (tf-range (- tf-high tf-low))
          (tf-body (abs (- tf-close tf-open)))
          (body-ratio (if (= tf-range 0.0) 0.0 (/ tf-body tf-range))))
      (list tf-close tf-high tf-low tf-ret body-ratio))))

;; ── Aroon ───────────────────────────────────────────────────────────

(define (compute-aroon [buf : RingBuffer])
  : f64  ; aroon value for this buffer (high or low)
  (let ((n (:len buf)))
    (if (< n 2) 50.0
      (let ((period (- n 1))
            ;; Find index of max/min (for aroon-up use high-buf, for aroon-down use low-buf)
            (extreme-idx
              (fold (lambda (best-idx i)
                (if (>= (rb-get buf i) (rb-get buf best-idx)) i best-idx))
                0 (range 0 n)))
            (periods-since (- (- n 1) extreme-idx)))
        (* 100.0 (/ (- (+ period 0.0) (+ periods-since 0.0)) (+ period 0.0)))))))

(define (compute-aroon-down [buf : RingBuffer])
  : f64
  (let ((n (:len buf)))
    (if (< n 2) 50.0
      (let ((period (- n 1))
            (extreme-idx
              (fold (lambda (best-idx i)
                (if (<= (rb-get buf i) (rb-get buf best-idx)) i best-idx))
                0 (range 0 n)))
            (periods-since (- (- n 1) extreme-idx)))
        (* 100.0 (/ (- (+ period 0.0) (+ periods-since 0.0)) (+ period 0.0)))))))

;; ── Parse time from timestamp ───────────────────────────────────────

(define (parse-minute [ts : String])  : f64 (+ 0.0 (substring ts 14 16)))
(define (parse-hour [ts : String])    : f64 (+ 0.0 (substring ts 11 13)))
;; day-of-week, day-of-month, month-of-year parsed from ISO 8601

(define (parse-day-of-month [ts : String]) : f64 (+ 0.0 (substring ts 8 10)))
(define (parse-month [ts : String])        : f64 (+ 0.0 (substring ts 5 7)))

;; day-of-week requires full date calculation — simplified Zeller-like
(define (parse-day-of-week [ts : String])
  : f64
  (let ((y (+ 0.0 (substring ts 0 4)))
        (m (+ 0.0 (substring ts 5 7)))
        (d (+ 0.0 (substring ts 8 10)))
        ;; Tomohiko Sakamoto's algorithm
        (adj-m (if (< m 3) (+ m 12) m))
        (adj-y (if (< m 3) (- y 1) y))
        (dow (mod (+ d
                     (/ (* 13 (+ adj-m 1)) 5)
                     adj-y
                     (/ adj-y 4)
                     (- (/ adj-y 100))
                     (/ adj-y 400))
                  7)))
    (+ dow 0.0)))

;; ── The tick function — the full indicator bank update ───────────────

(define (tick [bank : IndicatorBank] [raw : RawCandle])
  : Candle
  (let ((open (:open raw))
        (high (:high raw))
        (low (:low raw))
        (close (:close raw))
        (volume (:volume raw))
        (ts (:ts raw)))

    ;; Moving averages
    (let ((sma20-val (sma-update (:sma20 bank) close))
          (sma50-val (sma-update (:sma50 bank) close))
          (sma200-val (sma-update (:sma200 bank) close))
          (ema20-val (ema-update (:ema20 bank) close)))

      ;; Bollinger Bands
      (let ((bb-std (stddev-update (:bb-stddev bank) close))
            (bb-up (+ sma20-val (* 2.0 bb-std)))
            (bb-lo (- sma20-val (* 2.0 bb-std)))
            (bb-w (if (= close 0.0) 0.0 (/ (- bb-up bb-lo) close)))
            (bb-p (if (= (- bb-up bb-lo) 0.0) 0.5 (/ (- close bb-lo) (- bb-up bb-lo)))))

        ;; RSI
        (let ((rsi-val (rsi-update (:rsi bank) close)))

          ;; MACD
          (let (((macd-val macd-sig macd-h) (macd-update (:macd bank) close)))

            ;; DMI
            (let (((plus-di-val minus-di-val adx-val) (dmi-update (:dmi bank) high low close)))

              ;; ATR
              (let ((atr-val (atr-update (:atr bank) high low close))
                    (atr-r-val (if (= close 0.0) 0.0 (/ atr-val close))))

                ;; ATR history
                (rb-push (:atr-history bank) atr-val)

                ;; Stochastic
                (let (((stoch-k-val stoch-d-val) (stoch-update (:stoch bank) high low close)))

                  ;; Williams %R — same as stochastic but different scale
                  (let ((williams-r-val
                          (let ((highest (rb-max (:high-buf (:stoch bank))))
                                (lowest (rb-min (:low-buf (:stoch bank))))
                                (r (- highest lowest)))
                            (if (= r 0.0) -50.0
                              (* -100.0 (/ (- highest close) r))))))

                    ;; CCI
                    (let ((cci-val (cci-update (:cci bank) high low close)))

                      ;; MFI
                      (let ((mfi-val (mfi-update (:mfi bank) high low close volume)))

                        ;; OBV
                        (let ((obv-val (obv-update (:obv bank) close volume))
                              (obv-slope-val (linreg-slope (rb-to-list (:history (:obv bank))))))

                          ;; Volume acceleration
                          (let ((vol-sma (sma-update (:volume-sma20 bank) volume))
                                (vol-accel (if (= vol-sma 0.0) 1.0 (/ volume vol-sma))))

                            ;; ROC buffer
                            (rb-push (:roc-buf bank) close)
                            (let ((roc-1-val (compute-roc (:roc-buf bank) 1))
                                  (roc-3-val (compute-roc (:roc-buf bank) 3))
                                  (roc-6-val (compute-roc (:roc-buf bank) 6))
                                  (roc-12-val (compute-roc (:roc-buf bank) 12)))

                              ;; ATR ROC
                              (let ((atr-roc-6-val (if (< (:len (:atr-history bank)) 7) 0.0
                                      (let ((atr-now (rb-newest (:atr-history bank)))
                                            (atr-6 (rb-get (:atr-history bank) (- (:len (:atr-history bank)) 7))))
                                        (if (= atr-6 0.0) 0.0 (/ (- atr-now atr-6) atr-6)))))
                                    (atr-roc-12-val (if (< (:len (:atr-history bank)) 12) 0.0
                                      (let ((atr-now (rb-newest (:atr-history bank)))
                                            (atr-12 (rb-get (:atr-history bank) 0)))
                                        (if (= atr-12 0.0) 0.0 (/ (- atr-now atr-12) atr-12))))))

                                ;; Range position
                                (rb-push (:range-high-12 bank) high) (rb-push (:range-low-12 bank) low)
                                (rb-push (:range-high-24 bank) high) (rb-push (:range-low-24 bank) low)
                                (rb-push (:range-high-48 bank) high) (rb-push (:range-low-48 bank) low)
                                (let ((rp-12 (compute-range-pos close (:range-high-12 bank) (:range-low-12 bank)))
                                      (rp-24 (compute-range-pos close (:range-high-24 bank) (:range-low-24 bank)))
                                      (rp-48 (compute-range-pos close (:range-high-48 bank) (:range-low-48 bank))))

                                  ;; Trend consistency
                                  (rb-push (:trend-buf-24 bank) close)
                                  (let ((tc-6 (compute-trend-consistency (:trend-buf-24 bank) 6))
                                        (tc-12 (compute-trend-consistency (:trend-buf-24 bank) 12))
                                        (tc-24 (compute-trend-consistency (:trend-buf-24 bank) 24)))

                                    ;; Multi-timeframe
                                    (rb-push (:tf-1h-buf bank) close)
                                    (rb-push (:tf-1h-high bank) high)
                                    (rb-push (:tf-1h-low bank) low)
                                    (rb-push (:tf-4h-buf bank) close)
                                    (rb-push (:tf-4h-high bank) high)
                                    (rb-push (:tf-4h-low bank) low)
                                    (let (((tf1h-c tf1h-h tf1h-l tf1h-r tf1h-b)
                                            (compute-tf-aggregate (:tf-1h-buf bank) (:tf-1h-high bank) (:tf-1h-low bank)))
                                          ((tf4h-c tf4h-h tf4h-l tf4h-r tf4h-b)
                                            (compute-tf-aggregate (:tf-4h-buf bank) (:tf-4h-high bank) (:tf-4h-low bank))))

                                      ;; Ichimoku
                                      (let (((tenkan kijun span-a span-b ct cb)
                                              (ichimoku-update (:ichimoku bank) high low)))

                                        ;; TK cross delta
                                        (let ((tk-spread (- tenkan kijun))
                                              (tk-cd (- tk-spread (:prev-tk-spread bank))))
                                          (set! bank :prev-tk-spread tk-spread)

                                          ;; Stochastic cross delta
                                          (let ((sk-spread (- stoch-k-val stoch-d-val))
                                                (stoch-cd (- sk-spread (:prev-stoch-kd bank))))
                                            (set! bank :prev-stoch-kd sk-spread)

                                            ;; Persistence
                                            (rb-push (:close-buf-48 bank) close)
                                            (let ((hurst-val (compute-hurst (rb-to-list (:close-buf-48 bank))))
                                                  (autocorr-val (compute-autocorrelation (rb-to-list (:close-buf-48 bank)))))

                                              ;; VWAP
                                              (set! bank :vwap-cum-vol (+ (:vwap-cum-vol bank) volume))
                                              (set! bank :vwap-cum-pv (+ (:vwap-cum-pv bank) (* close volume)))
                                              (let ((vwap (if (= (:vwap-cum-vol bank) 0.0) close
                                                            (/ (:vwap-cum-pv bank) (:vwap-cum-vol bank))))
                                                    (vwap-dist (if (= close 0.0) 0.0 (/ (- close vwap) close))))

                                                ;; Keltner channels
                                                (let ((kelt-u (+ ema20-val (* 2.0 atr-val)))
                                                      (kelt-l (- ema20-val (* 2.0 atr-val)))
                                                      (kelt-w (- kelt-u kelt-l))
                                                      (kelt-p (if (= kelt-w 0.0) 0.5 (/ (- close kelt-l) kelt-w)))
                                                      ;; Squeeze: bb-width / kelt-width
                                                      (squeeze-val (if (= kelt-w 0.0) 1.0 (/ (- bb-up bb-lo) kelt-w))))

                                                  ;; Regime indicators
                                                  (rb-push (:kama-er-buf bank) close)
                                                  (let ((kama-er-val (compute-kama-er (rb-to-list (:kama-er-buf bank)))))

                                                    ;; Choppiness
                                                    (let ((chop-atr-new (+ (:chop-atr-sum bank) atr-val)))
                                                      (when (rb-full? (:chop-buf bank))
                                                        (set! bank :chop-atr-sum (- chop-atr-new (rb-oldest (:chop-buf bank)))))
                                                      (when (not (rb-full? (:chop-buf bank)))
                                                        (set! bank :chop-atr-sum chop-atr-new))
                                                      (rb-push (:chop-buf bank) atr-val)
                                                      (let ((chop-val (compute-choppiness (:chop-atr-sum bank)
                                                                        (:range-high-12 bank) (:range-low-12 bank)
                                                                        (:len (:chop-buf bank)))))

                                                        ;; DFA
                                                        (rb-push (:dfa-buf bank) close)
                                                        (let ((dfa-val (compute-dfa-alpha (rb-to-list (:dfa-buf bank)))))

                                                          ;; Variance ratio
                                                          (rb-push (:var-ratio-buf bank) close)
                                                          (let ((var-ratio-val (compute-variance-ratio (rb-to-list (:var-ratio-buf bank)))))

                                                            ;; Entropy
                                                            (rb-push (:entropy-buf bank) close)
                                                            (let ((entropy-val (compute-entropy-rate (rb-to-list (:entropy-buf bank)))))

                                                              ;; Aroon
                                                              (rb-push (:aroon-high-buf bank) high)
                                                              (rb-push (:aroon-low-buf bank) low)
                                                              (let ((aroon-u (compute-aroon (:aroon-high-buf bank)))
                                                                    (aroon-d (compute-aroon-down (:aroon-low-buf bank))))

                                                                ;; Fractal dimension
                                                                (rb-push (:fractal-buf bank) close)
                                                                (let ((fractal-val (compute-fractal-dim (rb-to-list (:fractal-buf bank)))))

                                                                  ;; Divergence
                                                                  (rb-push (:rsi-peak-buf bank) (/ rsi-val 100.0))
                                                                  (rb-push (:price-peak-buf bank) close)
                                                                  (let (((div-bull div-bear)
                                                                          (compute-rsi-divergence (:price-peak-buf bank) (:rsi-peak-buf bank))))

                                                                    ;; Price action
                                                                    (let ((current-range (- high low))
                                                                          (rr (if (= (:prev-range bank) 0.0) 1.0
                                                                                (/ current-range (:prev-range bank))))
                                                                          (gap-val (if (= (:prev-close bank) 0.0) 0.0
                                                                                     (/ (- open (:prev-close bank)) (:prev-close bank)))))
                                                                      ;; Consecutive counts
                                                                      (if (> close open)
                                                                        (begin
                                                                          (set! bank :consecutive-up-count (+ (:consecutive-up-count bank) 1))
                                                                          (set! bank :consecutive-down-count 0))
                                                                        (if (< close open)
                                                                          (begin
                                                                            (set! bank :consecutive-down-count (+ (:consecutive-down-count bank) 1))
                                                                            (set! bank :consecutive-up-count 0))
                                                                          (begin)))  ; doji — no change

                                                                      ;; Timeframe agreement
                                                                      (let ((ret-5m (if (= (:prev-close bank) 0.0) 0.0
                                                                                      (/ (- close (:prev-close bank)) (:prev-close bank))))
                                                                            (dir-5m (signum ret-5m))
                                                                            (dir-1h (signum tf1h-r))
                                                                            (dir-4h (signum tf4h-r))
                                                                            (agreement (/ (+ (if (= dir-5m dir-1h) 1.0 0.0)
                                                                                            (if (= dir-5m dir-4h) 1.0 0.0)
                                                                                            (if (= dir-1h dir-4h) 1.0 0.0))
                                                                                         3.0)))

                                                                        ;; Time
                                                                        (let ((minute-val (parse-minute ts))
                                                                              (hour-val (parse-hour ts))
                                                                              (dow-val (parse-day-of-week ts))
                                                                              (dom-val (parse-day-of-month ts))
                                                                              (moy-val (parse-month ts)))

                                                                          ;; Update previous values
                                                                          (set! bank :prev-range current-range)
                                                                          (set! bank :prev-tf-1h-ret tf1h-r)
                                                                          (set! bank :prev-tf-4h-ret tf4h-r)
                                                                          (set! bank :prev-close close)
                                                                          (inc! bank :count)

                                                                          ;; Construct the enriched candle
                                                                          (candle
                                                                            ts open high low close volume
                                                                            sma20-val sma50-val sma200-val
                                                                            bb-up bb-lo bb-w bb-p
                                                                            rsi-val macd-val macd-sig macd-h
                                                                            plus-di-val minus-di-val adx-val atr-val atr-r-val
                                                                            stoch-k-val stoch-d-val williams-r-val cci-val mfi-val
                                                                            obv-slope-val vol-accel
                                                                            kelt-u kelt-l kelt-p squeeze-val
                                                                            roc-1-val roc-3-val roc-6-val roc-12-val
                                                                            atr-roc-6-val atr-roc-12-val
                                                                            tc-6 tc-12 tc-24
                                                                            rp-12 rp-24 rp-48
                                                                            tf1h-c tf1h-h tf1h-l tf1h-r tf1h-b
                                                                            tf4h-c tf4h-h tf4h-l tf4h-r tf4h-b
                                                                            tenkan kijun span-a span-b ct cb
                                                                            hurst-val autocorr-val vwap-dist
                                                                            kama-er-val chop-val dfa-val var-ratio-val entropy-val
                                                                            aroon-u aroon-d fractal-val
                                                                            div-bull div-bear
                                                                            tk-cd stoch-cd
                                                                            rr gap-val
                                                                            (+ (:consecutive-up-count bank) 0.0)
                                                                            (+ (:consecutive-down-count bank) 0.0)
                                                                            agreement
                                                                            minute-val hour-val dow-val dom-val moy-val)))))))))))))))))))))))))))))))))))))
