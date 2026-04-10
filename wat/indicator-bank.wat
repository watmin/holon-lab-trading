;; ── indicator-bank.wat ──────────────────────────────────────────────
;;
;; Streaming state machine. Advances all indicators by one raw candle.
;; Stateful — ring buffers, EMA accumulators, Wilder smoothers.
;; One per post (one per asset pair).
;; Depends on: raw-candle.
;; Produces: Candle (defined in candle.wat).

(require raw-candle)

;; ════════════════════════════════════════════════════════════════════
;; STREAMING PRIMITIVES — the building blocks of indicator state
;; ════════════════════════════════════════════════════════════════════

;; ── RingBuffer ─────────────────────────────────────────────────────
;; Fixed-capacity circular buffer. The fundamental storage primitive.

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
  (set! rb :head (mod (+ (:head rb) 1) (:capacity rb)))
  (when (< (:len rb) (:capacity rb))
    (inc! rb :len)))

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
  (fold-left max (ring-get rb 0)
    (map (lambda (i) (ring-get rb i))
         (range (:len rb)))))

(define (ring-min [rb : RingBuffer])
  : f64
  (fold-left min (ring-get rb 0)
    (map (lambda (i) (ring-get rb i))
         (range (:len rb)))))

(define (ring-to-list [rb : RingBuffer])
  : Vec<f64>
  (map (lambda (i) (ring-get rb i))
       (range (:len rb))))

;; ── EmaState ───────────────────────────────────────────────────────
;; Exponential moving average. Uses SMA for the seed period.

(struct ema-state
  [value     : f64]
  [smoothing : f64]
  [period    : usize]
  [count     : usize]
  [accum     : f64])

(define (make-ema-state [period : usize])
  : EmaState
  (ema-state 0.0 (/ 2.0 (+ period 1.0)) period 0 0.0))

(define (ema-step! [ema : EmaState] [value : f64])
  (inc! ema :count)
  (if (<= (:count ema) (:period ema))
    ;; Seed phase: accumulate for SMA
    (begin
      (set! ema :accum (+ (:accum ema) value))
      (when (= (:count ema) (:period ema))
        (set! ema :value (/ (:accum ema) (:period ema)))))
    ;; Running phase: EMA formula
    (set! ema :value (+ (* (:smoothing ema) value)
                        (* (- 1.0 (:smoothing ema)) (:value ema))))))

(define (ema-ready? [ema : EmaState])
  : bool
  (>= (:count ema) (:period ema)))

;; ── WilderState ────────────────────────────────────────────────────
;; Wilder's smoothing method. Used by RSI, ATR, DMI.

(struct wilder-state
  [value  : f64]
  [period : usize]
  [count  : usize]
  [accum  : f64])

(define (make-wilder-state [period : usize])
  : WilderState
  (wilder-state 0.0 period 0 0.0))

(define (wilder-step! [ws : WilderState] [value : f64])
  (inc! ws :count)
  (if (<= (:count ws) (:period ws))
    ;; Seed phase: accumulate for initial average
    (begin
      (set! ws :accum (+ (:accum ws) value))
      (when (= (:count ws) (:period ws))
        (set! ws :value (/ (:accum ws) (:period ws)))))
    ;; Running phase: Wilder's smoothing
    (set! ws :value (+ (/ value (:period ws))
                       (* (:value ws) (/ (- (:period ws) 1.0) (:period ws)))))))

(define (wilder-ready? [ws : WilderState])
  : bool
  (>= (:count ws) (:period ws)))

;; ── SmaState ───────────────────────────────────────────────────────
;; Simple moving average. Period is the buffer's capacity.

(struct sma-state
  [buffer : RingBuffer]
  [sum    : f64])

(define (make-sma-state [period : usize])
  : SmaState
  (sma-state (make-ring-buffer period) 0.0))

(define (sma-step! [sma : SmaState] [value : f64])
  ;; If buffer is full, subtract the oldest value
  (when (ring-full? (:buffer sma))
    (set! sma :sum (- (:sum sma) (ring-oldest (:buffer sma)))))
  (set! sma :sum (+ (:sum sma) value))
  (ring-push! (:buffer sma) value))

(define (sma-value [sma : SmaState])
  : f64
  (if (= (:len (:buffer sma)) 0)
    0.0
    (/ (:sum sma) (:len (:buffer sma)))))

(define (sma-ready? [sma : SmaState])
  : bool
  (ring-full? (:buffer sma)))

;; ── RollingStddev ──────────────────────────────────────────────────
;; Rolling standard deviation. Period is the buffer's capacity.

(struct rolling-stddev
  [buffer : RingBuffer]
  [sum    : f64]
  [sum-sq : f64])

(define (make-rolling-stddev [period : usize])
  : RollingStddev
  (rolling-stddev (make-ring-buffer period) 0.0 0.0))

(define (stddev-step! [sd : RollingStddev] [value : f64])
  (when (ring-full? (:buffer sd))
    (let ((old (ring-oldest (:buffer sd))))
      (set! sd :sum (- (:sum sd) old))
      (set! sd :sum-sq (- (:sum-sq sd) (* old old)))))
  (set! sd :sum (+ (:sum sd) value))
  (set! sd :sum-sq (+ (:sum-sq sd) (* value value)))
  (ring-push! (:buffer sd) value))

(define (stddev-value [sd : RollingStddev])
  : f64
  (let ((n (:len (:buffer sd))))
    (if (< n 2)
      0.0
      (let ((mean (/ (:sum sd) n))
            (var (- (/ (:sum-sq sd) n) (* mean mean))))
        (sqrt (max 0.0 var))))))

(define (stddev-ready? [sd : RollingStddev])
  : bool
  (ring-full? (:buffer sd)))

;; ── RsiState ───────────────────────────────────────────────────────
;; Wilder-smoothed relative strength index. Period 14.

(struct rsi-state
  [gain-smoother : WilderState]
  [loss-smoother : WilderState]
  [prev-close    : f64]
  [started       : bool])

(define (make-rsi-state [period : usize])
  : RsiState
  (rsi-state (make-wilder-state period) (make-wilder-state period) 0.0 false))

(define (rsi-step! [rsi : RsiState] [close : f64])
  (when (:started rsi)
    (let ((change (- close (:prev-close rsi)))
          (gain (max 0.0 change))
          (loss (max 0.0 (- change))))
      (wilder-step! (:gain-smoother rsi) gain)
      (wilder-step! (:loss-smoother rsi) loss)))
  (set! rsi :prev-close close)
  (set! rsi :started true))

(define (rsi-value [rsi : RsiState])
  : f64
  (let ((avg-gain (:value (:gain-smoother rsi)))
        (avg-loss (:value (:loss-smoother rsi))))
    (if (= avg-loss 0.0)
      100.0
      (let ((rs (/ avg-gain avg-loss)))
        (- 100.0 (/ 100.0 (+ 1.0 rs)))))))

(define (rsi-ready? [rsi : RsiState])
  : bool
  (and (:started rsi) (wilder-ready? (:gain-smoother rsi))))

;; ── AtrState ───────────────────────────────────────────────────────
;; Wilder-smoothed true range. Period 14.

(struct atr-state
  [wilder     : WilderState]
  [prev-close : f64]
  [started    : bool])

(define (make-atr-state [period : usize])
  : AtrState
  (atr-state (make-wilder-state period) 0.0 false))

(define (atr-step! [atr-st : AtrState] [high : f64] [low : f64] [close : f64])
  (let ((tr (if (:started atr-st)
              (max (- high low)
                   (max (abs (- high (:prev-close atr-st)))
                        (abs (- low (:prev-close atr-st)))))
              (- high low))))
    (wilder-step! (:wilder atr-st) tr)
    (set! atr-st :prev-close close)
    (set! atr-st :started true)))

(define (atr-value [atr-st : AtrState])
  : f64
  (:value (:wilder atr-st)))

(define (atr-ready? [atr-st : AtrState])
  : bool
  (wilder-ready? (:wilder atr-st)))

