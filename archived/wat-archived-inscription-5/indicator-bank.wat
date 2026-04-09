;; indicator-bank.wat — streaming state machine for technical indicators
;; Depends on: raw-candle (RawCandle), candle (Candle)
;; Advances all indicators by one raw candle.
;; Stateful — ring buffers, EMA accumulators, Wilder smoothers.
;; One per post (one per asset pair).

(require primitives)
(require raw-candle)
(require candle)

;; ══════════════════════════════════════════════════════════════════════
;; Streaming primitives — the building blocks of indicator state
;; ══════════════════════════════════════════════════════════════════════

;; ── RingBuffer ─────────────────────────────────────────────────────
;; Fixed-capacity circular buffer for windowed computations.

(struct ring-buffer
  [data     : Vec<f64>]
  [capacity : usize]
  [head     : usize]
  [len      : usize])

(define (make-ring-buffer [capacity : usize])
  : RingBuffer
  (ring-buffer (zeros capacity) capacity 0 0))

(define (ring-push! [rb : RingBuffer] [value : f64])
  (set! (:data rb) (:head rb) value)
  (set! (:head rb) (mod (+ (:head rb) 1) (:capacity rb)))
  (when (< (:len rb) (:capacity rb))
    (set! (:len rb) (+ (:len rb) 1))))

(define (ring-full? [rb : RingBuffer])
  : bool
  (= (:len rb) (:capacity rb)))

(define (ring-get [rb : RingBuffer] [idx : usize])
  : f64
  ;; idx 0 = oldest, idx (len-1) = newest
  (let ((actual (mod (+ (- (:head rb) (:len rb)) idx (:capacity rb))
                     (:capacity rb))))
    (nth (:data rb) actual)))

(define (ring-newest [rb : RingBuffer])
  : f64
  (ring-get rb (- (:len rb) 1)))

(define (ring-oldest [rb : RingBuffer])
  : f64
  (ring-get rb 0))

(define (ring-max [rb : RingBuffer])
  : f64
  (fold (lambda (best i) (max best (ring-get rb i)))
        f64-neg-infinity
        (range 0 (:len rb))))

(define (ring-min [rb : RingBuffer])
  : f64
  (fold (lambda (best i) (min best (ring-get rb i)))
        f64-infinity
        (range 0 (:len rb))))

(define (ring-sum [rb : RingBuffer])
  : f64
  (fold (lambda (acc i) (+ acc (ring-get rb i)))
        0.0
        (range 0 (:len rb))))

(define (ring-to-list [rb : RingBuffer])
  : Vec<f64>
  (map (lambda (i) (ring-get rb i)) (range 0 (:len rb))))

;; ── EmaState ───────────────────────────────────────────────────────
;; Exponential moving average. Uses SMA for warmup, then switches.

(struct ema-state
  [value     : f64]
  [smoothing : f64]
  [period    : usize]
  [count     : usize]
  [accum     : f64])

(define (make-ema-state [period : usize])
  : EmaState
  (ema-state 0.0 (/ 2.0 (+ 1.0 (+ 0.0 period))) period 0 0.0))

(define (ema-step! [es : EmaState] [value : f64])
  : f64
  (inc! (:count es))
  (if (<= (:count es) (:period es))
    ;; Warmup phase — accumulate for SMA
    (begin
      (set! (:accum es) (+ (:accum es) value))
      (if (= (:count es) (:period es))
        (begin
          (set! (:value es) (/ (:accum es) (+ 0.0 (:period es))))
          (:value es))
        value))
    ;; EMA phase
    (begin
      (set! (:value es) (+ (* (:smoothing es) value)
                           (* (- 1.0 (:smoothing es)) (:value es))))
      (:value es))))

;; ── WilderState ────────────────────────────────────────────────────
;; Wilder smoothing: value = prev × (period-1)/period + new/period
;; Used by RSI, ATR, DMI, ADX.

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
  (inc! (:count ws))
  (let ((period-float (+ 0.0 (:period ws))))
    (if (<= (:count ws) (:period ws))
      ;; Warmup — accumulate for initial average
      (begin
        (set! (:accum ws) (+ (:accum ws) value))
        (if (= (:count ws) (:period ws))
          (begin
            (set! (:value ws) (/ (:accum ws) period-float))
            (:value ws))
          0.0))
      ;; Wilder smoothing
      (begin
        (set! (:value ws) (+ (/ (* (:value ws) (- period-float 1.0)) period-float)
                             (/ value period-float)))
        (:value ws)))))

;; ── RsiState ───────────────────────────────────────────────────────
;; Wilder-smoothed relative strength, period 14. Raw [0, 100].

(struct rsi-state
  [gain-smoother : WilderState]
  [loss-smoother : WilderState]
  [prev-close    : f64]
  [started       : bool])

(define (make-rsi-state)
  : RsiState
  (rsi-state (make-wilder-state 14) (make-wilder-state 14) 0.0 false))

(define (rsi-step! [rs : RsiState] [close : f64])
  : f64
  (if (not (:started rs))
    (begin
      (set! (:started rs) true)
      (set! (:prev-close rs) close)
      50.0)
    (let ((change (- close (:prev-close rs)))
          (gain   (if (> change 0.0) change 0.0))
          (loss   (if (< change 0.0) (abs change) 0.0))
          (avg-gain (wilder-step! (:gain-smoother rs) gain))
          (avg-loss (wilder-step! (:loss-smoother rs) loss)))
      (set! (:prev-close rs) close)
      (if (= avg-loss 0.0)
        100.0
        (- 100.0 (/ 100.0 (+ 1.0 (/ avg-gain avg-loss))))))))

;; ── AtrState ───────────────────────────────────────────────────────
;; Wilder-smoothed true range, period 14.

(struct atr-state
  [wilder     : WilderState]
  [prev-close : f64]
  [started    : bool])

(define (make-atr-state)
  : AtrState
  (atr-state (make-wilder-state 14) 0.0 false))

(define (atr-step! [as : AtrState] [high : f64] [low : f64] [close : f64])
  : f64
  (if (not (:started as))
    (begin
      (set! (:started as) true)
      (set! (:prev-close as) close)
      (wilder-step! (:wilder as) (- high low)))
    (let ((tr (max (- high low)
                   (max (abs (- high (:prev-close as)))
                        (abs (- low (:prev-close as)))))))
      (set! (:prev-close as) close)
      (wilder-step! (:wilder as) tr))))

