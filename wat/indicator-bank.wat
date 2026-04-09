;; indicator-bank.wat — streaming state machine for all technical indicators
;; Depends on: raw-candle.wat, candle.wat
;; ~1600 lines. The full tick from the tick contract.

(require primitives)
(require raw-candle)
(require candle)

;; ═══════════════════════════════════════════════════════════════════
;; Streaming Primitives — the building blocks of indicator state
;; ═══════════════════════════════════════════════════════════════════

;; ── RingBuffer ─────────────────────────────────────────────────────

(struct ring-buffer
  [data     : Vec<f64>]
  [capacity : usize]
  [head     : usize]
  [len      : usize])

(define (make-ring-buffer [capacity : usize])
  : RingBuffer
  (ring-buffer (zeros capacity) capacity 0 0))

(define (rb-push! [rb : RingBuffer] [value : f64])
  (set! (:data rb) (:head rb) value)
  (set! rb :head (mod (+ (:head rb) 1) (:capacity rb)))
  (when (< (:len rb) (:capacity rb))
    (set! rb :len (+ (:len rb) 1))))

(define (rb-get [rb : RingBuffer] [i : usize])
  : f64
  ;; i=0 is the oldest element
  (let ((idx (mod (+ (- (:head rb) (:len rb)) i (:capacity rb)) (:capacity rb))))
    (nth (:data rb) idx)))

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

;; ── EmaState ───────────────────────────────────────────────────────

(struct ema-state
  [value     : f64]
  [smoothing : f64]
  [period    : usize]
  [count     : usize]
  [accum     : f64])

(define (make-ema-state [period : usize])
  : EmaState
  (let ((smoothing (/ 2.0 (+ period 1))))
    (ema-state 0.0 smoothing period 0 0.0)))

(define (ema-step! [ema : EmaState] [value : f64])
  : f64
  (set! ema :count (+ (:count ema) 1))
  (if (<= (:count ema) (:period ema))
    ;; Warmup: accumulate for SMA seed
    (begin
      (set! ema :accum (+ (:accum ema) value))
      (if (= (:count ema) (:period ema))
        (let ((seed (/ (:accum ema) (:period ema))))
          (set! ema :value seed)
          seed)
        (begin
          (set! ema :value value)
          value)))
    ;; Running: exponential smoothing
    (let ((new-val (+ (* (:smoothing ema) value)
                      (* (- 1.0 (:smoothing ema)) (:value ema)))))
      (set! ema :value new-val)
      new-val)))

;; ── WilderState ────────────────────────────────────────────────────

(struct wilder-state
  [value  : f64]
  [period : usize]
  [count  : usize]
  [accum  : f64])

(define (make-wilder-state [period : usize])
  : WilderState
  (wilder-state 0.0 period 0 0.0))

(define (wilder-step! [ws : WilderState] [value : f64])
  : f64
  (let ((period-float (:period ws)))
    (set! ws :count (+ (:count ws) 1))
    (if (<= (:count ws) (:period ws))
      ;; Warmup: accumulate for SMA seed
      (begin
        (set! ws :accum (+ (:accum ws) value))
        (if (= (:count ws) (:period ws))
          (let ((seed (/ (:accum ws) period-float)))
            (set! ws :value seed)
            seed)
          (begin
            (set! ws :value value)
            value)))
      ;; Running: Wilder smoothing
      (let ((new-val (+ (/ value period-float)
                        (* (/ (- period-float 1.0) period-float) (:value ws)))))
        (set! ws :value new-val)
        new-val))))

;; ── RsiState ───────────────────────────────────────────────────────

(struct rsi-state
  [gain-smoother : WilderState]
  [loss-smoother : WilderState]
  [prev-close    : f64]
  [started       : bool])

(define (make-rsi-state [period : usize])
  : RsiState
  (rsi-state (make-wilder-state period) (make-wilder-state period) 0.0 false))

(define (rsi-step! [rsi : RsiState] [close : f64])
  : f64
  (if (not (:started rsi))
    (begin
      (set! rsi :prev-close close)
      (set! rsi :started true)
      50.0)
    (let ((change (- close (:prev-close rsi)))
          (gain (if (> change 0.0) change 0.0))
          (loss (if (< change 0.0) (abs change) 0.0))
          (avg-gain (wilder-step! (:gain-smoother rsi) gain))
          (avg-loss (wilder-step! (:loss-smoother rsi) loss)))
      (set! rsi :prev-close close)
      (if (= avg-loss 0.0)
        100.0
        (let ((rs (/ avg-gain avg-loss)))
          (- 100.0 (/ 100.0 (+ 1.0 rs))))))))

;; ── AtrState ───────────────────────────────────────────────────────

(struct atr-state
  [wilder     : WilderState]
  [prev-close : f64]
  [started    : bool])

(define (make-atr-state [period : usize])
  : AtrState
  (atr-state (make-wilder-state period) 0.0 false))

(define (atr-step! [atr-st : AtrState] [high : f64] [low : f64] [close : f64])
  : f64
  (if (not (:started atr-st))
    (begin
      (set! atr-st :prev-close close)
      (set! atr-st :started true)
      (let ((tr (- high low)))
        (wilder-step! (:wilder atr-st) tr)))
    (let ((tr (max (- high low)
                   (max (abs (- high (:prev-close atr-st)))
                        (abs (- low (:prev-close atr-st)))))))
      (set! atr-st :prev-close close)
      (wilder-step! (:wilder atr-st) tr))))

;; ═══════════════════════════════════════════════════════════════════
;; Linear Regression Slope — for OBV slope computation
;; Must be defined before obv-step! (define before use).
;; ═══════════════════════════════════════════════════════════════════