;; ── ObvState ───────────────────────────────────────────────────────
;; Cumulative on-balance volume with history for slope computation.

(struct obv-state
  [obv        : f64]
  [prev-close : f64]
  [history    : RingBuffer]
  [started    : bool])

(define (make-obv-state [history-len : usize])
  : ObvState
  (obv-state 0.0 0.0 (make-ring-buffer history-len) false))

(define (obv-step! [obv-st : ObvState] [close : f64] [volume : f64])
  (when (:started obv-st)
    (cond
      ((> close (:prev-close obv-st))
       (set! obv-st :obv (+ (:obv obv-st) volume)))
      ((< close (:prev-close obv-st))
       (set! obv-st :obv (- (:obv obv-st) volume)))
      (else (begin))))  ; unchanged
  (ring-push! (:history obv-st) (:obv obv-st))
  (set! obv-st :prev-close close)
  (set! obv-st :started true))

;; ── MacdState ──────────────────────────────────────────────────────
;; MACD: fast EMA(12) - slow EMA(26). Signal = EMA(9) of MACD.

(struct macd-state
  [fast-ema   : EmaState]
  [slow-ema   : EmaState]
  [signal-ema : EmaState])

(define (make-macd-state)
  : MacdState
  (macd-state (make-ema-state 12) (make-ema-state 26) (make-ema-state 9)))

(define (macd-step! [m : MacdState] [close : f64])
  (ema-step! (:fast-ema m) close)
  (ema-step! (:slow-ema m) close)
  (when (and (ema-ready? (:fast-ema m)) (ema-ready? (:slow-ema m)))
    (let ((macd-val (- (:value (:fast-ema m)) (:value (:slow-ema m)))))
      (ema-step! (:signal-ema m) macd-val))))

(define (macd-value [m : MacdState])
  : f64
  (- (:value (:fast-ema m)) (:value (:slow-ema m))))

(define (macd-signal-value [m : MacdState])
  : f64
  (:value (:signal-ema m)))

(define (macd-hist-value [m : MacdState])
  : f64
  (- (macd-value m) (macd-signal-value m)))

(define (macd-ready? [m : MacdState])
  : bool
  (and (ema-ready? (:slow-ema m)) (ema-ready? (:signal-ema m))))

;; ── DmiState ───────────────────────────────────────────────────────
;; Wilder-smoothed +DI, -DI, ADX. Period 14.

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

(define (make-dmi-state [period : usize])
  : DmiState
  (dmi-state (make-wilder-state period) (make-wilder-state period)
             (make-wilder-state period) (make-wilder-state period)
             0.0 0.0 0.0 false 0))

(define (dmi-step! [dmi : DmiState] [high : f64] [low : f64] [close : f64])
  (when (:started dmi)
    (let ((up-move (- high (:prev-high dmi)))
          (down-move (- (:prev-low dmi) low))
          (plus-dm (if (and (> up-move down-move) (> up-move 0.0)) up-move 0.0))
          (minus-dm (if (and (> down-move up-move) (> down-move 0.0)) down-move 0.0))
          (tr (max (- high low)
                   (max (abs (- high (:prev-close dmi)))
                        (abs (- low (:prev-close dmi)))))))
      (wilder-step! (:plus-smoother dmi) plus-dm)
      (wilder-step! (:minus-smoother dmi) minus-dm)
      (wilder-step! (:tr-smoother dmi) tr)
      ;; ADX: smooth the DX after the DI smoothers are ready
      (when (wilder-ready? (:tr-smoother dmi))
        (let ((smoothed-tr (:value (:tr-smoother dmi))))
          (when (> smoothed-tr 0.0)
            (let ((plus-di (/ (* 100.0 (:value (:plus-smoother dmi))) smoothed-tr))
                  (minus-di (/ (* 100.0 (:value (:minus-smoother dmi))) smoothed-tr))
                  (di-sum (+ plus-di minus-di)))
              (when (> di-sum 0.0)
                (let ((dx (* 100.0 (/ (abs (- plus-di minus-di)) di-sum))))
                  (wilder-step! (:adx-smoother dmi) dx)))))))))
  (set! dmi :prev-high high)
  (set! dmi :prev-low low)
  (set! dmi :prev-close close)
  (set! dmi :started true)
  (inc! dmi :count))

(define (dmi-plus-di [dmi : DmiState])
  : f64
  (let ((tr (:value (:tr-smoother dmi))))
    (if (= tr 0.0) 0.0
      (/ (* 100.0 (:value (:plus-smoother dmi))) tr))))

(define (dmi-minus-di [dmi : DmiState])
  : f64
  (let ((tr (:value (:tr-smoother dmi))))
    (if (= tr 0.0) 0.0
      (/ (* 100.0 (:value (:minus-smoother dmi))) tr))))

(define (dmi-adx [dmi : DmiState])
  : f64
  (:value (:adx-smoother dmi)))

(define (dmi-ready? [dmi : DmiState])
  : bool
  (wilder-ready? (:adx-smoother dmi)))

;; ── StochState ─────────────────────────────────────────────────────
;; Stochastic oscillator. %K period 14, %D = SMA(3) of %K.

(struct stoch-state
  [high-buf : RingBuffer]
  [low-buf  : RingBuffer]
  [k-buf    : RingBuffer])

(define (make-stoch-state [period : usize] [d-period : usize])
  : StochState
  (stoch-state (make-ring-buffer period) (make-ring-buffer period) (make-ring-buffer d-period)))

(define (stoch-step! [st : StochState] [high : f64] [low : f64] [close : f64])
  (ring-push! (:high-buf st) high)
  (ring-push! (:low-buf st) low)
  (when (ring-full? (:high-buf st))
    (let ((highest (ring-max (:high-buf st)))
          (lowest (ring-min (:low-buf st)))
          (range (- highest lowest)))
      (let ((k (if (= range 0.0) 50.0 (* 100.0 (/ (- close lowest) range)))))
        (ring-push! (:k-buf st) k)))))

(define (stoch-k [st : StochState])
  : f64
  (if (= (:len (:k-buf st)) 0) 50.0
    (ring-newest (:k-buf st))))

(define (stoch-d [st : StochState])
  : f64
  ;; %D = SMA(3) of %K
  (if (< (:len (:k-buf st)) 1) 50.0
    (let ((vals (ring-to-list (:k-buf st))))
      (/ (fold-left + 0.0 vals) (length vals)))))

(define (stoch-ready? [st : StochState])
  : bool
  (and (ring-full? (:high-buf st)) (ring-full? (:k-buf st))))

;; ── CciState ───────────────────────────────────────────────────────
;; Commodity Channel Index. Period 20.

(struct cci-state
  [tp-buf : RingBuffer]
  [tp-sma : SmaState])

(define (make-cci-state [period : usize])
  : CciState
  (cci-state (make-ring-buffer period) (make-sma-state period)))

(define (cci-step! [cci : CciState] [high : f64] [low : f64] [close : f64])
  (let ((tp (/ (+ high low close) 3.0)))
    (ring-push! (:tp-buf cci) tp)
    (sma-step! (:tp-sma cci) tp)))

(define (cci-value [cci : CciState])
  : f64
  (if (not (sma-ready? (:tp-sma cci)))
    0.0
    (let ((tp-mean (sma-value (:tp-sma cci)))
          (tp-latest (ring-newest (:tp-buf cci)))
          ;; Mean deviation
          (vals (ring-to-list (:tp-buf cci)))
          (mean-dev (/ (fold-left + 0.0
                         (map (lambda (v) (abs (- v tp-mean))) vals))
                       (length vals))))
      (if (= mean-dev 0.0)
        0.0
        (/ (- tp-latest tp-mean) (* 0.015 mean-dev))))))

(define (cci-ready? [cci : CciState])
  : bool
  (sma-ready? (:tp-sma cci)))

;; ── MfiState ───────────────────────────────────────────────────────
;; Money Flow Index. Period 14.

(struct mfi-state
  [pos-flow-buf : RingBuffer]
  [neg-flow-buf : RingBuffer]
  [prev-tp      : f64]
  [started      : bool])