;; ── ObvState ───────────────────────────────────────────────────────
;; Cumulative on-balance-volume. obv-slope-12 = linear regression slope.

(struct obv-state
  [obv        : f64]
  [prev-close : f64]
  [history    : RingBuffer]
  [started    : bool])

(define (make-obv-state)
  : ObvState
  (obv-state 0.0 0.0 (make-ring-buffer 12) false))

(define (obv-step! [os : ObvState] [close : f64] [volume : f64])
  : f64
  (if (not (:started os))
    (begin
      (set! (:started os) true)
      (set! (:prev-close os) close)
      (set! (:obv os) volume)
      (ring-push! (:history os) (:obv os))
      (:obv os))
    (begin
      (cond
        ((> close (:prev-close os))
          (set! (:obv os) (+ (:obv os) volume)))
        ((< close (:prev-close os))
          (set! (:obv os) (- (:obv os) volume)))
        (else (:obv os)))
      (set! (:prev-close os) close)
      (ring-push! (:history os) (:obv os))
      (:obv os))))

;; Linear regression slope over a ring buffer.
(define (linreg-slope [rb : RingBuffer])
  : f64
  (let ((n (:len rb)))
    (if (< n 2)
      0.0
      (let ((nf   (+ 0.0 n))
            (sum-x  (/ (* nf (- nf 1.0)) 2.0))
            (sum-x2 (/ (* nf (- nf 1.0) (- (* 2.0 nf) 1.0)) 6.0))
            (sum-y  (ring-sum rb))
            (sum-xy (fold (lambda (acc i)
                      (+ acc (* (+ 0.0 i) (ring-get rb i))))
                      0.0 (range 0 n)))
            (denom  (- (* nf sum-x2) (* sum-x sum-x))))
        (if (= denom 0.0)
          0.0
          (/ (- (* nf sum-xy) (* sum-x sum-y)) denom))))))

;; ── SmaState ───────────────────────────────────────────────────────
;; Simple moving average. Uses a ring buffer.

(struct sma-state
  [buffer : RingBuffer]
  [sum    : f64]
  [period : usize])

(define (make-sma-state [period : usize])
  : SmaState
  (sma-state (make-ring-buffer period) 0.0 period))

(define (sma-step! [ss : SmaState] [value : f64])
  : f64
  (when (ring-full? (:buffer ss))
    (set! (:sum ss) (- (:sum ss) (ring-oldest (:buffer ss)))))
  (ring-push! (:buffer ss) value)
  (set! (:sum ss) (+ (:sum ss) value))
  (/ (:sum ss) (+ 0.0 (min (:len (:buffer ss)) (:period ss)))))

;; ── RollingStddev ──────────────────────────────────────────────────
;; Rolling standard deviation for Bollinger Bands.

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
  (when (ring-full? (:buffer rs))
    (let ((old (ring-oldest (:buffer rs))))
      (set! (:sum rs) (- (:sum rs) old))
      (set! (:sum-sq rs) (- (:sum-sq rs) (* old old)))))
  (ring-push! (:buffer rs) value)
  (set! (:sum rs) (+ (:sum rs) value))
  (set! (:sum-sq rs) (+ (:sum-sq rs) (* value value)))
  (let ((n (+ 0.0 (:len (:buffer rs))))
        (mean (/ (:sum rs) n))
        (variance (- (/ (:sum-sq rs) n) (* mean mean))))
    (sqrt (max 0.0 variance))))

;; ── StochState ─────────────────────────────────────────────────────
;; Stochastic oscillator. %K = (close - low14) / (high14 - low14) × 100.
;; %D = SMA(3) of %K.

(struct stoch-state
  [high-buf : RingBuffer]
  [low-buf  : RingBuffer]
  [k-buf    : RingBuffer])

(define (make-stoch-state)
  : StochState
  (stoch-state (make-ring-buffer 14) (make-ring-buffer 14) (make-ring-buffer 3)))

(define (stoch-step! [ss : StochState] [high : f64] [low : f64] [close : f64])
  : (f64, f64)
  (ring-push! (:high-buf ss) high)
  (ring-push! (:low-buf ss) low)
  (let ((highest (ring-max (:high-buf ss)))
        (lowest  (ring-min (:low-buf ss)))
        (denom   (- highest lowest))
        (k       (if (= denom 0.0) 50.0
                   (* (/ (- close lowest) denom) 100.0))))
    (ring-push! (:k-buf ss) k)
    (let ((d (/ (ring-sum (:k-buf ss))
                (+ 0.0 (:len (:k-buf ss))))))
      (list k d))))

;; ── CciState ───────────────────────────────────────────────────────
;; Commodity Channel Index. Period 20.
;; CCI = (typical-price - SMA(tp, 20)) / (0.015 × mean-deviation)

(struct cci-state
  [tp-buf : RingBuffer]
  [tp-sma : SmaState])

(define (make-cci-state)
  : CciState
  (cci-state (make-ring-buffer 20) (make-sma-state 20)))

(define (cci-step! [cs : CciState] [high : f64] [low : f64] [close : f64])
  : f64
  (let ((tp (/ (+ high low close) 3.0))
        (sma-val (sma-step! (:tp-sma cs) tp)))
    (ring-push! (:tp-buf cs) tp)
    (let ((mean-dev (/ (fold (lambda (acc i)
                          (+ acc (abs (- (ring-get (:tp-buf cs) i) sma-val))))
                        0.0 (range 0 (:len (:tp-buf cs))))
                       (+ 0.0 (:len (:tp-buf cs))))))
      (if (= mean-dev 0.0)
        0.0
        (/ (- tp sma-val) (* 0.015 mean-dev))))))

;; ── MfiState ───────────────────────────────────────────────────────
;; Money Flow Index. 14 periods. Positive/negative flow by typical-price direction.

(struct mfi-state
  [pos-flow-buf : RingBuffer]
  [neg-flow-buf : RingBuffer]
  [prev-tp      : f64]
  [started      : bool])

(define (make-mfi-state)
  : MfiState
  (mfi-state (make-ring-buffer 14) (make-ring-buffer 14) 0.0 false))