(define (linreg-slope [rb : RingBuffer])
  : f64
  (let ((n (:len rb)))
    (if (< n 2)
      0.0
      (let ((sum-x 0.0)
            (sum-y 0.0)
            (sum-xy 0.0)
            (sum-x2 0.0))
        (for-each (lambda (i)
          (let ((x (* 1.0 i))
                (y (rb-get rb i)))
            (set! sum-x (+ sum-x x))
            (set! sum-y (+ sum-y y))
            (set! sum-xy (+ sum-xy (* x y)))
            (set! sum-x2 (+ sum-x2 (* x x)))))
          (range 0 n))
        (let ((denom (- (* n sum-x2) (* sum-x sum-x))))
          (if (= denom 0.0)
            0.0
            (/ (- (* n sum-xy) (* sum-x sum-y)) denom)))))))

;; ── ObvState ───────────────────────────────────────────────────────

(struct obv-state
  [obv        : f64]
  [prev-close : f64]
  [history    : RingBuffer]
  [started    : bool])

(define (make-obv-state [history-len : usize])
  : ObvState
  (obv-state 0.0 0.0 (make-ring-buffer history-len) false))

(define (obv-step! [os : ObvState] [close : f64] [volume : f64])
  : f64
  (if (not (:started os))
    (begin
      (set! os :prev-close close)
      (set! os :started true)
      (rb-push! (:history os) (:obv os))
      (:obv os))
    (begin
      (cond
        ((> close (:prev-close os))
          (set! os :obv (+ (:obv os) volume)))
        ((< close (:prev-close os))
          (set! os :obv (- (:obv os) volume)))
        (else nil))
      (set! os :prev-close close)
      (rb-push! (:history os) (:obv os))
      (:obv os))))

;; ── SmaState ───────────────────────────────────────────────────────

(struct sma-state
  [buffer : RingBuffer]
  [sum    : f64]
  [period : usize])

(define (make-sma-state [period : usize])
  : SmaState
  (sma-state (make-ring-buffer period) 0.0 period))

(define (sma-step! [sma : SmaState] [value : f64])
  : f64
  (when (rb-full? (:buffer sma))
    (set! sma :sum (- (:sum sma) (rb-oldest (:buffer sma)))))
  (set! sma :sum (+ (:sum sma) value))
  (rb-push! (:buffer sma) value)
  (/ (:sum sma) (:len (:buffer sma))))

;; ── RollingStddev ──────────────────────────────────────────────────

(struct rolling-stddev
  [buffer : RingBuffer]
  [sum    : f64]
  [sum-sq : f64]
  [period : usize])

(define (make-rolling-stddev [period : usize])
  : RollingStddev
  (rolling-stddev (make-ring-buffer period) 0.0 0.0 period))

(define (stddev-step! [rs : RollingStddev] [value : f64])
  : f64
  (when (rb-full? (:buffer rs))
    (let ((old (rb-oldest (:buffer rs))))
      (set! rs :sum (- (:sum rs) old))
      (set! rs :sum-sq (- (:sum-sq rs) (* old old)))))
  (set! rs :sum (+ (:sum rs) value))
  (set! rs :sum-sq (+ (:sum-sq rs) (* value value)))
  (rb-push! (:buffer rs) value)
  (let ((n (:len (:buffer rs)))
        (mean (/ (:sum rs) n))
        (variance (- (/ (:sum-sq rs) n) (* mean mean))))
    (sqrt (max variance 0.0))))

;; ── StochState ─────────────────────────────────────────────────────

(struct stoch-state
  [high-buf : RingBuffer]
  [low-buf  : RingBuffer]
  [k-buf    : RingBuffer])

(define (make-stoch-state [period : usize] [k-smooth : usize])
  : StochState
  (stoch-state (make-ring-buffer period) (make-ring-buffer period)
               (make-ring-buffer k-smooth)))

(define (stoch-step! [ss : StochState] [high : f64] [low : f64] [close : f64])
  : (f64, f64)
  (rb-push! (:high-buf ss) high)
  (rb-push! (:low-buf ss) low)
  (let ((highest (rb-max (:high-buf ss)))
        (lowest (rb-min (:low-buf ss)))
        (denom (- highest lowest))
        (raw-k (if (= denom 0.0) 50.0 (* (/ (- close lowest) denom) 100.0))))
    (rb-push! (:k-buf ss) raw-k)
    ;; %D = SMA(3) of %K
    (let ((k-sum (fold (lambda (acc i) (+ acc (rb-get (:k-buf ss) i)))
                   0.0
                   (range 0 (:len (:k-buf ss)))))
          (d (/ k-sum (:len (:k-buf ss)))))
      (list raw-k d))))

;; ── CciState ───────────────────────────────────────────────────────

(struct cci-state
  [tp-buf : RingBuffer]
  [tp-sma : SmaState])

(define (make-cci-state [period : usize])
  : CciState
  (cci-state (make-ring-buffer period) (make-sma-state period)))

(define (cci-step! [cs : CciState] [high : f64] [low : f64] [close : f64])
  : f64
  (let ((tp (/ (+ high low close) 3.0))
        (tp-mean (sma-step! (:tp-sma cs) tp)))
    (rb-push! (:tp-buf cs) tp)
    ;; Mean deviation = mean of |tp_i - tp_mean|
    (let ((mean-dev (/ (fold (lambda (acc i)
                          (+ acc (abs (- (rb-get (:tp-buf cs) i) tp-mean))))
                        0.0
                        (range 0 (:len (:tp-buf cs))))
                       (:len (:tp-buf cs))))
          (cci-constant 0.015))
      (if (= mean-dev 0.0)
        0.0
        (/ (- tp tp-mean) (* cci-constant mean-dev))))))

;; ── MfiState ───────────────────────────────────────────────────────

(struct mfi-state
  [pos-flow-buf : RingBuffer]
  [neg-flow-buf : RingBuffer]
  [prev-tp      : f64]
  [started      : bool])

(define (make-mfi-state [period : usize])
  : MfiState
  (mfi-state (make-ring-buffer period) (make-ring-buffer period) 0.0 false))