(define (make-mfi-state [period : usize])
  : MfiState
  (mfi-state (make-ring-buffer period) (make-ring-buffer period) 0.0 false))

(define (mfi-step! [mfi : MfiState] [high : f64] [low : f64] [close : f64] [volume : f64])
  (let ((tp (/ (+ high low close) 3.0))
        (raw-flow (* tp volume)))
    (when (:started mfi)
      (if (> tp (:prev-tp mfi))
        (begin
          (ring-push! (:pos-flow-buf mfi) raw-flow)
          (ring-push! (:neg-flow-buf mfi) 0.0))
        (begin
          (ring-push! (:pos-flow-buf mfi) 0.0)
          (ring-push! (:neg-flow-buf mfi) raw-flow))))
    (set! mfi :prev-tp tp)
    (set! mfi :started true)))

(define (mfi-value [mfi : MfiState])
  : f64
  (let ((pos-sum (fold-left + 0.0 (ring-to-list (:pos-flow-buf mfi))))
        (neg-sum (fold-left + 0.0 (ring-to-list (:neg-flow-buf mfi)))))
    (if (= neg-sum 0.0)
      100.0
      (let ((mf-ratio (/ pos-sum neg-sum)))
        (- 100.0 (/ 100.0 (+ 1.0 mf-ratio)))))))

(define (mfi-ready? [mfi : MfiState])
  : bool
  (and (:started mfi) (ring-full? (:pos-flow-buf mfi))))

;; ── IchimokuState ──────────────────────────────────────────────────
;; Ichimoku Cloud. Periods: 9 (tenkan), 26 (kijun), 52 (senkou-b).

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

(define (ichimoku-step! [ich : IchimokuState] [high : f64] [low : f64])
  (ring-push! (:high-9 ich) high)   (ring-push! (:low-9 ich) low)
  (ring-push! (:high-26 ich) high)  (ring-push! (:low-26 ich) low)
  (ring-push! (:high-52 ich) high)  (ring-push! (:low-52 ich) low))

(define (ichimoku-midpoint [high-buf : RingBuffer] [low-buf : RingBuffer])
  : f64
  (/ (+ (ring-max high-buf) (ring-min low-buf)) 2.0))

(define (ichimoku-tenkan [ich : IchimokuState])
  : f64
  (ichimoku-midpoint (:high-9 ich) (:low-9 ich)))

(define (ichimoku-kijun [ich : IchimokuState])
  : f64
  (ichimoku-midpoint (:high-26 ich) (:low-26 ich)))

(define (ichimoku-senkou-a [ich : IchimokuState])
  : f64
  (/ (+ (ichimoku-tenkan ich) (ichimoku-kijun ich)) 2.0))

(define (ichimoku-senkou-b [ich : IchimokuState])
  : f64
  (ichimoku-midpoint (:high-52 ich) (:low-52 ich)))

(define (ichimoku-ready? [ich : IchimokuState])
  : bool
  (ring-full? (:high-52 ich)))


;; ════════════════════════════════════════════════════════════════════
;; INDICATOR BANK — composed from the streaming primitives
;; ════════════════════════════════════════════════════════════════════

(struct indicator-bank
  ;; Moving averages
  [sma20  : SmaState]
  [sma50  : SmaState]
  [sma200 : SmaState]
  [ema20  : EmaState]           ; internal — for Keltner channel computation

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
  [volume-sma20 : SmaState]    ; internal — for volume ratio computation

  ;; ROC
  [roc-buf : RingBuffer]       ; 12-period close buffer — ROC 1/3/6/12 index into this

  ;; Range position
  [range-high-12 : RingBuffer]  [range-low-12 : RingBuffer]
  [range-high-24 : RingBuffer]  [range-low-24 : RingBuffer]
  [range-high-48 : RingBuffer]  [range-low-48 : RingBuffer]

  ;; Trend consistency
  [trend-buf-24 : RingBuffer]

  ;; ATR history
  [atr-history : RingBuffer]   ; for atr-r (ATR ratio) and ATR ROC

  ;; Multi-timeframe
  [tf-1h-buf  : RingBuffer]  [tf-1h-high : RingBuffer]  [tf-1h-low : RingBuffer]
  [tf-4h-buf  : RingBuffer]  [tf-4h-high : RingBuffer]  [tf-4h-low : RingBuffer]

  ;; Ichimoku
  [ichimoku : IchimokuState]

  ;; Persistence — close buffer for Hurst + autocorrelation
  [close-buf-48 : RingBuffer]

  ;; VWAP — running accumulation
  [vwap-cum-vol : f64]
  [vwap-cum-pv  : f64]

  ;; Regime — state for regime fields
  [kama-er-buf : RingBuffer]   ; 10-period close buffer for KAMA efficiency ratio
  [chop-atr-sum : f64]         ; running sum of ATR over choppiness period
  [chop-buf : RingBuffer]      ; 14-period ATR buffer for Choppiness Index
  [dfa-buf : RingBuffer]       ; close buffer for DFA
  [var-ratio-buf : RingBuffer] ; close buffer for variance ratio (two scales)
  [entropy-buf : RingBuffer]   ; discretized return buffer for conditional entropy
  [aroon-high-buf : RingBuffer] ; 25-period high buffer for Aroon up
  [aroon-low-buf : RingBuffer]  ; 25-period low buffer for Aroon down
  [fractal-buf : RingBuffer]   ; close buffer for fractal dimension

  ;; Divergence — state for divergence fields
  [rsi-peak-buf : RingBuffer]  ; recent RSI values for PELT peak detection
  [price-peak-buf : RingBuffer] ; recent close values for divergence

  ;; Ichimoku cross delta — prev TK spread
  [prev-tk-spread : f64]

  ;; Stochastic cross delta — prev K-D spread
  [prev-stoch-kd : f64]

  ;; Price action — state for price-action fields
  [prev-range : f64]
  [consecutive-up-count : usize]
  [consecutive-down-count : usize]

  ;; Timeframe agreement — prev returns for direction comparison
  [prev-tf-1h-ret : f64]
  [prev-tf-4h-ret : f64]

  ;; Previous values
  [prev-close : f64]

  ;; Counter
  [count : usize])


;; ── Constructor ────────────────────────────────────────────────────

(define (make-indicator-bank)
  : IndicatorBank
  (indicator-bank
    ;; Moving averages
    (make-sma-state 20) (make-sma-state 50) (make-sma-state 200)
    (make-ema-state 20)
    ;; Bollinger
    (make-rolling-stddev 20)
    ;; Oscillators
    (make-rsi-state 14)
    (make-macd-state)
    (make-dmi-state 14)
    (make-atr-state 14)
    (make-stoch-state 14 3)
    (make-cci-state 20)
    (make-mfi-state 14)
    (make-obv-state 12)
    (make-sma-state 20)   ; volume-sma20
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
    ;; Multi-timeframe: 1h = 12 candles, 4h = 48 candles
    (make-ring-buffer 12) (make-ring-buffer 12) (make-ring-buffer 12)
    (make-ring-buffer 48) (make-ring-buffer 48) (make-ring-buffer 48)
    ;; Ichimoku
    (make-ichimoku-state)
    ;; Persistence
    (make-ring-buffer 48)
    ;; VWAP
    0.0 0.0
    ;; Regime
    (make-ring-buffer 10)   ; kama-er-buf
    0.0                     ; chop-atr-sum
    (make-ring-buffer 14)   ; chop-buf
    (make-ring-buffer 48)   ; dfa-buf
    (make-ring-buffer 30)   ; var-ratio-buf
    (make-ring-buffer 30)   ; entropy-buf
    (make-ring-buffer 25)   ; aroon-high-buf
    (make-ring-buffer 25)   ; aroon-low-buf
    (make-ring-buffer 30)   ; fractal-buf
    ;; Divergence
    (make-ring-buffer 20)   ; rsi-peak-buf
    (make-ring-buffer 20)   ; price-peak-buf
    ;; Ichimoku cross delta
    0.0
    ;; Stochastic cross delta
    0.0
    ;; Price action
    0.0   ; prev-range
    0     ; consecutive-up-count
    0     ; consecutive-down-count
    ;; Timeframe agreement
    0.0   ; prev-tf-1h-ret
    0.0   ; prev-tf-4h-ret
    ;; Previous values
    0.0   ; prev-close
    ;; Counter
    0))