(define (mfi-step! [ms : MfiState] [high : f64] [low : f64] [close : f64] [volume : f64])
  : f64
  (let ((tp (/ (+ high low close) 3.0))
        (raw-flow (* tp volume)))
    (if (not (:started ms))
      (begin
        (set! (:started ms) true)
        (set! (:prev-tp ms) tp)
        (ring-push! (:pos-flow-buf ms) raw-flow)
        (ring-push! (:neg-flow-buf ms) 0.0)
        50.0)
      (let ((pos (if (> tp (:prev-tp ms)) raw-flow 0.0))
            (neg (if (< tp (:prev-tp ms)) raw-flow 0.0)))
        (set! (:prev-tp ms) tp)
        (ring-push! (:pos-flow-buf ms) pos)
        (ring-push! (:neg-flow-buf ms) neg)
        (let ((pos-sum (ring-sum (:pos-flow-buf ms)))
              (neg-sum (ring-sum (:neg-flow-buf ms))))
          (if (= neg-sum 0.0)
            100.0
            (- 100.0 (/ 100.0 (+ 1.0 (/ pos-sum neg-sum))))))))))

;; ── IchimokuState ──────────────────────────────────────────────────
;; Ichimoku cloud components. Periods: 9, 26, 52.

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

(define (ichimoku-step! [is : IchimokuState] [high : f64] [low : f64])
  : (f64, f64, f64, f64, f64, f64)
  ;; Push to all buffers
  (ring-push! (:high-9 is) high)  (ring-push! (:low-9 is) low)
  (ring-push! (:high-26 is) high) (ring-push! (:low-26 is) low)
  (ring-push! (:high-52 is) high) (ring-push! (:low-52 is) low)
  ;; Compute components
  (let ((tenkan  (/ (+ (ring-max (:high-9 is))  (ring-min (:low-9 is))) 2.0))
        (kijun   (/ (+ (ring-max (:high-26 is)) (ring-min (:low-26 is))) 2.0))
        (span-a  (/ (+ tenkan kijun) 2.0))
        (span-b  (/ (+ (ring-max (:high-52 is)) (ring-min (:low-52 is))) 2.0))
        (c-top   (max span-a span-b))
        (c-bot   (min span-a span-b)))
    (list tenkan kijun span-a span-b c-top c-bot)))

;; ── MacdState ──────────────────────────────────────────────────────
;; MACD: fast EMA(12) - slow EMA(26). Signal = EMA(9) of MACD.

(struct macd-state
  [fast-ema   : EmaState]
  [slow-ema   : EmaState]
  [signal-ema : EmaState])

(define (make-macd-state)
  : MacdState
  (macd-state (make-ema-state 12) (make-ema-state 26) (make-ema-state 9)))

(define (macd-step! [ms : MacdState] [close : f64])
  : (f64, f64, f64)
  (let ((fast-val   (ema-step! (:fast-ema ms) close))
        (slow-val   (ema-step! (:slow-ema ms) close))
        (macd-val   (- fast-val slow-val))
        (signal-val (ema-step! (:signal-ema ms) macd-val))
        (hist-val   (- macd-val signal-val)))
    (list macd-val signal-val hist-val)))

;; ── DmiState ───────────────────────────────────────────────────────
;; Directional Movement Index. Wilder-smoothed +DI, -DI, ADX. Period 14.

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

(define (make-dmi-state)
  : DmiState
  (dmi-state
    (make-wilder-state 14) (make-wilder-state 14)
    (make-wilder-state 14) (make-wilder-state 14)
    0.0 0.0 0.0 false 0 14))

(define (dmi-step! [ds : DmiState] [high : f64] [low : f64] [close : f64])
  : (f64, f64, f64)
  (if (not (:started ds))
    (begin
      (set! (:started ds) true)
      (set! (:prev-high ds) high)
      (set! (:prev-low ds) low)
      (set! (:prev-close ds) close)
      (list 0.0 0.0 0.0))
    (let ((up-move   (- high (:prev-high ds)))
          (down-move (- (:prev-low ds) low))
          (plus-dm   (if (and (> up-move down-move) (> up-move 0.0)) up-move 0.0))
          (minus-dm  (if (and (> down-move up-move) (> down-move 0.0)) down-move 0.0))
          (tr        (max (- high low)
                      (max (abs (- high (:prev-close ds)))
                           (abs (- low (:prev-close ds))))))
          (sm-plus   (wilder-step! (:plus-smoother ds) plus-dm))
          (sm-minus  (wilder-step! (:minus-smoother ds) minus-dm))
          (sm-tr     (wilder-step! (:tr-smoother ds) tr))
          (plus-di   (if (= sm-tr 0.0) 0.0 (* (/ sm-plus sm-tr) 100.0)))
          (minus-di  (if (= sm-tr 0.0) 0.0 (* (/ sm-minus sm-tr) 100.0)))
          (di-sum    (+ plus-di minus-di))
          (dx        (if (= di-sum 0.0) 0.0 (* (/ (abs (- plus-di minus-di)) di-sum) 100.0))))
      (set! (:prev-high ds) high)
      (set! (:prev-low ds) low)
      (set! (:prev-close ds) close)
      (inc! (:count ds))
      (let ((adx (wilder-step! (:adx-smoother ds) dx)))
        (list plus-di minus-di adx)))))

;; ══════════════════════════════════════════════════════════════════════
;; The IndicatorBank — composed from the streaming primitives
;; ══════════════════════════════════════════════════════════════════════

(struct indicator-bank
  ;; Moving averages
  [sma20  : SmaState]
  [sma50  : SmaState]
  [sma200 : SmaState]
  [ema20  : EmaState]         ; internal — for Keltner channel computation
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
  [volume-sma20 : SmaState]   ; internal — for volume ratio
  ;; ROC
  [roc-buf : RingBuffer]      ; 12-period close buffer
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
    (make-sma-state 20)    ; volume-sma20
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
    ;; Multi-timeframe
    (make-ring-buffer 12) (make-ring-buffer 12) (make-ring-buffer 12)  ; 1h
    (make-ring-buffer 48) (make-ring-buffer 48) (make-ring-buffer 48)  ; 4h
    ;; Ichimoku
    (make-ichimoku-state)
    ;; Persistence
    (make-ring-buffer 48)
    ;; VWAP
    0.0 0.0
    ;; Regime
    (make-ring-buffer 10)     ; kama-er
    0.0                        ; chop-atr-sum
    (make-ring-buffer 14)     ; chop-buf
    (make-ring-buffer 48)     ; dfa
    (make-ring-buffer 30)     ; var-ratio
    (make-ring-buffer 30)     ; entropy
    (make-ring-buffer 25)     ; aroon-high
    (make-ring-buffer 25)     ; aroon-low
    (make-ring-buffer 30)     ; fractal
    ;; Divergence
    (make-ring-buffer 30)     ; rsi-peak
    (make-ring-buffer 30)     ; price-peak
    ;; Cross deltas
    0.0                        ; prev-tk-spread
    0.0                        ; prev-stoch-kd
    ;; Price action
    0.0                        ; prev-range
    0                          ; consecutive-up-count
    0                          ; consecutive-down-count
    ;; Timeframe agreement
    0.0 0.0                    ; prev-tf-1h-ret, prev-tf-4h-ret
    ;; Previous values
    0.0                        ; prev-close
    ;; Counter
    0))