(define (mfi-step! [ms : MfiState] [high : f64] [low : f64] [close : f64] [volume : f64])
  : f64
  (let ((tp (/ (+ high low close) 3.0))
        (raw-money-flow (* tp volume)))
    (if (not (:started ms))
      (begin
        (set! ms :prev-tp tp)
        (set! ms :started true)
        (rb-push! (:pos-flow-buf ms) 0.0)
        (rb-push! (:neg-flow-buf ms) 0.0)
        50.0)
      (begin
        (if (> tp (:prev-tp ms))
          (begin
            (rb-push! (:pos-flow-buf ms) raw-money-flow)
            (rb-push! (:neg-flow-buf ms) 0.0))
          (begin
            (rb-push! (:pos-flow-buf ms) 0.0)
            (rb-push! (:neg-flow-buf ms) raw-money-flow)))
        (set! ms :prev-tp tp)
        (let ((pos-sum (fold (lambda (acc i) (+ acc (rb-get (:pos-flow-buf ms) i)))
                         0.0 (range 0 (:len (:pos-flow-buf ms)))))
              (neg-sum (fold (lambda (acc i) (+ acc (rb-get (:neg-flow-buf ms) i)))
                         0.0 (range 0 (:len (:neg-flow-buf ms))))))
          (if (= neg-sum 0.0)
            100.0
            (let ((mfr (/ pos-sum neg-sum)))
              (- 100.0 (/ 100.0 (+ 1.0 mfr))))))))))

;; ── IchimokuState ──────────────────────────────────────────────────

(struct ichimoku-state
  [high-9  : RingBuffer] [low-9  : RingBuffer]
  [high-26 : RingBuffer] [low-26 : RingBuffer]
  [high-52 : RingBuffer] [low-52 : RingBuffer])

(define (make-ichimoku-state)
  : IchimokuState
  (ichimoku-state
    (make-ring-buffer 9) (make-ring-buffer 9)
    (make-ring-buffer 26) (make-ring-buffer 26)
    (make-ring-buffer 52) (make-ring-buffer 52)))

(define (ichimoku-step! [is : IchimokuState] [high : f64] [low : f64])
  : (f64, f64, f64, f64, f64, f64)
  ;; Push into all buffers
  (rb-push! (:high-9 is) high) (rb-push! (:low-9 is) low)
  (rb-push! (:high-26 is) high) (rb-push! (:low-26 is) low)
  (rb-push! (:high-52 is) high) (rb-push! (:low-52 is) low)
  ;; Compute Ichimoku components
  (let ((tenkan (/ (+ (rb-max (:high-9 is)) (rb-min (:low-9 is))) 2.0))
        (kijun (/ (+ (rb-max (:high-26 is)) (rb-min (:low-26 is))) 2.0))
        (senkou-a (/ (+ tenkan kijun) 2.0))
        (senkou-b (/ (+ (rb-max (:high-52 is)) (rb-min (:low-52 is))) 2.0))
        (c-top (max senkou-a senkou-b))
        (c-bottom (min senkou-a senkou-b)))
    (list tenkan kijun senkou-a senkou-b c-top c-bottom)))

;; ── MacdState ──────────────────────────────────────────────────────

(struct macd-state
  [fast-ema   : EmaState]
  [slow-ema   : EmaState]
  [signal-ema : EmaState])

(define (make-macd-state)
  : MacdState
  (macd-state (make-ema-state 12) (make-ema-state 26) (make-ema-state 9)))

(define (macd-step! [ms : MacdState] [close : f64])
  : (f64, f64, f64)
  (let ((fast (ema-step! (:fast-ema ms) close))
        (slow (ema-step! (:slow-ema ms) close))
        (macd-val (- fast slow))
        (signal (ema-step! (:signal-ema ms) macd-val))
        (hist (- macd-val signal)))
    (list macd-val signal hist)))

;; ── DmiState ───────────────────────────────────────────────────────

(struct dmi-state
  [plus-smoother  : WilderState]
  [minus-smoother : WilderState]
  [tr-smoother    : WilderState]
  [adx-smoother   : WilderState]
  [prev-high      : f64]
  [prev-low       : f64]
  [prev-close     : f64]
  [started        : bool]
  [count          : usize]
  [period         : usize])

(define (make-dmi-state [period : usize])
  : DmiState
  (dmi-state
    (make-wilder-state period) (make-wilder-state period)
    (make-wilder-state period) (make-wilder-state period)
    0.0 0.0 0.0 false 0 period))

(define (dmi-step! [ds : DmiState] [high : f64] [low : f64] [close : f64])
  : (f64, f64, f64)
  (if (not (:started ds))
    (begin
      (set! ds :prev-high high)
      (set! ds :prev-low low)
      (set! ds :prev-close close)
      (set! ds :started true)
      (list 0.0 0.0 0.0))
    (let ((up-move (- high (:prev-high ds)))
          (down-move (- (:prev-low ds) low))
          (plus-dm (if (and (> up-move down-move) (> up-move 0.0)) up-move 0.0))
          (minus-dm (if (and (> down-move up-move) (> down-move 0.0)) down-move 0.0))
          (tr (max (- high low)
                   (max (abs (- high (:prev-close ds)))
                        (abs (- low (:prev-close ds))))))
          (smoothed-tr (wilder-step! (:tr-smoother ds) tr))
          (smoothed-plus (wilder-step! (:plus-smoother ds) plus-dm))
          (smoothed-minus (wilder-step! (:minus-smoother ds) minus-dm))
          (plus-di (if (= smoothed-tr 0.0) 0.0 (* (/ smoothed-plus smoothed-tr) 100.0)))
          (minus-di (if (= smoothed-tr 0.0) 0.0 (* (/ smoothed-minus smoothed-tr) 100.0)))
          (di-sum (+ plus-di minus-di))
          (dx (if (= di-sum 0.0) 0.0 (* (/ (abs (- plus-di minus-di)) di-sum) 100.0))))
      (set! ds :count (+ (:count ds) 1))
      (set! ds :prev-high high)
      (set! ds :prev-low low)
      (set! ds :prev-close close)
      (let ((adx (wilder-step! (:adx-smoother ds) dx)))
        (list plus-di minus-di adx)))))