;; ════════════════════════════════════════════════════════════════════
;; STEP FUNCTIONS — the tick waterfall, one per indicator family
;; ════════════════════════════════════════════════════════════════════

;; ── Step: Moving Averages ──────────────────────────────────────────

(define (step-sma! [bank : IndicatorBank] [close : f64])
  (sma-step! (:sma20 bank) close)
  (sma-step! (:sma50 bank) close)
  (sma-step! (:sma200 bank) close)
  (ema-step! (:ema20 bank) close))

;; ── Step: Bollinger Bands ──────────────────────────────────────────

(define (step-bollinger! [bank : IndicatorBank] [close : f64])
  (stddev-step! (:bb-stddev bank) close))

(define (compute-bb-upper [bank : IndicatorBank])
  : f64
  (+ (sma-value (:sma20 bank)) (* 2.0 (stddev-value (:bb-stddev bank)))))

(define (compute-bb-lower [bank : IndicatorBank])
  : f64
  (- (sma-value (:sma20 bank)) (* 2.0 (stddev-value (:bb-stddev bank)))))

(define (compute-bb-width [bank : IndicatorBank] [close : f64])
  : f64
  (let ((upper (compute-bb-upper bank))
        (lower (compute-bb-lower bank)))
    (if (= close 0.0) 0.0
      (/ (- upper lower) close))))

(define (compute-bb-pos [bank : IndicatorBank] [close : f64])
  : f64
  (let ((upper (compute-bb-upper bank))
        (lower (compute-bb-lower bank))
        (range (- upper lower)))
    (if (= range 0.0) 0.5
      (/ (- close lower) range))))

;; ── Step: RSI ──────────────────────────────────────────────────────

(define (step-rsi! [bank : IndicatorBank] [close : f64])
  (rsi-step! (:rsi bank) close))

;; ── Step: MACD ─────────────────────────────────────────────────────

(define (step-macd! [bank : IndicatorBank] [close : f64])
  (macd-step! (:macd bank) close))

;; ── Step: DMI ──────────────────────────────────────────────────────

(define (step-dmi! [bank : IndicatorBank] [high : f64] [low : f64] [close : f64])
  (dmi-step! (:dmi bank) high low close))

;; ── Step: ATR ──────────────────────────────────────────────────────

(define (step-atr! [bank : IndicatorBank] [high : f64] [low : f64] [close : f64])
  (atr-step! (:atr bank) high low close)
  ;; Push ATR value into history buffer for ATR ROC
  (when (atr-ready? (:atr bank))
    (ring-push! (:atr-history bank) (atr-value (:atr bank)))))

;; ── Step: Stochastic ───────────────────────────────────────────────

(define (step-stoch! [bank : IndicatorBank] [high : f64] [low : f64] [close : f64])
  (stoch-step! (:stoch bank) high low close))

;; ── Step: CCI ──────────────────────────────────────────────────────

(define (step-cci! [bank : IndicatorBank] [high : f64] [low : f64] [close : f64])
  (cci-step! (:cci bank) high low close))

;; ── Step: MFI ──────────────────────────────────────────────────────

(define (step-mfi! [bank : IndicatorBank] [high : f64] [low : f64] [close : f64] [volume : f64])
  (mfi-step! (:mfi bank) high low close volume))

;; ── Step: OBV ──────────────────────────────────────────────────────

(define (step-obv! [bank : IndicatorBank] [close : f64] [volume : f64])
  (obv-step! (:obv bank) close volume))

;; ── Step: Volume SMA ───────────────────────────────────────────────

(define (step-volume-sma! [bank : IndicatorBank] [volume : f64])
  (sma-step! (:volume-sma20 bank) volume))

;; ── Step: ROC (Rate of Change) ─────────────────────────────────────

(define (step-roc! [bank : IndicatorBank] [close : f64])
  (ring-push! (:roc-buf bank) close))

(define (compute-roc [bank : IndicatorBank] [n : usize])
  : f64
  ;; ROC-N = (close - close_N_ago) / close_N_ago
  (let ((buf (:roc-buf bank)))
    (if (< (:len buf) (+ n 1))
      0.0
      (let ((current (ring-newest buf))
            (past (ring-get buf (- (:len buf) 1 n))))
        (if (= past 0.0) 0.0
          (/ (- current past) past))))))

;; ── Step: Range Position ───────────────────────────────────────────

(define (step-range-pos! [bank : IndicatorBank] [high : f64] [low : f64])
  (ring-push! (:range-high-12 bank) high) (ring-push! (:range-low-12 bank) low)
  (ring-push! (:range-high-24 bank) high) (ring-push! (:range-low-24 bank) low)
  (ring-push! (:range-high-48 bank) high) (ring-push! (:range-low-48 bank) low))

(define (compute-range-pos [high-buf : RingBuffer] [low-buf : RingBuffer] [close : f64])
  : f64
  ;; (close - lowest) / (highest - lowest)
  (let ((highest (ring-max high-buf))
        (lowest (ring-min low-buf))
        (range (- highest lowest)))
    (if (= range 0.0) 0.5
      (/ (- close lowest) range))))

;; ── Step: Trend Consistency ────────────────────────────────────────

(define (step-trend-consistency! [bank : IndicatorBank] [close : f64])
  ;; Push 1.0 if close > prev-close, else 0.0
  (let ((bullish (if (> close (:prev-close bank)) 1.0 0.0)))
    (ring-push! (:trend-buf-24 bank) bullish)))

(define (compute-trend-consistency [bank : IndicatorBank] [n : usize])
  : f64
  ;; Fraction of last n candles where close > prev-close
  (let ((buf (:trend-buf-24 bank)))
    (if (< (:len buf) n)
      0.5
      (let ((recent (last-n (ring-to-list buf) n)))
        (/ (fold-left + 0.0 recent) n)))))

;; ── Step: Multi-Timeframe ──────────────────────────────────────────

(define (step-timeframe! [bank : IndicatorBank] [close : f64] [high : f64] [low : f64])
  ;; 1h = 12 5-min candles
  (ring-push! (:tf-1h-buf bank) close)
  (ring-push! (:tf-1h-high bank) high)
  (ring-push! (:tf-1h-low bank) low)
  ;; 4h = 48 5-min candles
  (ring-push! (:tf-4h-buf bank) close)
  (ring-push! (:tf-4h-high bank) high)
  (ring-push! (:tf-4h-low bank) low))

(define (compute-tf-close [buf : RingBuffer])
  : f64
  (if (= (:len buf) 0) 0.0 (ring-newest buf)))

(define (compute-tf-high [buf : RingBuffer])
  : f64
  (if (= (:len buf) 0) 0.0 (ring-max buf)))

(define (compute-tf-low [buf : RingBuffer])
  : f64
  (if (= (:len buf) 0) 0.0 (ring-min buf)))

(define (compute-tf-ret [buf : RingBuffer])
  : f64
  ;; Return = (newest - oldest) / oldest
  (if (< (:len buf) 2) 0.0
    (let ((oldest (ring-oldest buf))
          (newest (ring-newest buf)))
      (if (= oldest 0.0) 0.0
        (/ (- newest oldest) oldest)))))

(define (compute-tf-body [buf : RingBuffer])
  : f64
  ;; body-ratio = |close - open| / (high - low)
  (if (< (:len buf) 2) 0.0
    (let ((open-val (ring-oldest buf))
          (close-val (ring-newest buf))
          (high-val (ring-max buf))
          (low-val (ring-min buf))
          (range (- high-val low-val)))
      (if (= range 0.0) 0.0
        (/ (abs (- close-val open-val)) range)))))