;; ══════════════════════════════════════════════════════════════════════
;; Helper computations — pure functions over buffers
;; ══════════════════════════════════════════════════════════════════════

;; Williams %R: (highest14 - close) / (highest14 - lowest14) × -100
(define (compute-williams-r [stoch : StochState] [close : f64])
  : f64
  (let ((highest (ring-max (:high-buf stoch)))
        (lowest  (ring-min (:low-buf stoch)))
        (denom   (- highest lowest)))
    (if (= denom 0.0)
      -50.0
      (* (/ (- highest close) denom) -100.0))))

;; Rate of change: (close - close_N_ago) / close_N_ago
(define (compute-roc [rb : RingBuffer] [n : usize])
  : f64
  (if (< (:len rb) (+ n 1))
    0.0
    (let ((old (ring-get rb (- (:len rb) (+ n 1)))))
      (if (= old 0.0) 0.0
        (/ (- (ring-newest rb) old) (abs old))))))

;; Range position: (close - lowest-N) / (highest-N - lowest-N)
(define (compute-range-pos [high-rb : RingBuffer] [low-rb : RingBuffer] [close : f64])
  : f64
  (let ((highest (ring-max high-rb))
        (lowest  (ring-min low-rb))
        (denom   (- highest lowest)))
    (if (= denom 0.0) 0.5
      (/ (- close lowest) denom))))

;; Trend consistency: fraction of candles where close > prev-close, over last N
(define (compute-trend-consistency [rb : RingBuffer] [n : usize])
  : f64
  (let ((effective-n (min n (:len rb))))
    (if (< effective-n 2)
      0.5
      (let ((start (- (:len rb) effective-n))
            (ups   (fold (lambda (acc i)
                     (if (> (ring-get rb (+ start i 1))
                            (ring-get rb (+ start i)))
                       (+ acc 1.0) acc))
                     0.0 (range 0 (- effective-n 1)))))
        (/ ups (+ 0.0 (- effective-n 1)))))))

;; Multi-timeframe aggregation — aggregate N 5-minute bars
(define (compute-tf-close [buf : RingBuffer] [n : usize])
  : f64
  (if (< (:len buf) n) 0.0
    (ring-newest buf)))

(define (compute-tf-high [buf : RingBuffer])
  : f64
  (ring-max buf))

(define (compute-tf-low [buf : RingBuffer])
  : f64
  (ring-min buf))

(define (compute-tf-return [buf : RingBuffer] [n : usize])
  : f64
  (if (< (:len buf) n) 0.0
    (let ((old (ring-get buf (- (:len buf) n)))
          (new (ring-newest buf)))
      (if (= old 0.0) 0.0
        (/ (- new old) (abs old))))))

(define (compute-tf-body [buf : RingBuffer] [high-buf : RingBuffer] [low-buf : RingBuffer] [n : usize])
  : f64
  (if (< (:len buf) n) 0.0
    (let ((o   (ring-get buf (- (:len buf) n)))
          (c   (ring-newest buf))
          (h   (ring-max high-buf))
          (l   (ring-min low-buf))
          (rng (- h l)))
      (if (= rng 0.0) 0.0
        (/ (abs (- c o)) rng)))))