;; ═══════════════════════════════════════════════════════════════════
;; IndicatorBank — composed from the streaming primitives
;; ═══════════════════════════════════════════════════════════════════

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
    (make-rsi-state 14) (make-macd-state) (make-dmi-state 14)
    (make-atr-state 14) (make-stoch-state 14 3) (make-cci-state 20)
    (make-mfi-state 14) (make-obv-state 12) (make-sma-state 20)
    ;; ROC
    (make-ring-buffer 12)
    ;; Range position
    (make-ring-buffer 12) (make-ring-buffer 12)
    (make-ring-buffer 24) (make-ring-buffer 24)
    (make-ring-buffer 48) (make-ring-buffer 48)
    ;; Trend consistency
    (make-ring-buffer 24)
    ;; ATR history
    (make-ring-buffer 12)
    ;; Multi-timeframe — aggregate 12 for 1h, 48 for 4h
    (make-ring-buffer 12) (make-ring-buffer 12) (make-ring-buffer 12)
    (make-ring-buffer 48) (make-ring-buffer 48) (make-ring-buffer 48)
    ;; Ichimoku
    (make-ichimoku-state)
    ;; Persistence
    (make-ring-buffer 48)
    ;; VWAP
    0.0 0.0
    ;; Regime
    (make-ring-buffer 10)   ; kama-er
    0.0                      ; chop-atr-sum
    (make-ring-buffer 14)   ; chop-buf
    (make-ring-buffer 48)   ; dfa
    (make-ring-buffer 30)   ; var-ratio
    (make-ring-buffer 30)   ; entropy
    (make-ring-buffer 25)   ; aroon high
    (make-ring-buffer 25)   ; aroon low
    (make-ring-buffer 30)   ; fractal
    ;; Divergence
    (make-ring-buffer 30)   ; rsi peak
    (make-ring-buffer 30)   ; price peak
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

;; ═══════════════════════════════════════════════════════════════════
;; Helper computations — used inside tick
;; ═══════════════════════════════════════════════════════════════════