(define (compute-tf-agreement [bank : IndicatorBank] [close : f64])
  : f64
  ;; Directional agreement score across 5m/1h/4h returns.
  ;; +1 if all agree, -1 if all disagree, 0 if mixed.
  (let ((ret-5m (if (= (:prev-close bank) 0.0) 0.0
                  (/ (- close (:prev-close bank)) (:prev-close bank))))
        (ret-1h (compute-tf-ret (:tf-1h-buf bank)))
        (ret-4h (compute-tf-ret (:tf-4h-buf bank)))
        (sign-5m (signum ret-5m))
        (sign-1h (signum ret-1h))
        (sign-4h (signum ret-4h)))
    ;; Average of pairwise agreements: sign(a) × sign(b) for each pair
    (/ (+ (* sign-5m sign-1h) (* sign-5m sign-4h) (* sign-1h sign-4h))
       3.0)))

;; ── Step: Ichimoku ─────────────────────────────────────────────────

(define (step-ichimoku! [bank : IndicatorBank] [high : f64] [low : f64])
  (ichimoku-step! (:ichimoku bank) high low))

;; ── Step: Persistence ──────────────────────────────────────────────

(define (step-persistence! [bank : IndicatorBank] [close : f64])
  (ring-push! (:close-buf-48 bank) close))

(define (compute-hurst [bank : IndicatorBank])
  : f64
  ;; R/S analysis over close-buf-48. Hurst exponent.
  ;; >0.5 trending, <0.5 mean-reverting, 0.5 random walk.
  (let ((buf (:close-buf-48 bank)))
    (if (< (:len buf) 8) 0.5
      (let ((prices (ring-to-list buf))
            (returns (map (lambda (i)
                           (let ((p0 (nth prices i))
                                 (p1 (nth prices (+ i 1))))
                             (if (= p0 0.0) 0.0
                               (/ (- p1 p0) p0))))
                         (range (- (length prices) 1))))
            (n (length returns))
            (mu (mean returns))
            (deviations (map (lambda (r) (- r mu)) returns))
            ;; Cumulative deviations
            (cum-dev (fold-left (lambda (acc d)
                                 (append acc (list (+ (last acc) d))))
                               (list 0.0)
                               deviations))
            (r (- (apply max cum-dev) (apply min cum-dev)))
            (s (stddev returns)))
        (if (= s 0.0) 0.5
          ;; R/S = r / s. Hurst ~ log(R/S) / log(n).
          ;; Simplified single-scale estimate.
          (let ((rs (/ r s)))
            (if (<= rs 0.0) 0.5
              (/ (ln rs) (ln n)))))))))

(define (compute-autocorrelation [bank : IndicatorBank])
  : f64
  ;; Lag-1 autocorrelation of close-buf-48.
  (let ((buf (:close-buf-48 bank)))
    (if (< (:len buf) 3) 0.0
      (let ((prices (ring-to-list buf))
            (n (length prices))
            (mu (mean prices))
            ;; Lag-0 variance
            (var-0 (/ (fold-left + 0.0
                        (map (lambda (p) (* (- p mu) (- p mu))) prices))
                      n))
            ;; Lag-1 covariance
            (cov-1 (/ (fold-left + 0.0
                        (map (lambda (i)
                               (* (- (nth prices i) mu)
                                  (- (nth prices (+ i 1)) mu)))
                             (range (- n 1))))
                      (- n 1))))
        (if (= var-0 0.0) 0.0
          (/ cov-1 var-0))))))

;; ── Step: VWAP ─────────────────────────────────────────────────────

(define (step-vwap! [bank : IndicatorBank] [close : f64] [volume : f64])
  (set! bank :vwap-cum-vol (+ (:vwap-cum-vol bank) volume))
  (set! bank :vwap-cum-pv (+ (:vwap-cum-pv bank) (* close volume))))

(define (compute-vwap-distance [bank : IndicatorBank] [close : f64])
  : f64
  (if (= (:vwap-cum-vol bank) 0.0) 0.0
    (let ((vwap (/ (:vwap-cum-pv bank) (:vwap-cum-vol bank))))
      (/ (- close vwap) close))))

;; ── Step: Regime — KAMA Efficiency Ratio ───────────────────────────

(define (step-kama-er! [bank : IndicatorBank] [close : f64])
  (ring-push! (:kama-er-buf bank) close))

(define (compute-kama-er [bank : IndicatorBank])
  : f64
  ;; Kaufman efficiency ratio over 10-period close buffer.
  ;; ER = |close - close_10ago| / sum(|close_i - close_{i-1}|, i=1..10)
  (let ((buf (:kama-er-buf bank)))
    (if (not (ring-full? buf)) 0.5
      (let ((prices (ring-to-list buf))
            (direction (abs (- (last prices) (first prices))))
            (volatility (fold-left + 0.0
                          (map (lambda (i)
                                 (abs (- (nth prices (+ i 1)) (nth prices i))))
                               (range (- (length prices) 1))))))
        (if (= volatility 0.0) 1.0
          (/ direction volatility))))))

;; ── Step: Regime — Choppiness Index ────────────────────────────────

(define (step-choppiness! [bank : IndicatorBank])
  ;; Uses ATR history from step-atr!. Pushes current ATR into chop-buf.
  (when (atr-ready? (:atr bank))
    (let ((current-atr (atr-value (:atr bank))))
      ;; Maintain running sum
      (when (ring-full? (:chop-buf bank))
        (set! bank :chop-atr-sum (- (:chop-atr-sum bank)
                                    (ring-oldest (:chop-buf bank)))))
      (set! bank :chop-atr-sum (+ (:chop-atr-sum bank) current-atr))
      (ring-push! (:chop-buf bank) current-atr))))

(define (compute-choppiness [bank : IndicatorBank] [high : f64] [low : f64])
  : f64
  ;; 100 × log(sum(ATR, 14) / range(14)) / log(14)
  (let ((buf (:chop-buf bank)))
    (if (not (ring-full? buf)) 50.0
      (let ((atr-sum (:chop-atr-sum bank))
            ;; range(14) from the last 14 highs and lows
            ;; Approximate from the range-position buffers or the ATR itself
            ;; Using the range-12 buffers (close enough to 14):
            (highest (ring-max (:range-high-12 bank)))
            (lowest (ring-min (:range-low-12 bank)))
            (range-val (- highest lowest)))
        (if (or (= range-val 0.0) (<= atr-sum 0.0))
          50.0
          (* 100.0 (/ (ln (/ atr-sum range-val)) (ln 14.0))))))))

;; ── Step: Regime — DFA (Detrended Fluctuation Analysis) ────────────

(define (step-dfa! [bank : IndicatorBank] [close : f64])
  (ring-push! (:dfa-buf bank) close))

(define (compute-dfa-alpha [bank : IndicatorBank])
  : f64
  ;; DFA exponent over close buffer(48).
  ;; >0.5 = persistent, <0.5 = anti-persistent, 0.5 = random.
  (let ((buf (:dfa-buf bank)))
    (if (< (:len buf) 16) 0.5
      (let ((prices (ring-to-list buf))
            (n (length prices))
            (mu (mean prices))
            ;; Cumulative deviation from mean
            (cum-dev (fold-left (lambda (acc p)
                                 (append acc (list (+ (last acc) (- p mu)))))
                               (list 0.0)
                               prices))
            ;; Compute fluctuation at two scales
            ;; Scale 1: segment length 4
            ;; Scale 2: segment length 8
            (f1 (dfa-fluctuation cum-dev 4))
            (f2 (dfa-fluctuation cum-dev 8)))
        (if (or (<= f1 0.0) (<= f2 0.0)) 0.5
          ;; alpha = log(F2/F1) / log(8/4) = log(F2/F1) / log(2)
          (/ (ln (/ f2 f1)) (ln 2.0)))))))