;; Hurst exponent — R/S analysis over a buffer
(define (compute-hurst [rb : RingBuffer])
  : f64
  (let ((n (:len rb)))
    (if (< n 8)
      0.5
      (let ((values (ring-to-list rb))
            ;; Compute returns
            (returns (map (lambda (i)
                       (let ((prev (nth values i))
                             (curr (nth values (+ i 1))))
                         (if (= prev 0.0) 0.0
                           (/ (- curr prev) (abs prev)))))
                     (range 0 (- n 1))))
            (ret-n (length returns)))
        (if (< ret-n 4)
          0.5
          ;; R/S for full series
          (let ((m (/ (fold + 0.0 returns) (+ 0.0 ret-n)))
                (deviations (map (lambda (r) (- r m)) returns))
                ;; Cumulative deviation
                (cum-dev (fold-left (lambda (acc d)
                            (let ((prev (if (empty? acc) 0.0 (last acc))))
                              (append acc (list (+ prev d)))))
                          '() deviations))
                (r (- (apply max cum-dev) (apply min cum-dev)))
                (s (sqrt (/ (fold + 0.0 (map (lambda (d) (* d d)) deviations))
                            (+ 0.0 ret-n))))
                (rs (if (= s 0.0) 1.0 (/ r s))))
            ;; H = log(R/S) / log(n) — simplified single-scale estimate
            (if (<= rs 0.0) 0.5
              (/ (ln rs) (ln (+ 0.0 ret-n))))))))))

;; Autocorrelation — lag-1 autocorrelation of a buffer
(define (compute-autocorrelation [rb : RingBuffer])
  : f64
  (let ((n (:len rb)))
    (if (< n 4)
      0.0
      (let ((values (ring-to-list rb))
            (m (/ (fold + 0.0 values) (+ 0.0 n)))
            (var (/ (fold + 0.0 (map (lambda (v) (* (- v m) (- v m))) values))
                    (+ 0.0 n))))
        (if (= var 0.0)
          0.0
          (let ((cov (/ (fold + 0.0
                          (map (lambda (i)
                            (* (- (nth values i) m) (- (nth values (+ i 1)) m)))
                            (range 0 (- n 1))))
                        (+ 0.0 (- n 1)))))
            (/ cov var)))))))

;; KAMA Efficiency Ratio: |close - close_N_ago| / sum(|close_i - close_i-1|)
(define (compute-kama-er [rb : RingBuffer])
  : f64
  (let ((n (:len rb)))
    (if (< n 2)
      0.0
      (let ((direction (abs (- (ring-newest rb) (ring-oldest rb))))
            (volatility (fold (lambda (acc i)
                          (+ acc (abs (- (ring-get rb (+ i 1))
                                        (ring-get rb i)))))
                        0.0 (range 0 (- n 1)))))
        (if (= volatility 0.0) 0.0
          (/ direction volatility))))))

;; Choppiness Index: 100 × log(sum(ATR, 14) / range(14)) / log(14)
(define (compute-choppiness [atr-sum : f64] [high-rb : RingBuffer] [low-rb : RingBuffer])
  : f64
  (let ((highest (ring-max high-rb))
        (lowest  (ring-min low-rb))
        (rng     (- highest lowest)))
    (if (<= rng 0.0) 50.0
      (let ((ratio (/ atr-sum rng)))
        (if (<= ratio 0.0) 50.0
          (* 100.0 (/ (ln ratio) (ln 14.0))))))))

;; DFA alpha — detrended fluctuation analysis exponent
;; Simplified: log-log slope of fluctuation vs scale
(define (compute-dfa-alpha [rb : RingBuffer])
  : f64
  (let ((n (:len rb)))
    (if (< n 16)
      0.5
      (let ((values (ring-to-list rb))
            ;; Cumulative deviation from mean
            (m (/ (fold + 0.0 values) (+ 0.0 n)))
            (profile (fold-left (lambda (acc v)
                        (let ((prev (if (empty? acc) 0.0 (last acc))))
                          (append acc (list (+ prev (- v m))))))
                      '() values))
            ;; Two scales: n/4 and n/2
            (s1 (max 4 (/ n 4)))
            (s2 (max 8 (/ n 2)))
            ;; Fluctuation at scale s: RMS of detrended segments
            (f1 (compute-dfa-fluctuation profile s1))
            (f2 (compute-dfa-fluctuation profile s2)))
        (if (or (= f1 0.0) (= f2 0.0) (= s1 s2))
          0.5
          (/ (- (ln f2) (ln f1))
             (- (ln (+ 0.0 s2)) (ln (+ 0.0 s1)))))))))

(define (compute-dfa-fluctuation [profile : Vec<f64>] [scale : usize])
  : f64
  (let ((n (length profile))
        (num-segments (/ n scale)))
    (if (< num-segments 1)
      0.0
      (let ((total-var (fold (lambda (acc seg)
                          (let ((start (* seg scale))
                                ;; Simple linear detrend over segment
                                (seg-vals (map (lambda (i) (nth profile (+ start i)))
                                              (range 0 scale)))
                                (seg-mean (/ (fold + 0.0 seg-vals) (+ 0.0 scale)))
                                (seg-var  (/ (fold + 0.0 (map (lambda (v) (* (- v seg-mean) (- v seg-mean)))
                                                              seg-vals))
                                             (+ 0.0 scale))))
                            (+ acc seg-var)))
                        0.0 (range 0 num-segments))))
        (sqrt (/ total-var (+ 0.0 num-segments)))))))

;; Variance ratio: variance at scale N / (N × variance at scale 1)
(define (compute-variance-ratio [rb : RingBuffer])
  : f64
  (let ((n (:len rb)))
    (if (< n 8)
      1.0
      (let ((values (ring-to-list rb))
            ;; Scale-1 returns
            (ret1 (map (lambda (i)
                     (if (= (nth values i) 0.0) 0.0
                       (/ (- (nth values (+ i 1)) (nth values i))
                          (abs (nth values i)))))
                   (range 0 (- n 1))))
            ;; Scale-4 returns
            (scale 4)
            (ret4 (map (lambda (i)
                     (if (= (nth values i) 0.0) 0.0
                       (/ (- (nth values (+ i scale)) (nth values i))
                          (abs (nth values i)))))
                   (range 0 (- n scale))))
            (var1 (if (empty? ret1) 1.0
                    (variance ret1)))
            (var4 (if (empty? ret4) 1.0
                    (variance ret4))))
        (if (= var1 0.0) 1.0
          (/ var4 (* (+ 0.0 scale) var1)))))))

;; Entropy rate — conditional entropy of discretized returns
(define (compute-entropy-rate [rb : RingBuffer])
  : f64
  (let ((n (:len rb)))
    (if (< n 4)
      1.0
      (let ((values (ring-to-list rb))
            ;; Discretize: -1 (down), 0 (flat), +1 (up)
            (symbols (map (lambda (i)
                       (let ((diff (- (nth values (+ i 1)) (nth values i))))
                         (cond
                           ((> diff 0.0)  1)
                           ((< diff 0.0) -1)
                           (else          0))))
                     (range 0 (- n 1))))
            (sym-n (length symbols))
            ;; Count transitions
            (transitions (map (lambda (i) (list (nth symbols i) (nth symbols (+ i 1))))
                          (range 0 (- sym-n 1))))
            (trans-n (length transitions)))
        (if (< trans-n 2)
          1.0
          ;; Count unique pair frequencies
          (let ((pair-counts (fold (lambda (acc t)
                               ;; Simple: encode pair as a × 10 + b
                               (let ((key (+ (* (+ (first t) 2) 10) (+ (second t) 2))))
                                 (assoc acc key (+ 1 (get acc key 0)))))
                             (map-of) transitions))
                ;; Entropy = -sum(p × log(p))
                (entropy (fold (lambda (acc k)
                            (let ((c (get pair-counts k 0))
                                  (p (/ (+ 0.0 c) (+ 0.0 trans-n))))
                              (if (<= p 0.0) acc
                                (- acc (* p (ln p))))))
                          0.0 (keys pair-counts))))
            entropy))))))

;; Aroon up/down: 100 × (period - periods-since-highest/lowest) / period
(define (compute-aroon-up [rb : RingBuffer] [period : usize])
  : f64
  (let ((n (min (:len rb) period)))
    (if (< n 2)
      50.0
      (let ((max-idx (fold (lambda (best i)
                       (if (>= (ring-get rb (- (:len rb) 1 (- i 0)))
                               (ring-get rb (- (:len rb) 1 (- best 0))))
                         i best))
                     0 (range 0 n)))
            (periods-since (- n 1 max-idx)))
        (* (/ (- (+ 0.0 n) 1.0 (+ 0.0 periods-since)) (- (+ 0.0 n) 1.0)) 100.0)))))

(define (compute-aroon-down [rb : RingBuffer] [period : usize])
  : f64
  (let ((n (min (:len rb) period)))
    (if (< n 2)
      50.0
      (let ((min-idx (fold (lambda (best i)
                       (if (<= (ring-get rb (- (:len rb) 1 (- i 0)))
                               (ring-get rb (- (:len rb) 1 (- best 0))))
                         i best))
                     0 (range 0 n)))
            (periods-since (- n 1 min-idx)))
        (* (/ (- (+ 0.0 n) 1.0 (+ 0.0 periods-since)) (- (+ 0.0 n) 1.0)) 100.0)))))

;; Fractal dimension — box-counting method over a buffer
(define (compute-fractal-dim [rb : RingBuffer])
  : f64
  (let ((n (:len rb)))
    (if (< n 8)
      1.5
      (let ((values (ring-to-list rb))
            (v-max (apply max values))
            (v-min (apply min values))
            (rng (- v-max v-min)))
        (if (= rng 0.0) 1.0
          ;; Simplified Higuchi method: two scales
          (let ((l1 (/ (fold + 0.0 (map (lambda (i)
                          (abs (- (nth values (+ i 1)) (nth values i))))
                        (range 0 (- n 1))))
                      (+ 0.0 (- n 1))))
                (k 2)
                (l2 (/ (fold + 0.0 (map (lambda (i)
                          (abs (- (nth values (+ i k)) (nth values i))))
                        (range 0 (- n k))))
                      (+ 0.0 (/ (- n k) k)))))
            (if (or (= l1 0.0) (= l2 0.0))
              1.5
              (/ (ln (/ l1 l2)) (ln (+ 0.0 k))))))))))

;; RSI divergence — PELT peak detection
(define (compute-rsi-divergence-bull [price-rb : RingBuffer] [rsi-rb : RingBuffer])
  : f64
  (let ((n (min (:len price-rb) (:len rsi-rb))))
    (if (< n 10)
      0.0
      ;; Find two recent lows in price and RSI
      (let ((prices (map (lambda (i) (ring-get price-rb (+ (- (:len price-rb) n) i)))
                     (range 0 n)))
            (rsis   (map (lambda (i) (ring-get rsi-rb (+ (- (:len rsi-rb) n) i)))
                     (range 0 n)))
            ;; Recent low = minimum in second half
            (half   (/ n 2))
            (first-prices (take prices half))
            (second-prices (last-n prices half))
            (first-rsis  (take rsis half))
            (second-rsis (last-n rsis half))
            (p-low1 (apply min first-prices))
            (p-low2 (apply min second-prices))
            (r-low1 (apply min first-rsis))
            (r-low2 (apply min second-rsis)))
        ;; Bullish: price makes lower low, RSI makes higher low
        (if (and (< p-low2 p-low1) (> r-low2 r-low1))
          (abs (- r-low2 r-low1))
          0.0)))))

(define (compute-rsi-divergence-bear [price-rb : RingBuffer] [rsi-rb : RingBuffer])
  : f64
  (let ((n (min (:len price-rb) (:len rsi-rb))))
    (if (< n 10)
      0.0
      (let ((prices (map (lambda (i) (ring-get price-rb (+ (- (:len price-rb) n) i)))
                     (range 0 n)))
            (rsis   (map (lambda (i) (ring-get rsi-rb (+ (- (:len rsi-rb) n) i)))
                     (range 0 n)))
            (half   (/ n 2))
            (first-prices (take prices half))
            (second-prices (last-n prices half))
            (first-rsis  (take rsis half))
            (second-rsis (last-n rsis half))
            (p-high1 (apply max first-prices))
            (p-high2 (apply max second-prices))
            (r-high1 (apply max first-rsis))
            (r-high2 (apply max second-rsis)))
        ;; Bearish: price makes higher high, RSI makes lower high
        (if (and (> p-high2 p-high1) (< r-high2 r-high1))
          (abs (- r-high1 r-high2))
          0.0)))))

;; Timeframe agreement — direction alignment across timeframes
(define (compute-tf-agreement [ret-5m : f64] [ret-1h : f64] [prev-1h : f64]
                              [ret-4h : f64] [prev-4h : f64])
  : f64
  ;; Score = fraction of timeframes agreeing on direction
  ;; Each timeframe: current vs previous return direction
  (let ((dir-5m  (signum ret-5m))
        (dir-1h  (signum ret-1h))
        (dir-4h  (signum ret-4h))
        (agree-5m-1h (if (= dir-5m dir-1h) 1.0 0.0))
        (agree-5m-4h (if (= dir-5m dir-4h) 1.0 0.0))
        (agree-1h-4h (if (= dir-1h dir-4h) 1.0 0.0)))
    (/ (+ agree-5m-1h agree-5m-4h agree-1h-4h) 3.0)))

;; ══════════════════════════════════════════════════════════════════════
;; Timestamp parsing — extract time components from ISO string
;; ══════════════════════════════════════════════════════════════════════

(define (parse-minute [ts : String])
  : f64
  ;; Expects "YYYY-MM-DDThh:mm:ss" — minute at positions 14-15
  (+ 0.0 (mod (+ 0 (substring ts 14 16)) 60)))

(define (parse-hour [ts : String])
  : f64
  (+ 0.0 (mod (+ 0 (substring ts 11 13)) 24)))

(define (parse-day-of-week [ts : String])
  : f64
  ;; Simplified Zeller's — compute from year/month/day
  (let ((y (+ 0 (substring ts 0 4)))
        (m (+ 0 (substring ts 5 7)))
        (d (+ 0 (substring ts 8 10))))
    ;; Tomohiko Sakamoto's method
    (let ((t (list 0 3 2 5 0 3 5 1 4 6 2 4))
          (yr (if (< m 3) (- y 1) y)))
      (+ 0.0 (mod (+ yr (/ yr 4) (- (/ yr 100)) (/ yr 400)
                     (nth t (- m 1)) d)
                  7)))))

(define (parse-day-of-month [ts : String])
  : f64
  (+ 0.0 (+ 0 (substring ts 8 10))))

(define (parse-month-of-year [ts : String])
  : f64
  (+ 0.0 (+ 0 (substring ts 5 7))))

;; ══════════════════════════════════════════════════════════════════════
;; tick — the main entry point
;; ══════════════════════════════════════════════════════════════════════

(define (tick [bank : IndicatorBank] [raw : RawCandle])
  : Candle
  (let ((open   (:open raw))
        (high   (:high raw))
        (low    (:low raw))
        (close  (:close raw))
        (volume (:volume raw))
        (ts     (:ts raw)))

    ;; ── Moving averages ──────────────────────────────────────────
    (let ((sma20-val  (sma-step! (:sma20 bank) close))
          (sma50-val  (sma-step! (:sma50 bank) close))
          (sma200-val (sma-step! (:sma200 bank) close))
          (ema20-val  (ema-step! (:ema20 bank) close)))

    ;; ── Bollinger Bands ──────────────────────────────────────────
    (let ((bb-std   (stddev-step! (:bb-stddev bank) close))
          (bb-up    (+ sma20-val (* 2.0 bb-std)))
          (bb-dn    (- sma20-val (* 2.0 bb-std)))
          (bb-w     (if (= close 0.0) 0.0 (/ (- bb-up bb-dn) close)))
          (bb-rng   (- bb-up bb-dn))
          (bb-p     (if (= bb-rng 0.0) 0.5 (/ (- close bb-dn) bb-rng))))

    ;; ── Oscillators ──────────────────────────────────────────────
    (let ((rsi-val     (rsi-step! (:rsi bank) close))
          ((macd-val macd-sig macd-h) (macd-step! (:macd bank) close))
          ((plus-di-val minus-di-val adx-val) (dmi-step! (:dmi bank) high low close))
          (atr-val     (atr-step! (:atr bank) high low close))
          (atr-r-val   (if (= close 0.0) 0.0 (/ atr-val close)))
          ((stk std)   (stoch-step! (:stoch bank) high low close))
          (cci-val     (cci-step! (:cci bank) high low close))
          (mfi-val     (mfi-step! (:mfi bank) high low close volume))
          (will-r      (compute-williams-r (:stoch bank) close))
          (obv-val     (obv-step! (:obv bank) close volume))
          (obv-sl      (linreg-slope (:history (:obv bank))))
          (vol-sma-val (sma-step! (:volume-sma20 bank) volume))
          (vol-accel   (if (= vol-sma-val 0.0) 1.0 (/ volume vol-sma-val))))

    ;; ── Keltner + Squeeze ────────────────────────────────────────
    (let ((kelt-up  (+ ema20-val (* 1.5 atr-val)))
          (kelt-dn  (- ema20-val (* 1.5 atr-val)))
          (kelt-rng (- kelt-up kelt-dn))
          (kelt-p   (if (= kelt-rng 0.0) 0.5 (/ (- close kelt-dn) kelt-rng)))
          (squeeze-val (if (= kelt-rng 0.0) 1.0 (/ bb-rng kelt-rng))))

    ;; ── ROC ──────────────────────────────────────────────────────
    (begin
      (ring-push! (:roc-buf bank) close)
      (let ((roc1  (compute-roc (:roc-buf bank) 1))
            (roc3  (compute-roc (:roc-buf bank) 3))
            (roc6  (compute-roc (:roc-buf bank) 6))
            (roc12 (compute-roc (:roc-buf bank) 12)))

    ;; ── ATR history + ATR ROC ────────────────────────────────────
    (begin
      (ring-push! (:atr-history bank) atr-val)
      (let ((atr-roc6  (compute-roc (:atr-history bank) 6))
            (atr-roc12 (compute-roc (:atr-history bank) 12)))

    ;; ── Range position ───────────────────────────────────────────
    (begin
      (ring-push! (:range-high-12 bank) high)
      (ring-push! (:range-low-12 bank) low)
      (ring-push! (:range-high-24 bank) high)
      (ring-push! (:range-low-24 bank) low)
      (ring-push! (:range-high-48 bank) high)
      (ring-push! (:range-low-48 bank) low)
      (let ((rp12 (compute-range-pos (:range-high-12 bank) (:range-low-12 bank) close))
            (rp24 (compute-range-pos (:range-high-24 bank) (:range-low-24 bank) close))
            (rp48 (compute-range-pos (:range-high-48 bank) (:range-low-48 bank) close)))

    ;; ── Trend consistency ────────────────────────────────────────
    (begin
      (ring-push! (:trend-buf-24 bank) close)
      (let ((tc6  (compute-trend-consistency (:trend-buf-24 bank) 6))
            (tc12 (compute-trend-consistency (:trend-buf-24 bank) 12))
            (tc24 (compute-trend-consistency (:trend-buf-24 bank) 24)))

    ;; ── Multi-timeframe ──────────────────────────────────────────
    (begin
      (ring-push! (:tf-1h-buf bank) close)
      (ring-push! (:tf-1h-high bank) high)
      (ring-push! (:tf-1h-low bank) low)
      (ring-push! (:tf-4h-buf bank) close)
      (ring-push! (:tf-4h-high bank) high)
      (ring-push! (:tf-4h-low bank) low)
      (let ((tf1h-c  (compute-tf-close (:tf-1h-buf bank) 12))
            (tf1h-h  (compute-tf-high (:tf-1h-high bank)))
            (tf1h-l  (compute-tf-low (:tf-1h-low bank)))
            (tf1h-r  (compute-tf-return (:tf-1h-buf bank) 12))
            (tf1h-b  (compute-tf-body (:tf-1h-buf bank) (:tf-1h-high bank) (:tf-1h-low bank) 12))
            (tf4h-c  (compute-tf-close (:tf-4h-buf bank) 48))
            (tf4h-h  (compute-tf-high (:tf-4h-high bank)))
            (tf4h-l  (compute-tf-low (:tf-4h-low bank)))
            (tf4h-r  (compute-tf-return (:tf-4h-buf bank) 48))
            (tf4h-b  (compute-tf-body (:tf-4h-buf bank) (:tf-4h-high bank) (:tf-4h-low bank) 48)))

    ;; ── Ichimoku ─────────────────────────────────────────────────
    (let (((tenkan kijun span-a span-b c-top c-bot)
             (ichimoku-step! (:ichimoku bank) high low)))

    ;; ── Persistence ──────────────────────────────────────────────
    (begin
      (ring-push! (:close-buf-48 bank) close)
      (let ((hurst-val  (compute-hurst (:close-buf-48 bank)))
            (autocor-val (compute-autocorrelation (:close-buf-48 bank))))

    ;; ── VWAP ─────────────────────────────────────────────────────
    (begin
      (set! (:vwap-cum-vol bank) (+ (:vwap-cum-vol bank) volume))
      (set! (:vwap-cum-pv bank) (+ (:vwap-cum-pv bank) (* close volume)))
      (let ((vwap (if (= (:vwap-cum-vol bank) 0.0) close
                    (/ (:vwap-cum-pv bank) (:vwap-cum-vol bank))))
            (vwap-dist (if (= close 0.0) 0.0 (/ (- close vwap) close))))

    ;; ── Regime indicators ────────────────────────────────────────
    (begin
      (ring-push! (:kama-er-buf bank) close)
      (let ((kama-er-val (compute-kama-er (:kama-er-buf bank))))

    ;; Choppiness
    (begin
      (ring-push! (:chop-buf bank) atr-val)
      (set! (:chop-atr-sum bank)
        (if (ring-full? (:chop-buf bank))
          (ring-sum (:chop-buf bank))
          (+ (:chop-atr-sum bank) atr-val)))
      (let ((chop-val (compute-choppiness (:chop-atr-sum bank)
                        (:range-high-12 bank) (:range-low-12 bank))))

    ;; DFA
    (begin
      (ring-push! (:dfa-buf bank) close)
      (let ((dfa-val (compute-dfa-alpha (:dfa-buf bank))))

    ;; Variance ratio
    (begin
      (ring-push! (:var-ratio-buf bank) close)
      (let ((vr-val (compute-variance-ratio (:var-ratio-buf bank))))

    ;; Entropy
    (begin
      (ring-push! (:entropy-buf bank) close)
      (let ((entropy-val (compute-entropy-rate (:entropy-buf bank))))

    ;; Aroon
    (begin
      (ring-push! (:aroon-high-buf bank) high)
      (ring-push! (:aroon-low-buf bank) low)
      (let ((aroon-u (compute-aroon-up (:aroon-high-buf bank) 25))
            (aroon-d (compute-aroon-down (:aroon-low-buf bank) 25)))

    ;; Fractal dimension
    (begin
      (ring-push! (:fractal-buf bank) close)
      (let ((fractal-val (compute-fractal-dim (:fractal-buf bank))))

    ;; ── Divergence ───────────────────────────────────────────────
    (begin
      (ring-push! (:rsi-peak-buf bank) rsi-val)
      (ring-push! (:price-peak-buf bank) close)
      (let ((div-bull (compute-rsi-divergence-bull (:price-peak-buf bank) (:rsi-peak-buf bank)))
            (div-bear (compute-rsi-divergence-bear (:price-peak-buf bank) (:rsi-peak-buf bank))))

    ;; ── Cross deltas ─────────────────────────────────────────────
    (let ((tk-spread    (- tenkan kijun))
          (tk-delta     (- tk-spread (:prev-tk-spread bank)))
          (stoch-spread (- stk std))
          (stoch-delta  (- stoch-spread (:prev-stoch-kd bank))))
      (set! (:prev-tk-spread bank) tk-spread)
      (set! (:prev-stoch-kd bank) stoch-spread)

    ;; ── Price action ─────────────────────────────────────────────
    (let ((current-range (- high low))
          (range-r (if (= (:prev-range bank) 0.0) 1.0
                     (/ current-range (:prev-range bank))))
          (gap-val (if (= (:prev-close bank) 0.0) 0.0
                     (/ (- open (:prev-close bank)) (:prev-close bank)))))
      ;; Consecutive runs
      (if (> close open)
        (begin
          (set! (:consecutive-up-count bank) (+ (:consecutive-up-count bank) 1))
          (set! (:consecutive-down-count bank) 0))
        (if (< close open)
          (begin
            (set! (:consecutive-down-count bank) (+ (:consecutive-down-count bank) 1))
            (set! (:consecutive-up-count bank) 0))
          'noop))
      (set! (:prev-range bank) current-range)

    ;; ── Timeframe agreement ──────────────────────────────────────
    (let ((ret-5m (if (= (:prev-close bank) 0.0) 0.0
                    (/ (- close (:prev-close bank)) (:prev-close bank))))
          (tf-agree (compute-tf-agreement ret-5m tf1h-r (:prev-tf-1h-ret bank)
                                          tf4h-r (:prev-tf-4h-ret bank))))
      (set! (:prev-tf-1h-ret bank) tf1h-r)
      (set! (:prev-tf-4h-ret bank) tf4h-r)
      (set! (:prev-close bank) close)
      (inc! (:count bank))

    ;; ── Time ─────────────────────────────────────────────────────
    (let ((minute-val       (parse-minute ts))
          (hour-val         (parse-hour ts))
          (day-of-week-val  (parse-day-of-week ts))
          (day-of-month-val (parse-day-of-month ts))
          (month-val        (parse-month-of-year ts)))

    ;; ── Construct Candle ─────────────────────────────────────────
    (candle
      ts open high low close volume
      sma20-val sma50-val sma200-val
      bb-up bb-dn bb-w bb-p
      rsi-val macd-val macd-sig macd-h
      plus-di-val minus-di-val adx-val atr-val atr-r-val
      stk std will-r cci-val mfi-val
      obv-sl vol-accel
      kelt-up kelt-dn kelt-p squeeze-val
      roc1 roc3 roc6 roc12
      atr-roc6 atr-roc12
      tc6 tc12 tc24
      rp12 rp24 rp48
      tf1h-c tf1h-h tf1h-l tf1h-r tf1h-b
      tf4h-c tf4h-h tf4h-l tf4h-r tf4h-b
      tenkan kijun span-a span-b c-top c-bot
      hurst-val autocor-val vwap-dist
      kama-er-val chop-val dfa-val vr-val entropy-val
      aroon-u aroon-d fractal-val
      div-bull div-bear
      tk-delta stoch-delta
      range-r gap-val
      (+ 0.0 (:consecutive-up-count bank))
      (+ 0.0 (:consecutive-down-count bank))
      tf-agree
      minute-val hour-val day-of-week-val day-of-month-val month-val)

    )))))))))))))))))))))))))