;; Hurst exponent via R/S analysis
(define (compute-hurst [rb : RingBuffer])
  : f64
  (let ((n (:len rb)))
    (if (< n 8)
      0.5
      (let ((vals (rb-to-list rb))
            (mean-val (/ (fold + 0.0 vals) n))
            (deviations (map (lambda (v) (- v mean-val)) vals))
            (cumulative (fold-left (lambda (acc d)
                          (let ((new-val (+ (if (empty? acc) 0.0 (last acc)) d)))
                            (append acc (list new-val))))
                          '() deviations))
            (r (- (fold max f64-neg-infinity cumulative)
                  (fold min f64-infinity cumulative)))
            (s (sqrt (/ (fold (lambda (acc d) (+ acc (* d d))) 0.0 deviations) n))))
        (if (= s 0.0)
          0.5
          (let ((rs (/ r s)))
            ;; H ~ log(R/S) / log(n)
            (if (<= rs 0.0)
              0.5
              (/ (ln rs) (ln (* 1.0 n))))))))))

;; Lag-1 autocorrelation
(define (compute-autocorrelation [rb : RingBuffer])
  : f64
  (let ((n (:len rb)))
    (if (< n 3)
      0.0
      (let ((vals (rb-to-list rb))
            (mean-val (/ (fold + 0.0 vals) n))
            (var-sum (fold (lambda (acc v) (+ acc (* (- v mean-val) (- v mean-val)))) 0.0 vals))
            (cov-sum (fold (lambda (acc i)
                      (+ acc (* (- (nth vals i) mean-val)
                                (- (nth vals (- i 1)) mean-val))))
                    0.0 (range 1 n))))
        (if (= var-sum 0.0)
          0.0
          (/ cov-sum var-sum))))))

;; KAMA Efficiency Ratio
(define (compute-kama-er [rb : RingBuffer])
  : f64
  (let ((n (:len rb)))
    (if (< n 2)
      0.0
      (let ((direction (abs (- (rb-newest rb) (rb-oldest rb))))
            (volatility (fold (lambda (acc i)
                          (+ acc (abs (- (rb-get rb i) (rb-get rb (- i 1))))))
                        0.0 (range 1 n))))
        (if (= volatility 0.0) 0.0 (/ direction volatility))))))

;; Choppiness Index
(define (compute-choppiness [atr-sum : f64] [high-buf : RingBuffer] [low-buf : RingBuffer] [period : usize])
  : f64
  (let ((highest (rb-max high-buf))
        (lowest (rb-min low-buf))
        (price-range (- highest lowest)))
    (if (<= price-range 0.0)
      50.0
      (* 100.0 (/ (ln (/ atr-sum price-range)) (ln (* 1.0 period)))))))

;; DFA alpha
(define (compute-dfa-alpha [rb : RingBuffer])
  : f64
  (let ((n (:len rb)))
    (if (< n 8)
      0.5
      (let ((vals (rb-to-list rb))
            ;; Compute cumulative sum of demeaned series
            (mean-val (/ (fold + 0.0 vals) n))
            (profile (fold-left (lambda (acc v)
                       (let ((new-val (+ (if (empty? acc) 0.0 (last acc)) (- v mean-val))))
                         (append acc (list new-val))))
                     '() vals))
            ;; Compute fluctuation at one scale (n/4)
            (seg-len (max (/ n 4) 2))
            (n-segs (/ n seg-len))
            (fluct-sum (fold (lambda (acc seg-i)
                        (let ((start (* seg-i seg-len))
                              (end (min (* (+ seg-i 1) seg-len) n))
                              (seg-n (- end start))
                              ;; Linear detrend: subtract best-fit line
                              (seg-vals (map (lambda (j) (nth profile (+ start j))) (range 0 seg-n)))
                              (seg-mean (/ (fold + 0.0 seg-vals) seg-n))
                              (var (/ (fold (lambda (a v) (+ a (* (- v seg-mean) (- v seg-mean))))
                                       0.0 seg-vals) seg-n)))
                          (+ acc var)))
                      0.0 (range 0 n-segs)))
            (f-val (sqrt (/ fluct-sum (max n-segs 1)))))
        ;; alpha ~ 0.5 for random walk, >0.5 for persistent, <0.5 for anti-persistent
        (if (<= f-val 0.0)
          0.5
          (/ (ln f-val) (ln (* 1.0 seg-len))))))))

;; Variance ratio
(define (compute-variance-ratio [rb : RingBuffer])
  : f64
  (let ((n (:len rb)))
    (if (< n 4)
      1.0
      (let ((vals (rb-to-list rb))
            ;; Returns at scale 1
            (ret1 (map (lambda (i) (- (nth vals i) (nth vals (- i 1)))) (range 1 n)))
            (var1 (variance ret1))
            ;; Returns at scale 2
            (ret2 (filter-map (lambda (i)
                    (if (>= i 2)
                      (Some (- (nth vals i) (nth vals (- i 2))))
                      None))
                    (range 2 n)))
            (var2 (variance ret2)))
        (if (= var1 0.0)
          1.0
          (/ var2 (* 2.0 var1)))))))

;; Conditional entropy
(define (compute-entropy-rate [rb : RingBuffer])
  : f64
  (let ((n (:len rb)))
    (if (< n 4)
      1.0
      (let ((vals (rb-to-list rb))
            ;; Discretize returns into bins: -1, 0, +1
            (bins (map (lambda (i)
                    (let ((ret (- (nth vals i) (nth vals (- i 1)))))
                      (cond
                        ((> ret 0.001) 1)
                        ((< ret -0.001) -1)
                        (else 0))))
                  (range 1 n)))
            ;; Count transitions
            (n-bins (- (length bins) 1))
            ;; Pair counts for conditional entropy H(X_t | X_{t-1})
            (pair-counts (map-of))
            (single-counts (map-of)))
        (for-each (lambda (i)
          (let ((prev (nth bins i))
                (curr (nth bins (+ i 1)))
                (pair-key (format "{}_{}" prev curr))
                (prev-count (or (get single-counts prev) 0))
                (pair-count-val (or (get pair-counts pair-key) 0)))
            (set! single-counts (assoc single-counts prev (+ prev-count 1)))
            (set! pair-counts (assoc pair-counts pair-key (+ pair-count-val 1)))))
          (range 0 n-bins))
        ;; H(X_t | X_{t-1}) = - sum P(x_t, x_{t-1}) * log(P(x_t | x_{t-1}))
        (let ((entropy-sum 0.0))
          (for-each (lambda (pair-key)
            (let ((p-joint (/ (get pair-counts pair-key) n-bins))
                  ;; Extract the conditioning value from the key
                  (prev-val (substring pair-key 0 (- (length pair-key) 2)))
                  (p-prev (/ (or (get single-counts prev-val) 1) n-bins))
                  (p-cond (/ p-joint p-prev)))
              (when (> p-cond 0.0)
                (set! entropy-sum (- entropy-sum (* p-joint (ln p-cond)))))))
            (keys pair-counts))
          entropy-sum)))))

;; Aroon
(define (compute-aroon-up [rb : RingBuffer])
  : f64
  (let ((n (:len rb))
        (aroon-period 25))
    (if (< n 2)
      50.0
      (let ((max-idx (fold (lambda (best-i i)
                       (if (>= (rb-get rb i) (rb-get rb best-i)) i best-i))
                     0 (range 0 n)))
            (periods-since (- n 1 max-idx)))
        (* (/ (- aroon-period periods-since) aroon-period) 100.0)))))

(define (compute-aroon-down [rb : RingBuffer])
  : f64
  (let ((n (:len rb))
        (aroon-period 25))
    (if (< n 2)
      50.0
      (let ((min-idx (fold (lambda (best-i i)
                       (if (<= (rb-get rb i) (rb-get rb best-i)) i best-i))
                     0 (range 0 n)))
            (periods-since (- n 1 min-idx)))
        (* (/ (- aroon-period periods-since) aroon-period) 100.0)))))

;; Fractal dimension (simplified box-counting)
(define (compute-fractal-dim [rb : RingBuffer])
  : f64
  (let ((n (:len rb)))
    (if (< n 8)
      1.5
      (let ((vals (rb-to-list rb))
            ;; Two scales: count direction changes
            (changes (fold (lambda (acc i)
                      (let ((d1 (- (nth vals i) (nth vals (- i 1))))
                            (d2 (if (< i 2) 0.0 (- (nth vals (- i 1)) (nth vals (- i 2))))))
                        (if (and (!= d1 0.0) (!= d2 0.0) (< (* d1 d2) 0.0))
                          (+ acc 1)
                          acc)))
                    0 (range 1 n)))
            (roughness (/ changes (max (- n 1) 1))))
        ;; Map roughness to [1.0, 2.0]
        (+ 1.0 roughness)))))

;; RSI divergence detection (simplified PELT-style peak detection)
(define (compute-rsi-divergence [price-buf : RingBuffer] [rsi-buf : RingBuffer])
  : (f64, f64)
  (let ((n (min (:len price-buf) (:len rsi-buf))))
    (if (< n 6)
      (list 0.0 0.0)
      (let ((prices (map (lambda (i) (rb-get price-buf i)) (range 0 n)))
            (rsis (map (lambda (i) (rb-get rsi-buf i)) (range 0 n)))
            ;; Find recent local extremes (simplified)
            (mid (/ n 2))
            (first-half-price-low (fold min f64-infinity (take prices mid)))
            (second-half-price-low (fold min f64-infinity (last-n prices (- n mid))))
            (first-half-rsi-low (fold min f64-infinity (take rsis mid)))
            (second-half-rsi-low (fold min f64-infinity (last-n rsis (- n mid))))
            (first-half-price-high (fold max f64-neg-infinity (take prices mid)))
            (second-half-price-high (fold max f64-neg-infinity (last-n prices (- n mid))))
            (first-half-rsi-high (fold max f64-neg-infinity (take rsis mid)))
            (second-half-rsi-high (fold max f64-neg-infinity (last-n rsis (- n mid))))
            ;; Bullish: price makes lower low, RSI makes higher low
            (bull-mag (if (and (< second-half-price-low first-half-price-low)
                              (> second-half-rsi-low first-half-rsi-low))
                       (abs (- second-half-rsi-low first-half-rsi-low))
                       0.0))
            ;; Bearish: price makes higher high, RSI makes lower high
            (bear-mag (if (and (> second-half-price-high first-half-price-high)
                              (< second-half-rsi-high first-half-rsi-high))
                       (abs (- first-half-rsi-high second-half-rsi-high))
                       0.0)))
        (list bull-mag bear-mag)))))

;; Trend consistency for a window
(define (compute-trend-consistency [rb : RingBuffer] [window : usize])
  : f64
  (let ((n (min (:len rb) window)))
    (if (< n 2)
      0.5
      (let ((up-count (fold (lambda (acc i)
                        (if (> (rb-get rb i) (rb-get rb (- i 1)))
                          (+ acc 1)
                          acc))
                      0 (range (- (:len rb) n -1) (:len rb)))))
        (/ up-count (- n 1))))))

;; Timeframe agreement: compare 5m, 1h, 4h direction
(define (compute-tf-agreement [five-min-ret : f64] [one-h-ret : f64] [four-h-ret : f64])
  : f64
  (let ((five-dir (signum five-min-ret))
        (one-dir (signum one-h-ret))
        (four-dir (signum four-h-ret))
        (agreement-score 0.0))
    (when (= five-dir one-dir) (set! agreement-score (+ agreement-score 1.0)))
    (when (= five-dir four-dir) (set! agreement-score (+ agreement-score 1.0)))
    (when (= one-dir four-dir) (set! agreement-score (+ agreement-score 1.0)))
    (/ agreement-score 3.0)))

;; Parse timestamp components
(define (parse-minute [ts : String])
  : f64
  ;; ts format: "YYYY-MM-DDTHH:MM:SS" — minute at positions 14-15
  (let ((mm-str (substring ts 14 16)))
    (* 1.0 mm-str)))

(define (parse-hour [ts : String])
  : f64
  (let ((hh-str (substring ts 11 13)))
    (* 1.0 hh-str)))

(define (parse-day-of-week [ts : String])
  : f64
  ;; Simplified: derive from date. This is a host function in practice.
  ;; The Rust implementation will parse the timestamp properly.
  0.0)

(define (parse-day-of-month [ts : String])
  : f64
  (let ((dd-str (substring ts 8 10)))
    (* 1.0 dd-str)))

(define (parse-month-of-year [ts : String])
  : f64
  (let ((mm-str (substring ts 5 7)))
    (* 1.0 mm-str)))

;; ═══════════════════════════════════════════════════════════════════
;; tick — the main entry point. Advances all indicators by one candle.
;; ═══════════════════════════════════════════════════════════════════

(define (tick [bank : IndicatorBank] [rc : RawCandle])
  : Candle
  (let ((open (:open rc))
        (high (:high rc))
        (low (:low rc))
        (close (:close rc))
        (volume (:volume rc))
        (ts (:ts rc)))

    ;; ── Moving averages ──────────────────────────────────────────
    (let ((sma20-val (sma-step! (:sma20 bank) close))
          (sma50-val (sma-step! (:sma50 bank) close))
          (sma200-val (sma-step! (:sma200 bank) close))
          (ema20-val (ema-step! (:ema20 bank) close)))

    ;; ── Bollinger ────────────────────────────────────────────────
    (let ((bb-std (stddev-step! (:bb-stddev bank) close))
          (bb-upper-val (+ sma20-val (* 2.0 bb-std)))
          (bb-lower-val (- sma20-val (* 2.0 bb-std)))
          (bb-width-val (if (= close 0.0) 0.0 (/ (- bb-upper-val bb-lower-val) close)))
          (bb-range (- bb-upper-val bb-lower-val))
          (bb-pos-val (if (= bb-range 0.0) 0.5 (/ (- close bb-lower-val) bb-range))))

    ;; ── Oscillators ──────────────────────────────────────────────
    (let ((rsi-val (rsi-step! (:rsi bank) close))
          ((macd-val macd-signal-val macd-hist-val) (macd-step! (:macd bank) close))
          ((plus-di-val minus-di-val adx-val) (dmi-step! (:dmi bank) high low close))
          (atr-val (atr-step! (:atr bank) high low close))
          (atr-r-val (if (= close 0.0) 0.0 (/ atr-val close)))
          ((stoch-k-val stoch-d-val) (stoch-step! (:stoch bank) high low close))
          (cci-val (cci-step! (:cci bank) high low close))
          (mfi-val (mfi-step! (:mfi bank) high low close volume))
          (obv-val (obv-step! (:obv bank) close volume))
          (vol-sma20 (sma-step! (:volume-sma20 bank) volume))
          (volume-accel-val (if (= vol-sma20 0.0) 1.0 (/ volume vol-sma20))))

    ;; Williams %R = (highest14 - close) / (highest14 - lowest14) × -100
    ;; Reuse stoch high/low buffers (same period=14)
    (let ((highest14 (rb-max (:high-buf (:stoch bank))))
          (lowest14 (rb-min (:low-buf (:stoch bank))))
          (stoch-range (- highest14 lowest14))
          (williams-r-val (if (= stoch-range 0.0) -50.0
                            (* (/ (- highest14 close) stoch-range) -100.0))))

    ;; ── OBV slope ────────────────────────────────────────────────
    (let ((obv-slope-12-val (linreg-slope (:history (:obv bank)))))

    ;; ── Keltner ──────────────────────────────────────────────────
    (let ((kelt-width-mult 1.5)
          (kelt-upper-val (+ ema20-val (* kelt-width-mult atr-val)))
          (kelt-lower-val (- ema20-val (* kelt-width-mult atr-val)))
          (kelt-range (- kelt-upper-val kelt-lower-val))
          (kelt-pos-val (if (= kelt-range 0.0) 0.5
                          (/ (- close kelt-lower-val) kelt-range)))
          (kelt-width (- kelt-upper-val kelt-lower-val))
          (squeeze-val (if (= kelt-width 0.0) 1.0 (/ (- bb-upper-val bb-lower-val) kelt-width))))

    ;; ── Rate of Change ───────────────────────────────────────────
    (rb-push! (:roc-buf bank) close)
    (let ((roc-fn (lambda (n)
            (let ((buf-len (:len (:roc-buf bank))))
              (if (< buf-len (+ n 1))
                0.0
                (let ((old-val (rb-get (:roc-buf bank) (- buf-len 1 n))))
                  (if (= old-val 0.0) 0.0 (/ (- close old-val) old-val)))))))
          (roc-1-val (roc-fn 1))
          (roc-3-val (roc-fn 3))
          (roc-6-val (roc-fn 6))
          (roc-12-val (roc-fn 12)))

    ;; ── ATR Rate of Change ───────────────────────────────────────
    (rb-push! (:atr-history bank) atr-val)
    (let ((atr-roc-fn (lambda (n)
            (let ((buf-len (:len (:atr-history bank))))
              (if (< buf-len (+ n 1))
                0.0
                (let ((old-atr (rb-get (:atr-history bank) (- buf-len 1 n))))
                  (if (= old-atr 0.0) 0.0 (/ (- atr-val old-atr) old-atr)))))))
          (atr-roc-6-val (atr-roc-fn 6))
          (atr-roc-12-val (atr-roc-fn 12)))

    ;; ── Range position ───────────────────────────────────────────
    (rb-push! (:range-high-12 bank) high) (rb-push! (:range-low-12 bank) low)
    (rb-push! (:range-high-24 bank) high) (rb-push! (:range-low-24 bank) low)
    (rb-push! (:range-high-48 bank) high) (rb-push! (:range-low-48 bank) low)
    (let ((range-pos-fn (lambda (hi-buf lo-buf)
            (let ((highest (rb-max hi-buf))
                  (lowest (rb-min lo-buf))
                  (r (- highest lowest)))
              (if (= r 0.0) 0.5 (/ (- close lowest) r)))))
          (range-pos-12-val (range-pos-fn (:range-high-12 bank) (:range-low-12 bank)))
          (range-pos-24-val (range-pos-fn (:range-high-24 bank) (:range-low-24 bank)))
          (range-pos-48-val (range-pos-fn (:range-high-48 bank) (:range-low-48 bank))))

    ;; ── Trend consistency ────────────────────────────────────────
    (let ((up-candle (if (> close (:prev-close bank)) 1.0 0.0)))
      (rb-push! (:trend-buf-24 bank) up-candle))
    (let ((tc-6 (compute-trend-consistency (:trend-buf-24 bank) 6))
          (tc-12 (compute-trend-consistency (:trend-buf-24 bank) 12))
          (tc-24 (compute-trend-consistency (:trend-buf-24 bank) 24)))

    ;; ── Multi-timeframe ──────────────────────────────────────────
    (rb-push! (:tf-1h-buf bank) close)
    (rb-push! (:tf-1h-high bank) high)
    (rb-push! (:tf-1h-low bank) low)
    (rb-push! (:tf-4h-buf bank) close)
    (rb-push! (:tf-4h-high bank) high)
    (rb-push! (:tf-4h-low bank) low)
    (let ((tf-1h-buf-len (:len (:tf-1h-buf bank)))
          (tf-4h-buf-len (:len (:tf-4h-buf bank)))
          ;; 1h aggregation (12 candles)
          (tf-1h-close-val close)
          (tf-1h-high-val (rb-max (:tf-1h-high bank)))
          (tf-1h-low-val (rb-min (:tf-1h-low bank)))
          (tf-1h-first (rb-oldest (:tf-1h-buf bank)))
          (tf-1h-ret-val (if (= tf-1h-first 0.0) 0.0
                           (/ (- close tf-1h-first) tf-1h-first)))
          (tf-1h-body-val (if (= tf-1h-first 0.0) 0.0
                            (/ (abs (- close tf-1h-first))
                               (max (- tf-1h-high-val tf-1h-low-val) 0.0001))))
          ;; 4h aggregation (48 candles)
          (tf-4h-close-val close)
          (tf-4h-high-val (rb-max (:tf-4h-high bank)))
          (tf-4h-low-val (rb-min (:tf-4h-low bank)))
          (tf-4h-first (rb-oldest (:tf-4h-buf bank)))
          (tf-4h-ret-val (if (= tf-4h-first 0.0) 0.0
                           (/ (- close tf-4h-first) tf-4h-first)))
          (tf-4h-body-val (if (= tf-4h-first 0.0) 0.0
                            (/ (abs (- close tf-4h-first))
                               (max (- tf-4h-high-val tf-4h-low-val) 0.0001)))))

    ;; ── Ichimoku ─────────────────────────────────────────────────
    (let (((tenkan-val kijun-val senkou-a-val senkou-b-val cloud-top-val cloud-bottom-val)
           (ichimoku-step! (:ichimoku bank) high low))
          ;; Cross delta
          (tk-spread (- tenkan-val kijun-val))
          (tk-cross-delta-val (- tk-spread (:prev-tk-spread bank))))
    (set! bank :prev-tk-spread tk-spread)

    ;; ── Stochastic cross delta ───────────────────────────────────
    (let ((stoch-kd (- stoch-k-val stoch-d-val))
          (stoch-cross-delta-val (- stoch-kd (:prev-stoch-kd bank))))
    (set! bank :prev-stoch-kd stoch-kd)

    ;; ── Persistence ──────────────────────────────────────────────
    (rb-push! (:close-buf-48 bank) close)
    (let ((hurst-val (compute-hurst (:close-buf-48 bank)))
          (autocorrelation-val (compute-autocorrelation (:close-buf-48 bank))))

    ;; ── VWAP ─────────────────────────────────────────────────────
    (let ((tp (/ (+ high low close) 3.0)))
      (set! bank :vwap-cum-vol (+ (:vwap-cum-vol bank) volume))
      (set! bank :vwap-cum-pv (+ (:vwap-cum-pv bank) (* tp volume))))
    (let ((vwap (if (= (:vwap-cum-vol bank) 0.0) close
                  (/ (:vwap-cum-pv bank) (:vwap-cum-vol bank))))
          (vwap-distance-val (/ (- close vwap) close)))

    ;; ── Regime ───────────────────────────────────────────────────
    (rb-push! (:kama-er-buf bank) close)
    (let ((kama-er-val (compute-kama-er (:kama-er-buf bank))))

    ;; Choppiness
    (let ((current-atr atr-val))
      (when (rb-full? (:chop-buf bank))
        (set! bank :chop-atr-sum (- (:chop-atr-sum bank) (rb-oldest (:chop-buf bank)))))
      (set! bank :chop-atr-sum (+ (:chop-atr-sum bank) current-atr))
      (rb-push! (:chop-buf bank) current-atr))
    (let ((choppiness-val (compute-choppiness (:chop-atr-sum bank)
                            (:range-high-12 bank) (:range-low-12 bank) 14)))

    ;; DFA
    (rb-push! (:dfa-buf bank) close)
    (let ((dfa-alpha-val (compute-dfa-alpha (:dfa-buf bank))))

    ;; Variance ratio
    (rb-push! (:var-ratio-buf bank) close)
    (let ((variance-ratio-val (compute-variance-ratio (:var-ratio-buf bank))))

    ;; Entropy
    (rb-push! (:entropy-buf bank) close)
    (let ((entropy-rate-val (compute-entropy-rate (:entropy-buf bank))))

    ;; Aroon
    (rb-push! (:aroon-high-buf bank) high)
    (rb-push! (:aroon-low-buf bank) low)
    (let ((aroon-up-val (compute-aroon-up (:aroon-high-buf bank)))
          (aroon-down-val (compute-aroon-down (:aroon-low-buf bank))))

    ;; Fractal dimension
    (rb-push! (:fractal-buf bank) close)
    (let ((fractal-dim-val (compute-fractal-dim (:fractal-buf bank))))

    ;; ── Divergence ───────────────────────────────────────────────
    (rb-push! (:rsi-peak-buf bank) rsi-val)
    (rb-push! (:price-peak-buf bank) close)
    (let (((rsi-div-bull rsi-div-bear)
           (compute-rsi-divergence (:price-peak-buf bank) (:rsi-peak-buf bank))))

    ;; ── Price action ─────────────────────────────────────────────
    (let ((current-range (- high low))
          (range-ratio-val (if (= (:prev-range bank) 0.0) 1.0
                            (/ current-range (:prev-range bank))))
          (gap-val (if (= (:prev-close bank) 0.0) 0.0
                    (/ (- open (:prev-close bank)) (:prev-close bank)))))
    (set! bank :prev-range current-range)

    ;; Consecutive runs
    (if (> close (:prev-close bank))
      (begin
        (set! bank :consecutive-up-count (+ (:consecutive-up-count bank) 1))
        (set! bank :consecutive-down-count 0))
      (if (< close (:prev-close bank))
        (begin
          (set! bank :consecutive-down-count (+ (:consecutive-down-count bank) 1))
          (set! bank :consecutive-up-count 0))
        nil))
    (let ((consecutive-up-val (* 1.0 (:consecutive-up-count bank)))
          (consecutive-down-val (* 1.0 (:consecutive-down-count bank))))

    ;; ── Timeframe agreement ──────────────────────────────────────
    (let ((five-min-ret (if (= (:prev-close bank) 0.0) 0.0
                          (/ (- close (:prev-close bank)) (:prev-close bank))))
          (tf-agreement-val (compute-tf-agreement five-min-ret
                              (:prev-tf-1h-ret bank)
                              (:prev-tf-4h-ret bank))))
    (set! bank :prev-tf-1h-ret tf-1h-ret-val)
    (set! bank :prev-tf-4h-ret tf-4h-ret-val)

    ;; ── Time ─────────────────────────────────────────────────────
    (let ((minute-val (parse-minute ts))
          (hour-val (parse-hour ts))
          (dow-val (parse-day-of-week ts))
          (dom-val (parse-day-of-month ts))
          (moy-val (parse-month-of-year ts)))

    ;; ── Update bank state ────────────────────────────────────────
    (set! bank :prev-close close)
    (set! bank :count (+ (:count bank) 1))

    ;; ── Construct Candle ─────────────────────────────────────────
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
      tc-6 tc-12 tc-24
      range-pos-12-val range-pos-24-val range-pos-48-val
      tf-1h-close-val tf-1h-high-val tf-1h-low-val tf-1h-ret-val tf-1h-body-val
      tf-4h-close-val tf-4h-high-val tf-4h-low-val tf-4h-ret-val tf-4h-body-val
      tenkan-val kijun-val senkou-a-val senkou-b-val cloud-top-val cloud-bottom-val
      hurst-val autocorrelation-val vwap-distance-val
      kama-er-val choppiness-val dfa-alpha-val variance-ratio-val
      entropy-rate-val aroon-up-val aroon-down-val fractal-dim-val
      rsi-div-bull rsi-div-bear
      tk-cross-delta-val stoch-cross-delta-val
      range-ratio-val gap-val consecutive-up-val consecutive-down-val
      tf-agreement-val
      minute-val hour-val dow-val dom-val moy-val))

    )))))))))))))))))))))))))))))