(define (dfa-fluctuation [cum-dev : Vec<f64>] [seg-len : usize])
  : f64
  ;; Compute RMS fluctuation at a given segment length.
  ;; Detrend each segment, compute variance, average, sqrt.
  (let ((n (length cum-dev))
        (num-segs (/ n seg-len))
        (variances
          (filter-map
            (lambda (s)
              (let ((start (* s seg-len)))
                (if (> (+ start seg-len) n) None
                  (let ((segment (map (lambda (i) (nth cum-dev (+ start i)))
                                      (range seg-len)))
                        ;; Linear detrend: subtract best-fit line
                        (detrended (linear-detrend segment)))
                    (Some (variance detrended))))))
            (range num-segs))))
    (if (empty? variances) 0.0
      (sqrt (mean variances)))))

(define (linear-detrend [xs : Vec<f64>])
  : Vec<f64>
  ;; Subtract best-fit line from xs.
  (let ((n (length xs))
        (x-indices (map (lambda (i) (* 1.0 i)) (range n)))
        (x-mean (mean x-indices))
        (y-mean (mean xs))
        (num (fold-left + 0.0
               (map (lambda (i) (* (- (nth x-indices i) x-mean)
                                   (- (nth xs i) y-mean)))
                    (range n))))
        (den (fold-left + 0.0
               (map (lambda (i) (let ((d (- (nth x-indices i) x-mean)))
                                  (* d d)))
                    (range n))))
        (slope (if (= den 0.0) 0.0 (/ num den)))
        (intercept (- y-mean (* slope x-mean))))
    (map (lambda (i) (- (nth xs i) (+ intercept (* slope (nth x-indices i)))))
         (range n))))

;; ── Step: Regime — Variance Ratio ──────────────────────────────────

(define (step-var-ratio! [bank : IndicatorBank] [close : f64])
  (ring-push! (:var-ratio-buf bank) close))

(define (compute-variance-ratio [bank : IndicatorBank])
  : f64
  ;; Variance at scale N / (N × variance at scale 1). Close buffer(30).
  ;; N = 5. Compare multi-step to single-step variance.
  (let ((buf (:var-ratio-buf bank)))
    (if (< (:len buf) 10) 1.0
      (let ((prices (ring-to-list buf))
            (n (length prices))
            ;; Single-step returns
            (returns-1 (map (lambda (i)
                              (let ((p0 (nth prices i))
                                    (p1 (nth prices (+ i 1))))
                                (if (= p0 0.0) 0.0 (ln (/ p1 p0)))))
                            (range (- n 1))))
            ;; 5-step returns
            (returns-5 (map (lambda (i)
                              (let ((p0 (nth prices i))
                                    (p1 (nth prices (+ i 5))))
                                (if (= p0 0.0) 0.0 (ln (/ p1 p0)))))
                            (range (- n 5))))
            (var-1 (variance returns-1))
            (var-5 (variance returns-5)))
        (if (= var-1 0.0) 1.0
          (/ var-5 (* 5.0 var-1)))))))

;; ── Step: Regime — Entropy Rate ────────────────────────────────────

(define (step-entropy! [bank : IndicatorBank] [close : f64])
  ;; Discretize the return and push into entropy buffer
  (let ((ret (if (= (:prev-close bank) 0.0) 0.0
               (/ (- close (:prev-close bank)) (:prev-close bank))))
        ;; Discretize into bins: -2 (strong down), -1 (down), 0, +1 (up), +2 (strong up)
        (bin (cond
               ((< ret -0.005) -2.0)
               ((< ret -0.001) -1.0)
               ((< ret  0.001)  0.0)
               ((< ret  0.005)  1.0)
               (else            2.0))))
    (ring-push! (:entropy-buf bank) bin)))

(define (compute-entropy-rate [bank : IndicatorBank])
  : f64
  ;; Conditional entropy of discretized returns over buffer(30).
  ;; H(X_t | X_{t-1}) = -sum P(x_t, x_{t-1}) log P(x_t | x_{t-1})
  (let ((buf (:entropy-buf bank)))
    (if (< (:len buf) 5) 1.0
      (let ((vals (ring-to-list buf))
            (n (length vals))
            ;; Count transition pairs
            (pairs (map (lambda (i) (list (nth vals i) (nth vals (+ i 1))))
                        (range (- n 1))))
            (total (length pairs))
            ;; Compute joint probabilities via counting
            ;; Simplified: compute marginal entropy as approximation
            (counts (map (lambda (b) (count (lambda (v) (= v b)) vals))
                         (list -2.0 -1.0 0.0 1.0 2.0)))
            (probs (filter (lambda (p) (> p 0.0))
                           (map (lambda (c) (/ c n)) counts)))
            (entropy (- (fold-left + 0.0
                          (map (lambda (p) (* p (ln p))) probs)))))
        entropy))))

;; ── Step: Regime — Aroon ───────────────────────────────────────────

(define (step-aroon! [bank : IndicatorBank] [high : f64] [low : f64])
  (ring-push! (:aroon-high-buf bank) high)
  (ring-push! (:aroon-low-buf bank) low))

(define (compute-aroon-up [bank : IndicatorBank])
  : f64
  ;; 100 × (25 - periods-since-highest) / 25
  (let ((buf (:aroon-high-buf bank)))
    (if (not (ring-full? buf)) 50.0
      (let ((vals (ring-to-list buf))
            (n (length vals))
            (max-val (apply max vals))
            ;; Find the index of the most recent max
            (idx (fold-left (lambda (best i)
                              (if (= (nth vals i) max-val) i best))
                            0 (range n))))
        (* 100.0 (/ idx (- n 1.0)))))))

(define (compute-aroon-down [bank : IndicatorBank])
  : f64
  ;; 100 × (25 - periods-since-lowest) / 25
  (let ((buf (:aroon-low-buf bank)))
    (if (not (ring-full? buf)) 50.0
      (let ((vals (ring-to-list buf))
            (n (length vals))
            (min-val (apply min vals))
            (idx (fold-left (lambda (best i)
                              (if (= (nth vals i) min-val) i best))
                            0 (range n))))
        (* 100.0 (/ idx (- n 1.0)))))))

;; ── Step: Regime — Fractal Dimension ───────────────────────────────

(define (step-fractal! [bank : IndicatorBank] [close : f64])
  (ring-push! (:fractal-buf bank) close))

(define (compute-fractal-dim [bank : IndicatorBank])
  : f64
  ;; Higuchi method over close buffer(30).
  ;; 1.0 = trending, 2.0 = noisy.
  (let ((buf (:fractal-buf bank)))
    (if (< (:len buf) 10) 1.5
      (let ((prices (ring-to-list buf))
            (n (length prices))
            ;; Higuchi: compute curve lengths at scales k=1,2,4
            (l1 (higuchi-length prices 1))
            (l2 (higuchi-length prices 2))
            (l4 (higuchi-length prices 4)))
        (if (or (<= l1 0.0) (<= l4 0.0)) 1.5
          ;; D = -slope of log(L(k)) vs log(k)
          ;; Two-point estimate: (log(L1) - log(L4)) / (log(4) - log(1))
          (let ((d (/ (- (ln l1) (ln l4)) (ln 4.0))))
            (clamp d 1.0 2.0)))))))

(define (higuchi-length [prices : Vec<f64>] [k : usize])
  : f64
  ;; Average curve length at scale k.
  (let ((n (length prices))
        (lengths
          (filter-map
            (lambda (m)
              (if (> m k) None
                (let ((num-steps (/ (- n m) k))
                      (sum (fold-left + 0.0
                             (map (lambda (i)
                                    (abs (- (nth prices (+ m (* (+ i 1) k)))
                                            (nth prices (+ m (* i k))))))
                                  (range num-steps)))))
                  (if (= num-steps 0) None
                    (Some (/ (* sum (- n 1.0))
                             (* num-steps k k)))))))
            (range k))))
    (if (empty? lengths) 0.0
      (mean lengths))))

;; ── Step: Divergence — RSI vs Price ────────────────────────────────

(define (step-divergence! [bank : IndicatorBank] [close : f64])
  (ring-push! (:price-peak-buf bank) close)
  (when (rsi-ready? (:rsi bank))
    (ring-push! (:rsi-peak-buf bank) (rsi-value (:rsi bank)))))

(define (compute-rsi-divergence-bull [bank : IndicatorBank])
  : f64
  ;; Bull: price makes lower low, RSI makes higher low.
  ;; Magnitude = |price-slope - rsi-slope|.
  (divergence-magnitude (:price-peak-buf bank) (:rsi-peak-buf bank) :bull))

(define (compute-rsi-divergence-bear [bank : IndicatorBank])
  : f64
  ;; Bear: price makes higher high, RSI makes lower high.
  (divergence-magnitude (:price-peak-buf bank) (:rsi-peak-buf bank) :bear))

(define (divergence-magnitude [price-buf : RingBuffer] [rsi-buf : RingBuffer] [kind : Symbol])
  : f64
  ;; PELT-inspired peak detection and divergence scoring.
  ;; Simplified: compare slopes of recent lows (bull) or highs (bear).
  (if (or (< (:len price-buf) 5) (< (:len rsi-buf) 5))
    0.0
    (let ((prices (ring-to-list price-buf))
          (rsis (ring-to-list rsi-buf))
          (n (min (length prices) (length rsis)))
          ;; Split into two halves and compare extremes
          (half (/ n 2))
          (first-prices (take prices half))
          (second-prices (last-n prices half))
          (first-rsis (take rsis half))
          (second-rsis (last-n rsis half)))
      (match kind
        (:bull
          ;; Price lower low, RSI higher low
          (let ((price-low-1 (apply min first-prices))
                (price-low-2 (apply min second-prices))
                (rsi-low-1 (apply min first-rsis))
                (rsi-low-2 (apply min second-rsis)))
            (if (and (< price-low-2 price-low-1) (> rsi-low-2 rsi-low-1))
              (abs (- (- price-low-2 price-low-1) (- rsi-low-2 rsi-low-1)))
              0.0)))
        (:bear
          ;; Price higher high, RSI lower high
          (let ((price-high-1 (apply max first-prices))
                (price-high-2 (apply max second-prices))
                (rsi-high-1 (apply max first-rsis))
                (rsi-high-2 (apply max second-rsis)))
            (if (and (> price-high-2 price-high-1) (< rsi-high-2 rsi-high-1))
              (abs (- (- price-high-2 price-high-1) (- rsi-high-2 rsi-high-1)))
              0.0)))))))

;; ── Step: Ichimoku Cross Delta ─────────────────────────────────────

(define (compute-tk-cross-delta [bank : IndicatorBank])
  : f64
  ;; (tenkan - kijun) change from prev candle. Signed.
  (let ((current-spread (- (ichimoku-tenkan (:ichimoku bank))
                           (ichimoku-kijun (:ichimoku bank)))))
    (- current-spread (:prev-tk-spread bank))))

;; ── Step: Stochastic Cross Delta ───────────────────────────────────

(define (compute-stoch-cross-delta [bank : IndicatorBank])
  : f64
  ;; (%K - %D) change from prev candle. Signed.
  (let ((current-kd (- (stoch-k (:stoch bank)) (stoch-d (:stoch bank)))))
    (- current-kd (:prev-stoch-kd bank))))

;; ── Step: Price Action ─────────────────────────────────────────────

(define (step-price-action! [bank : IndicatorBank] [open : f64] [high : f64]
                             [low : f64] [close : f64])
  (let ((current-range (- high low)))
    ;; range-ratio
    ;; gap and consecutive are computed from prev-close, tracked below
    ;; Update consecutive counts
    (if (> close (:prev-close bank))
      (begin
        (set! bank :consecutive-up-count (+ (:consecutive-up-count bank) 1))
        (set! bank :consecutive-down-count 0))
      (if (< close (:prev-close bank))
        (begin
          (set! bank :consecutive-down-count (+ (:consecutive-down-count bank) 1))
          (set! bank :consecutive-up-count 0))
        (begin)))  ; unchanged — preserve counts
    (set! bank :prev-range current-range)))

(define (compute-range-ratio [bank : IndicatorBank] [high : f64] [low : f64])
  : f64
  (let ((current-range (- high low)))
    (if (= (:prev-range bank) 0.0) 1.0
      (/ current-range (:prev-range bank)))))

(define (compute-gap [bank : IndicatorBank] [open : f64])
  : f64
  (if (= (:prev-close bank) 0.0) 0.0
    (/ (- open (:prev-close bank)) (:prev-close bank))))

;; ── Step: Williams %R ──────────────────────────────────────────────
;; Williams %R uses the same high/low buffers as Stochastic (period 14).

(define (compute-williams-r [bank : IndicatorBank] [close : f64])
  : f64
  ;; (highest14 - close) / (highest14 - lowest14) × -100
  (let ((high-buf (:high-buf (:stoch bank)))
        (low-buf (:low-buf (:stoch bank))))
    (if (not (ring-full? high-buf)) -50.0
      (let ((highest (ring-max high-buf))
            (lowest (ring-min low-buf))
            (range (- highest lowest)))
        (if (= range 0.0) -50.0
          (* -100.0 (/ (- highest close) range)))))))

;; ── Step: OBV Slope ────────────────────────────────────────────────

(define (compute-obv-slope-12 [bank : IndicatorBank])
  : f64
  ;; 12-period linear regression slope of OBV history
  (let ((buf (:history (:obv bank))))
    (if (< (:len buf) 3) 0.0
      (let ((vals (ring-to-list buf))
            (n (length vals)))
        (linear-regression-slope vals)))))

(define (linear-regression-slope [ys : Vec<f64>])
  : f64
  ;; Slope of best-fit line through (0,y0), (1,y1), ..., (n-1,y_{n-1}).
  (let ((n (length ys))
        (x-mean (/ (- n 1.0) 2.0))
        (y-mean (mean ys))
        (num (fold-left + 0.0
               (map (lambda (i) (* (- i x-mean) (- (nth ys i) y-mean)))
                    (range n))))
        (den (fold-left + 0.0
               (map (lambda (i) (let ((d (- i x-mean))) (* d d)))
                    (range n)))))
    (if (= den 0.0) 0.0 (/ num den))))

;; ── Step: ATR ROC ──────────────────────────────────────────────────

(define (compute-atr-roc [bank : IndicatorBank] [n : usize])
  : f64
  ;; ROC of ATR at lag n. Same formula as price ROC applied to ATR.
  (let ((buf (:atr-history bank)))
    (if (< (:len buf) (+ n 1))
      0.0
      (let ((current (ring-newest buf))
            (past (ring-get buf (- (:len buf) 1 n))))
        (if (= past 0.0) 0.0
          (/ (- current past) past))))))

;; ── Step: Keltner Channel ──────────────────────────────────────────
;; Keltner = EMA(20) ± 2 × ATR. Computed from ema20 + atr.

(define (compute-kelt-upper [bank : IndicatorBank])
  : f64
  (+ (:value (:ema20 bank)) (* 2.0 (atr-value (:atr bank)))))

(define (compute-kelt-lower [bank : IndicatorBank])
  : f64
  (- (:value (:ema20 bank)) (* 2.0 (atr-value (:atr bank)))))

(define (compute-kelt-pos [bank : IndicatorBank] [close : f64])
  : f64
  (let ((upper (compute-kelt-upper bank))
        (lower (compute-kelt-lower bank))
        (range (- upper lower)))
    (if (= range 0.0) 0.5
      (/ (- close lower) range))))

(define (compute-squeeze [bank : IndicatorBank] [close : f64])
  : f64
  ;; bb-width / kelt-width ratio — continuous, not bool
  (let ((bb-w (compute-bb-width bank close))
        (kelt-w (let ((ku (compute-kelt-upper bank))
                      (kl (compute-kelt-lower bank)))
                  (if (= close 0.0) 0.0
                    (/ (- ku kl) close)))))
    (if (= kelt-w 0.0) 1.0
      (/ bb-w kelt-w))))

;; ── Time Parsing ───────────────────────────────────────────────────
;; Parse timestamp string to extract time components.
;; Format: "YYYY-MM-DDTHH:MM:SS" or similar ISO 8601.

(define (parse-minute [ts : String])
  : f64
  ;; Extract minute from timestamp
  (* 1.0 (parse-int (substring ts 14 16))))

(define (parse-hour [ts : String])
  : f64
  (* 1.0 (parse-int (substring ts 11 13))))

(define (parse-day-of-month [ts : String])
  : f64
  (* 1.0 (parse-int (substring ts 8 10))))

(define (parse-month [ts : String])
  : f64
  (* 1.0 (parse-int (substring ts 5 7))))

(define (parse-day-of-week [ts : String])
  : f64
  ;; Zeller's congruence or similar — returns day of week [0, 6]
  ;; Implementation detail: Rust provides chrono. The wat specifies the interface.
  (let ((year (parse-int (substring ts 0 4)))
        (month (parse-int (substring ts 5 7)))
        (day (parse-int (substring ts 8 10))))
    ;; Tomohiko Sakamoto's algorithm
    (let ((t (list 0 3 2 5 0 3 5 1 4 6 2 4))
          (y (if (< month 3) (- year 1) year)))
      (mod (+ y (/ y 4) (- (/ y 100)) (/ y 400) (nth t (- month 1)) day) 7.0))))


;; ════════════════════════════════════════════════════════════════════
;; TICK — the main entry point. One raw candle in, one enriched Candle out.
;; ════════════════════════════════════════════════════════════════════

(define (tick [bank : IndicatorBank] [raw : RawCandle])
  : Candle
  (let ((open   (:open raw))
        (high   (:high raw))
        (low    (:low raw))
        (close  (:close raw))
        (volume (:volume raw))
        (ts     (:ts raw)))

    ;; ── 1. Advance all streaming primitives ──────────────────────
    (step-sma! bank close)
    (step-bollinger! bank close)
    (step-rsi! bank close)
    (step-macd! bank close)
    (step-dmi! bank high low close)
    (step-atr! bank high low close)
    (step-stoch! bank high low close)
    (step-cci! bank high low close)
    (step-mfi! bank high low close volume)
    (step-obv! bank close volume)
    (step-volume-sma! bank volume)
    (step-roc! bank close)
    (step-range-pos! bank high low)
    (step-trend-consistency! bank close)
    (step-timeframe! bank close high low)
    (step-ichimoku! bank high low)
    (step-persistence! bank close)
    (step-vwap! bank close volume)
    (step-kama-er! bank close)
    (step-choppiness! bank)
    (step-dfa! bank close)
    (step-var-ratio! bank close)
    (step-entropy! bank close)
    (step-aroon! bank high low)
    (step-fractal! bank close)
    (step-divergence! bank close)
    (step-price-action! bank open high low close)

    ;; ── 2. Compute derived values ────────────────────────────────
    (let (;; Bollinger
          (bb-upper-val (compute-bb-upper bank))
          (bb-lower-val (compute-bb-lower bank))
          (bb-width-val (compute-bb-width bank close))
          (bb-pos-val (compute-bb-pos bank close))
          ;; Ichimoku
          (tenkan (ichimoku-tenkan (:ichimoku bank)))
          (kijun (ichimoku-kijun (:ichimoku bank)))
          (span-a (ichimoku-senkou-a (:ichimoku bank)))
          (span-b (ichimoku-senkou-b (:ichimoku bank)))
          ;; TK cross delta
          (tk-spread (- tenkan kijun))
          (tk-delta (- tk-spread (:prev-tk-spread bank)))
          ;; Stochastic cross delta
          (sk (stoch-k (:stoch bank)))
          (sd (stoch-d (:stoch bank)))
          (stoch-kd (- sk sd))
          (stoch-delta (- stoch-kd (:prev-stoch-kd bank)))
          ;; Keltner
          (ku (compute-kelt-upper bank))
          (kl (compute-kelt-lower bank))
          (kp (compute-kelt-pos bank close))
          (sq (compute-squeeze bank close))
          ;; Timeframe agreement
          (tf-agree (compute-tf-agreement bank close)))

      ;; ── 3. Update prev-state for next candle ───────────────────
      (set! bank :prev-tk-spread tk-spread)
      (set! bank :prev-stoch-kd stoch-kd)
      (set! bank :prev-close close)
      (inc! bank :count)

      ;; ── 4. Assemble the enriched Candle ────────────────────────
      (make-candle
        ;; Raw
        ts open high low close volume
        ;; Moving averages
        (sma-value (:sma20 bank))
        (sma-value (:sma50 bank))
        (sma-value (:sma200 bank))
        ;; Bollinger
        bb-upper-val bb-lower-val bb-width-val bb-pos-val
        ;; RSI, MACD, DMI, ATR
        (rsi-value (:rsi bank))
        (macd-value (:macd bank))
        (macd-signal-value (:macd bank))
        (macd-hist-value (:macd bank))
        (dmi-plus-di (:dmi bank))
        (dmi-minus-di (:dmi bank))
        (dmi-adx (:dmi bank))
        (atr-value (:atr bank))
        (if (= close 0.0) 0.0 (/ (atr-value (:atr bank)) close))  ; atr-r
        ;; Stochastic, CCI, MFI, OBV, Williams %R
        sk sd
        (compute-williams-r bank close)
        (cci-value (:cci bank))
        (mfi-value (:mfi bank))
        (compute-obv-slope-12 bank)
        (if (= (sma-value (:volume-sma20 bank)) 0.0) 1.0
          (/ volume (sma-value (:volume-sma20 bank))))  ; volume-accel
        ;; Keltner, squeeze
        ku kl kp sq
        ;; Rate of Change
        (compute-roc bank 1) (compute-roc bank 3)
        (compute-roc bank 6) (compute-roc bank 12)
        ;; ATR rate of change
        (compute-atr-roc bank 6) (compute-atr-roc bank 12)
        ;; Trend consistency
        (compute-trend-consistency bank 6)
        (compute-trend-consistency bank 12)
        (compute-trend-consistency bank 24)
        ;; Range position
        (compute-range-pos (:range-high-12 bank) (:range-low-12 bank) close)
        (compute-range-pos (:range-high-24 bank) (:range-low-24 bank) close)
        (compute-range-pos (:range-high-48 bank) (:range-low-48 bank) close)
        ;; Multi-timeframe
        (compute-tf-close (:tf-1h-buf bank))
        (compute-tf-high (:tf-1h-high bank))
        (compute-tf-low (:tf-1h-low bank))
        (compute-tf-ret (:tf-1h-buf bank))
        (compute-tf-body (:tf-1h-buf bank))
        (compute-tf-close (:tf-4h-buf bank))
        (compute-tf-high (:tf-4h-high bank))
        (compute-tf-low (:tf-4h-low bank))
        (compute-tf-ret (:tf-4h-buf bank))
        (compute-tf-body (:tf-4h-buf bank))
        ;; Ichimoku
        tenkan kijun span-a span-b
        (max span-a span-b)   ; cloud-top
        (min span-a span-b)   ; cloud-bottom
        ;; Persistence
        (compute-hurst bank)
        (compute-autocorrelation bank)
        (compute-vwap-distance bank close)
        ;; Regime
        (compute-kama-er bank)
        (compute-choppiness bank high low)
        (compute-dfa-alpha bank)
        (compute-variance-ratio bank)
        (compute-entropy-rate bank)
        (compute-aroon-up bank)
        (compute-aroon-down bank)
        (compute-fractal-dim bank)
        ;; Divergence
        (compute-rsi-divergence-bull bank)
        (compute-rsi-divergence-bear bank)
        ;; Cross deltas
        tk-delta
        stoch-delta
        ;; Price action
        (compute-range-ratio bank high low)
        (compute-gap bank open)
        (* 1.0 (:consecutive-up-count bank))
        (* 1.0 (:consecutive-down-count bank))
        ;; Timeframe agreement
        tf-agree
        ;; Time
        (parse-minute ts)
        (parse-hour ts)
        (parse-day-of-week ts)
        (parse-day-of-month ts)
        (parse-month ts)))))
