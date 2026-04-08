; indicator-bank.wat — streaming indicator state machine. Depends on: RawCandle.
;
; Advances all indicators by one raw candle. Stateful — ring buffers,
; EMA accumulators, Wilder smoothers. One per post (one per asset pair).
; Consumes raw candles, produces enriched Candles.

(require primitives)
(require raw-candle)

;; ── Time parsing — extract temporal components from timestamp string ──
;; These live here because parsing timestamps from raw candles is
;; indicator-bank's concern. time.wat uses the parsed Candle fields.

(define (parse-minute [ts : String])
  : f64
  (+ (substring ts 14 16) 0.0))

(define (parse-hour [ts : String])
  : f64
  (+ (substring ts 11 13) 0.0))

(define (parse-day-of-week [ts : String])
  : f64
  ; Tomohiko Sakamoto's algorithm. 0 = Sunday.
  (let* ((y (+ (substring ts 0 4) 0))
         (m (+ (substring ts 5 7) 0))
         (d (+ (substring ts 8 10) 0))
         (t (list 0 3 2 5 0 3 5 1 4 6 2 4))
         (y2 (if (< m 3) (- y 1) y)))
    (+ (mod (+ y2 (/ y2 4) (- (/ y2 100)) (/ y2 400)
               (nth t (- m 1)) d)
            7)
       0.0)))

(define (parse-day-of-month [ts : String])
  : f64
  (+ (substring ts 8 10) 0.0))

(define (parse-month [ts : String])
  : f64
  (+ (substring ts 5 7) 0.0))

;; ── Streaming primitives — the building blocks of indicator state ────

;; Leaves — depend on nothing
(struct ring-buffer
  [data     : Vec<f64>]
  [capacity : usize]
  [head     : usize]
  [len      : usize])

(struct ema-state
  [value     : f64]
  [smoothing : f64]
  [period    : usize]
  [count     : usize]
  [accum     : f64])

(struct wilder-state
  [value  : f64]
  [period : usize]
  [count  : usize]
  [accum  : f64])

(struct rsi-state
  [gain-smoother : WilderState]
  [loss-smoother : WilderState]
  [prev-close    : f64]
  [started       : bool])

(struct atr-state
  [wilder     : WilderState]
  [prev-close : f64]
  [started    : bool])

(struct obv-state
  [obv        : f64]
  [prev-close : f64]
  [history    : RingBuffer]
  [started    : bool])  ; for computing obv-slope-12 via linear regression

;; Depend on RingBuffer
(struct sma-state
  [buffer : RingBuffer]
  [sum    : f64]
  [period : usize])

(struct rolling-stddev
  [buffer : RingBuffer]
  [sum    : f64]
  [sum-sq : f64]
  [period : usize])

(struct stoch-state
  [high-buf : RingBuffer]
  [low-buf  : RingBuffer]
  [k-buf    : RingBuffer])  ; %K history for computing %D (3-period SMA of %K)

(struct cci-state
  [tp-buf : RingBuffer]
  [tp-sma : SmaState])

(struct mfi-state
  [pos-flow-buf : RingBuffer]
  [neg-flow-buf : RingBuffer]
  [prev-tp      : f64]
  [started      : bool])

(struct ichimoku-state
  [high-9  : RingBuffer]  [low-9  : RingBuffer]
  [high-26 : RingBuffer]  [low-26 : RingBuffer]
  [high-52 : RingBuffer]  [low-52 : RingBuffer])

;; Depend on EmaState
(struct macd-state
  [fast-ema   : EmaState]
  [slow-ema   : EmaState]
  [signal-ema : EmaState])

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

;; ── The indicator bank — composed from streaming primitives ──────────

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
  [volume-sma20 : SmaState]   ; internal — for volume ratio computation in flow vocab
  ;; ROC
  [roc-buf : RingBuffer]      ; 12-period close buffer — ROC 1/3/6/12 index into this
  ;; Range position
  [range-high-12 : RingBuffer]  [range-low-12 : RingBuffer]
  [range-high-24 : RingBuffer]  [range-low-24 : RingBuffer]
  [range-high-48 : RingBuffer]  [range-low-48 : RingBuffer]
  ;; Trend consistency
  [trend-buf-24 : RingBuffer]
  ;; ATR history
  [atr-history : RingBuffer]  ; for computing atr-r (ATR ratio) on Candle
  ;; Multi-timeframe
  [tf-1h-buf  : RingBuffer]  [tf-1h-high : RingBuffer]  [tf-1h-low : RingBuffer]
  [tf-4h-buf  : RingBuffer]  [tf-4h-high : RingBuffer]  [tf-4h-low : RingBuffer]
  ;; Ichimoku
  [ichimoku : IchimokuState]
  ;; Persistence — pre-computed from ring buffers
  [close-buf-48 : RingBuffer]  ; 48 closes for Hurst + autocorrelation
  ;; VWAP — running accumulation
  [vwap-cum-vol : f64]         ; cumulative volume
  [vwap-cum-pv  : f64]         ; cumulative price * volume
  ;; Regime — state for regime.wat fields
  [kama-er-buf : RingBuffer]   ; 10-period close buffer for KAMA efficiency ratio
  [chop-atr-sum : f64]         ; running sum of ATR over choppiness period
  [chop-buf : RingBuffer]      ; 14-period ATR buffer for Choppiness Index
  [dfa-buf : RingBuffer]       ; close buffer for Detrended Fluctuation Analysis
  [var-ratio-buf : RingBuffer] ; close buffer for variance ratio (two scales)
  [entropy-buf : RingBuffer]   ; discretized return buffer for conditional entropy
  [aroon-high-buf : RingBuffer] ; 25-period high buffer for Aroon up
  [aroon-low-buf : RingBuffer]  ; 25-period low buffer for Aroon down
  [fractal-buf : RingBuffer]   ; close buffer for fractal dimension (Higuchi or box-counting)
  ;; Divergence — state for divergence.wat fields
  [rsi-peak-buf : RingBuffer]  ; recent RSI values for PELT peak detection
  [price-peak-buf : RingBuffer] ; recent close values aligned with RSI for divergence
  ;; Ichimoku cross delta — prev TK spread
  [prev-tk-spread : f64]       ; (tenkan - kijun) from previous candle
  ;; Stochastic cross delta — prev K-D spread
  [prev-stoch-kd : f64]        ; (stoch-k - stoch-d) from previous candle
  ;; Price action — state for price-action.wat fields
  [prev-range : f64]           ; previous candle range (high - low) for range-ratio
  [consecutive-up-count : usize]  ; running count of consecutive bullish closes
  [consecutive-down-count : usize] ; running count of consecutive bearish closes
  ;; Timeframe agreement — prev returns for direction comparison
  [prev-tf-1h-ret : f64]       ; previous 1h return for direction tracking
  [prev-tf-4h-ret : f64]       ; previous 4h return for direction tracking
  ;; Previous values
  [prev-close : f64]
  ;; Counter
  [count : usize])


;; ════════════════════════════════════════════════════════════════════════
;; Ring buffer operations
;; ════════════════════════════════════════════════════════════════════════

(define (make-ring-buffer [capacity : usize])
  : RingBuffer
  (ring-buffer (zeros capacity) capacity 0 0))

(define (ring-push! [rb : RingBuffer] [value : f64])
  ; Push a value. If full, overwrite the oldest entry.
  (set! (:data rb) (:head rb) value)
  (set! (:head rb) (mod (+ (:head rb) 1) (:capacity rb)))
  (when (< (:len rb) (:capacity rb))
    (inc! (:len rb))))

(define (ring-oldest [rb : RingBuffer])
  : f64
  ; The oldest value in the buffer.
  (if (= (:len rb) 0)
    0.0
    (let* ((start (if (< (:len rb) (:capacity rb))
                    0
                    (:head rb))))
      (nth (:data rb) start))))

(define (ring-newest [rb : RingBuffer])
  : f64
  ; The most recent value pushed.
  (if (= (:len rb) 0)
    0.0
    (let* ((idx (mod (+ (- (:head rb) 1) (:capacity rb)) (:capacity rb))))
      (nth (:data rb) idx))))

(define (ring-full? [rb : RingBuffer])
  : bool
  (= (:len rb) (:capacity rb)))

(define (ring-len [rb : RingBuffer])
  : usize
  (:len rb))

(define (ring-get [rb : RingBuffer] [i : usize])
  : f64
  ; Get the i-th oldest element (0 = oldest).
  (let* ((start (if (< (:len rb) (:capacity rb))
                  0
                  (:head rb)))
         (idx (mod (+ start i) (:capacity rb))))
    (nth (:data rb) idx)))

(define (ring-get-from-end [rb : RingBuffer] [offset : usize])
  : f64
  ; Get element at offset from the end (0 = newest).
  (ring-get rb (- (:len rb) 1 offset)))

(define (ring-max [rb : RingBuffer])
  : f64
  ; Maximum value across all entries.
  (if (= (:len rb) 0)
    f64-neg-infinity
    (fold max f64-neg-infinity
      (map (lambda (i) (ring-get rb i))
           (range 0 (:len rb))))))

(define (ring-min [rb : RingBuffer])
  : f64
  ; Minimum value across all entries.
  (if (= (:len rb) 0)
    f64-infinity
    (fold min f64-infinity
      (map (lambda (i) (ring-get rb i))
           (range 0 (:len rb))))))

(define (ring-sum [rb : RingBuffer])
  : f64
  (fold + 0.0
    (map (lambda (i) (ring-get rb i))
         (range 0 (:len rb)))))

(define (ring-to-list [rb : RingBuffer])
  : List<f64>
  ; Returns elements oldest-first.
  (map (lambda (i) (ring-get rb i))
       (range 0 (:len rb))))

(define (ring-argmax [rb : RingBuffer])
  : usize
  ; Index of the maximum value (0 = oldest). For Aroon.
  (let* ((vals (ring-to-list rb))
         (mx (ring-max rb)))
    (fold-left (lambda (best i)
                 (if (= (nth vals i) mx) i best))
               0
               (range 0 (length vals)))))

(define (ring-argmin [rb : RingBuffer])
  : usize
  ; Index of the minimum value (0 = oldest). For Aroon.
  (let* ((vals (ring-to-list rb))
         (mn (ring-min rb)))
    (fold-left (lambda (best i)
                 (if (= (nth vals i) mn) i best))
               0
               (range 0 (length vals)))))


;; ════════════════════════════════════════════════════════════════════════
;; SMA — sliding window average, O(1) per step via running sum
;; ════════════════════════════════════════════════════════════════════════

(define (make-sma [period : usize])
  : SmaState
  (sma-state (make-ring-buffer period) 0.0 period))

(define (sma-step! [s : SmaState] [value : f64])
  : f64
  ; Advance the SMA by one value. Returns 0.0 during warmup.
  (let* ((was-full (ring-full? (:buffer s)))
         (old-val  (if was-full (ring-oldest (:buffer s)) 0.0)))
    (ring-push! (:buffer s) value)
    (set! (:sum s) (+ (:sum s) value))
    (when was-full
      (set! (:sum s) (- (:sum s) old-val)))
    (if (< (ring-len (:buffer s)) (:period s))
      0.0
      (/ (:sum s) (:period s)))))


;; ════════════════════════════════════════════════════════════════════════
;; EMA — exponential moving average with SMA seed (ta-lib canonical)
;; ════════════════════════════════════════════════════════════════════════

(define (make-ema [period : usize])
  : EmaState
  (ema-state 0.0                          ; value
             (/ 2.0 (+ period 1.0))       ; smoothing = 2 / (period + 1)
             period
             0                            ; count
             0.0))                        ; accum

(define (ema-step! [s : EmaState] [value : f64])
  : f64
  ; First `period` values averaged as SMA seed, then EMA recursive.
  ; Returns 0.0 during warmup (count < period).
  (inc! (:count s))
  (if (<= (:count s) (:period s))
    (begin
      (set! (:accum s) (+ (:accum s) value))
      (if (= (:count s) (:period s))
        (begin
          (set! (:value s) (/ (:accum s) (:period s)))
          (:value s))
        0.0))
    (begin
      (set! (:value s)
            (+ (* value (:smoothing s))
               (* (:value s) (- 1.0 (:smoothing s)))))
      (:value s))))


;; ════════════════════════════════════════════════════════════════════════
;; Wilder smoothing — O(1) after warmup. Matches ta-lib RSI/ATR/DMI.
;; ════════════════════════════════════════════════════════════════════════

(define (make-wilder [period : usize])
  : WilderState
  (wilder-state 0.0 period 0 0.0))

(define (wilder-step! [s : WilderState] [value : f64])
  : f64
  ; During warmup (count < period): accumulate, return 0.0.
  ; At count == period: initial average.
  ; After: Wilder smooth = (prev * (period - 1) + value) / period.
  (inc! (:count s))
  (let* ((period-float (+ (:period s) 0.0)))
    (if (<= (:count s) (:period s))
      (begin
        (set! (:accum s) (+ (:accum s) value))
        (if (= (:count s) (:period s))
          (begin
            (set! (:value s) (/ (:accum s) period-float))
            (:value s))
          0.0))
      (begin
        (set! (:value s)
              (/ (+ (* (:value s) (- period-float 1.0)) value) period-float))
        (:value s)))))


;; ════════════════════════════════════════════════════════════════════════
;; Rolling standard deviation — O(1) via running sum + sum-of-squares
;; ════════════════════════════════════════════════════════════════════════

(define (make-rolling-stddev [period : usize])
  : RollingStddev
  (rolling-stddev (make-ring-buffer period) 0.0 0.0 period))

(define (rolling-stddev-step! [s : RollingStddev] [value : f64])
  : f64
  ; Returns population stddev over the window. 0.0 during warmup.
  (let* ((was-full (ring-full? (:buffer s)))
         (old-val  (if was-full (ring-oldest (:buffer s)) 0.0)))
    (ring-push! (:buffer s) value)
    (set! (:sum s) (+ (:sum s) value))
    (set! (:sum-sq s) (+ (:sum-sq s) (* value value)))
    (when was-full
      (set! (:sum s) (- (:sum s) old-val))
      (set! (:sum-sq s) (- (:sum-sq s) (* old-val old-val))))
    (if (< (ring-len (:buffer s)) (:period s))
      0.0
      (let* ((n    (+ (:period s) 0.0))
             (mean (/ (:sum s) n))
             (var  (- (/ (:sum-sq s) n) (* mean mean))))
        (sqrt (max 0.0 var))))))


;; ════════════════════════════════════════════════════════════════════════
;; RSI — Wilder's relative strength index
;; ════════════════════════════════════════════════════════════════════════

(define (make-rsi [period : usize])
  : RsiState
  (rsi-state (make-wilder period)   ; gain-smoother
             (make-wilder period)   ; loss-smoother
             0.0                    ; prev-close
             false))                ; started

(define (rsi-step! [s : RsiState] [close : f64])
  : f64
  ; Returns RSI in [0, 100]. 50.0 during warmup.
  (if (not (:started s))
    (begin
      (set! (:started s) true)
      (set! (:prev-close s) close)
      50.0)
    (let* ((change   (- close (:prev-close s)))
           (gain     (max 0.0 change))
           (loss     (max 0.0 (- change)))
           (avg-gain (wilder-step! (:gain-smoother s) gain))
           (avg-loss (wilder-step! (:loss-smoother s) loss)))
      (set! (:prev-close s) close)
      (if (and (= avg-gain 0.0) (= avg-loss 0.0))
        50.0
        (- 100.0 (/ 100.0 (+ 1.0 (/ avg-gain (max avg-loss 1e-10)))))))))


;; ════════════════════════════════════════════════════════════════════════
;; ATR — average true range via Wilder smoothing
;; ════════════════════════════════════════════════════════════════════════

(define (make-atr [period : usize])
  : AtrState
  (atr-state (make-wilder period) 0.0 false))

(define (atr-step! [s : AtrState] [high : f64] [low : f64] [close : f64])
  : f64
  ; True range = max(high-low, |high-prev_close|, |low-prev_close|).
  ; Smoothed by Wilder. Returns 0.0 during warmup.
  (let* ((tr (if (not (:started s))
               (begin
                 (set! (:started s) true)
                 (set! (:prev-close s) close)
                 (- high low))
               (let* ((tr (max (- high low)
                               (max (abs (- high (:prev-close s)))
                                    (abs (- low (:prev-close s)))))))
                 (set! (:prev-close s) close)
                 tr))))
    (wilder-step! (:wilder s) tr)))


;; ════════════════════════════════════════════════════════════════════════
;; MACD — 12/26/9 EMA system
;; ════════════════════════════════════════════════════════════════════════

(define (make-macd)
  : MacdState
  (macd-state (make-ema 12) (make-ema 26) (make-ema 9)))

(define (macd-step! [s : MacdState] [close : f64])
  : (f64 f64 f64)
  ; Returns (macd-line, signal, histogram).
  (let* ((e12  (ema-step! (:fast-ema s) close))
         (e26  (ema-step! (:slow-ema s) close))
         (line (- e12 e26))
         (sig  (ema-step! (:signal-ema s) line))
         (hist (- line sig)))
    (list line sig hist)))


;; ════════════════════════════════════════════════════════════════════════
;; DMI / ADX — directional movement with two-phase ADX accumulation
;; ════════════════════════════════════════════════════════════════════════

(define (make-dmi [period : usize])
  : DmiState
  (dmi-state (make-wilder period)   ; plus-smoother
             (make-wilder period)   ; minus-smoother
             (make-wilder period)   ; tr-smoother
             (make-wilder period)   ; adx-smoother
             0.0 0.0 0.0           ; prev-high, prev-low, prev-close
             false                  ; started
             0                      ; count
             period))

(define (dmi-step! [s : DmiState] [high : f64] [low : f64] [close : f64])
  : (f64 f64 f64)
  ; Returns (+DI, -DI, ADX). All in [0, 100].
  (if (not (:started s))
    (begin
      (set! (:started s) true)
      (set! (:prev-high s) high)
      (set! (:prev-low s) low)
      (set! (:prev-close s) close)
      (set! (:count s) 1)
      (list 0.0 0.0 0.0))
    (begin
      (inc! (:count s))
      (let* ((up-move   (- high (:prev-high s)))
             (down-move (- (:prev-low s) low))
             (plus-dm   (if (and (> up-move down-move) (> up-move 0.0))
                          up-move 0.0))
             (minus-dm  (if (and (> down-move up-move) (> down-move 0.0))
                          down-move 0.0))
             (tr        (max (- high low)
                             (max (abs (- high (:prev-close s)))
                                  (abs (- low (:prev-close s))))))
             (sm-plus   (wilder-step! (:plus-smoother s) plus-dm))
             (sm-minus  (wilder-step! (:minus-smoother s) minus-dm))
             (sm-atr    (wilder-step! (:tr-smoother s) tr))
             (atr-val   (max sm-atr 1e-10))
             (dmi-plus  (/ (* sm-plus 100.0) atr-val))
             (dmi-minus (/ (* sm-minus 100.0) atr-val))
             (di-sum    (max (+ dmi-plus dmi-minus) 1e-10))
             (dx        (/ (* (abs (- dmi-plus dmi-minus)) 100.0) di-sum))
             ;; Two-phase ADX: only feed DX after DM/ATR warmup
             (adx       (if (>= (:count s) (:period s))
                          (wilder-step! (:adx-smoother s) dx)
                          0.0)))
        (set! (:prev-high s) high)
        (set! (:prev-low s) low)
        (set! (:prev-close s) close)
        (list dmi-plus dmi-minus adx)))))


;; ════════════════════════════════════════════════════════════════════════
;; Stochastic oscillator — %K, %D, Williams %R
;; ════════════════════════════════════════════════════════════════════════

(define (make-stoch [period : usize])
  : StochState
  (stoch-state (make-ring-buffer period)   ; high-buf
               (make-ring-buffer period)   ; low-buf
               (make-ring-buffer 3)))      ; k-buf for %D SMA(3)

(define (stoch-step! [s : StochState] [high : f64] [low : f64] [close : f64])
  : (f64 f64 f64)
  ; Returns (%K, %D, Williams %R). %K and %D in [0, 100]. Williams %R in [-100, 0].
  (ring-push! (:high-buf s) high)
  (ring-push! (:low-buf s) low)
  (let* ((hi    (ring-max (:high-buf s)))
         (lo    (ring-min (:low-buf s)))
         (range (max (- hi lo) 1e-10))
         (k     (* (/ (- close lo) range) 100.0))
         ;; %D = 3-period SMA of %K
         (_     (ring-push! (:k-buf s) k))
         (d     (if (< (ring-len (:k-buf s)) 3)
                  k
                  (/ (ring-sum (:k-buf s)) (ring-len (:k-buf s)))))
         ;; Williams %R
         (wr    (* -100.0 (/ (- hi close) range))))
    (list k d wr)))


;; ════════════════════════════════════════════════════════════════════════
;; CCI — Commodity Channel Index
;; ════════════════════════════════════════════════════════════════════════

(define (make-cci [period : usize])
  : CciState
  (cci-state (make-ring-buffer period)
             (make-sma period)))

(define (cci-step! [s : CciState] [high : f64] [low : f64] [close : f64])
  : f64
  ; CCI = (tp - SMA(tp)) / (0.015 * mean deviation of tp over period).
  (let* ((tp   (/ (+ high low close) 3.0))
         (mean (sma-step! (:tp-sma s) tp))
         (_    (ring-push! (:tp-buf s) tp))
         ;; Mean absolute deviation from the SMA
         (mad  (/ (fold + 0.0
                    (map (lambda (i) (abs (- (ring-get (:tp-buf s) i) mean)))
                         (range 0 (ring-len (:tp-buf s)))))
                  (max (ring-len (:tp-buf s)) 1))))
    (if (< mad 1e-10)
      0.0
      (/ (- tp mean) (* 0.015 mad)))))


;; ════════════════════════════════════════════════════════════════════════
;; MFI — Money Flow Index (windowed positive/negative flow)
;; ════════════════════════════════════════════════════════════════════════

(define (make-mfi [period : usize])
  : MfiState
  (mfi-state (make-ring-buffer period)    ; pos-flow-buf
             (make-ring-buffer period)    ; neg-flow-buf
             0.0                          ; prev-tp
             false))                      ; started

(define (mfi-step! [s : MfiState] [high : f64] [low : f64] [close : f64] [volume : f64])
  : f64
  ; Returns MFI in [0, 100]. 50.0 during warmup.
  (let* ((tp (/ (+ high low close) 3.0)))
    (if (not (:started s))
      (begin
        (set! (:started s) true)
        (set! (:prev-tp s) tp)
        50.0)
      (let* ((money-flow (* tp volume))
             (pos (if (> tp (:prev-tp s)) money-flow 0.0))
             (neg (if (<= tp (:prev-tp s)) money-flow 0.0)))
        (ring-push! (:pos-flow-buf s) pos)
        (ring-push! (:neg-flow-buf s) neg)
        (set! (:prev-tp s) tp)
        (if (not (ring-full? (:pos-flow-buf s)))
          50.0
          (let* ((pos-sum (ring-sum (:pos-flow-buf s)))
                 (neg-sum (ring-sum (:neg-flow-buf s))))
            (if (> neg-sum 1e-10)
              (- 100.0 (/ 100.0 (+ 1.0 (/ pos-sum neg-sum))))
              100.0)))))))


;; ════════════════════════════════════════════════════════════════════════
;; OBV — On-Balance Volume + 12-period linear regression slope
;; ════════════════════════════════════════════════════════════════════════

(define (make-obv [period : usize])
  : ObvState
  (obv-state 0.0 0.0 (make-ring-buffer period) false))

(define (obv-step! [s : ObvState] [close : f64] [volume : f64])
  : f64
  ; Returns the 12-period linear regression slope of OBV.
  (if (not (:started s))
    (begin
      (set! (:started s) true)
      (set! (:prev-close s) close)
      (ring-push! (:history s) 0.0)
      0.0)
    (begin
      (cond
        ((> close (:prev-close s)) (set! (:obv s) (+ (:obv s) volume)))
        ((< close (:prev-close s)) (set! (:obv s) (- (:obv s) volume))))
      (set! (:prev-close s) close)
      (ring-push! (:history s) (:obv s))
      ;; Linear regression slope over history
      (if (< (ring-len (:history s)) 2)
        0.0
        (linreg-slope (ring-to-list (:history s)))))))


;; ════════════════════════════════════════════════════════════════════════
;; Ichimoku Cloud — 9/26/52 period midpoint system
;; ════════════════════════════════════════════════════════════════════════

(define (make-ichimoku)
  : IchimokuState
  (ichimoku-state (make-ring-buffer 9)  (make-ring-buffer 9)
                  (make-ring-buffer 26) (make-ring-buffer 26)
                  (make-ring-buffer 52) (make-ring-buffer 52)))

(define (ichimoku-step! [s : IchimokuState] [high : f64] [low : f64])
  : (f64 f64 f64 f64 f64 f64)
  ; Returns (tenkan, kijun, span-a, span-b, cloud-top, cloud-bottom).
  (ring-push! (:high-9 s) high)  (ring-push! (:low-9 s) low)
  (ring-push! (:high-26 s) high) (ring-push! (:low-26 s) low)
  (ring-push! (:high-52 s) high) (ring-push! (:low-52 s) low)
  (let* ((tenkan (if (ring-full? (:high-9 s))
                   (/ (+ (ring-max (:high-9 s)) (ring-min (:low-9 s))) 2.0)
                   0.0))
         (kijun  (if (ring-full? (:high-26 s))
                   (/ (+ (ring-max (:high-26 s)) (ring-min (:low-26 s))) 2.0)
                   0.0))
         (span-b (if (ring-full? (:high-52 s))
                   (/ (+ (ring-max (:high-52 s)) (ring-min (:low-52 s))) 2.0)
                   0.0))
         (span-a (if (and (> tenkan 0.0) (> kijun 0.0))
                   (/ (+ tenkan kijun) 2.0)
                   0.0))
         (cloud-top    (if (and (> span-a 0.0) (> span-b 0.0))
                         (max span-a span-b)
                         0.0))
         (cloud-bottom (if (and (> span-a 0.0) (> span-b 0.0))
                         (min span-a span-b)
                         0.0)))
    (list tenkan kijun span-a span-b cloud-top cloud-bottom)))


;; ════════════════════════════════════════════════════════════════════════
;; Linear regression slope — general numeric utility
;; ════════════════════════════════════════════════════════════════════════

(define (linreg-slope [vals : List<f64>])
  : f64
  ; Least-squares slope of y = a + b*x where x = 0,1,...,n-1.
  (let* ((n   (+ (length vals) 0.0))
         (sx  (/ (* n (- n 1.0)) 2.0))
         (sy  (fold + 0.0 vals))
         (sxx (/ (* n (- n 1.0) (- (* 2.0 n) 1.0)) 6.0))
         (sxy (fold + 0.0
                (map (lambda (i) (* (+ i 0.0) (nth vals i)))
                     (range 0 (length vals)))))
         (denom (- (* n sxx) (* sx sx))))
    (if (< (abs denom) 1e-10)
      0.0
      (/ (- (* n sxy) (* sx sy)) denom))))


;; ════════════════════════════════════════════════════════════════════════
;; ROC — rate of change from ring buffer
;; ════════════════════════════════════════════════════════════════════════

(define (compute-roc [buf : RingBuffer] [close : f64] [period : usize])
  : f64
  ; (close - close_N_ago) / close_N_ago. 0.0 if not enough data.
  (if (< (ring-len buf) period)
    0.0
    (let* ((old (ring-get-from-end buf period)))
      (if (< (abs old) 1e-10) 0.0 (/ (- close old) old)))))


;; ════════════════════════════════════════════════════════════════════════
;; Range position — (close - lowest low) / (highest high - lowest low)
;; ════════════════════════════════════════════════════════════════════════

(define (compute-range-pos [hi-buf : RingBuffer] [lo-buf : RingBuffer]
                           [close : f64])
  : f64
  (let* ((hi (ring-max hi-buf))
         (lo (ring-min lo-buf))
         (range (- hi lo)))
    (if (< range 1e-10) 0.5 (/ (- close lo) range))))


;; ════════════════════════════════════════════════════════════════════════
;; Trend consistency — fraction of up-closes in last N candles
;; ════════════════════════════════════════════════════════════════════════

(define (compute-trend-consistency [buf : RingBuffer] [n : usize])
  : f64
  ; Count values > 0.5 in the last n entries. Returns 0.5 if not enough data.
  (if (< (ring-len buf) n)
    0.5
    (let* ((start (- (ring-len buf) n))
           (count (fold + 0.0
                    (map (lambda (i)
                           (if (> (ring-get buf (+ start i)) 0.5) 1.0 0.0))
                         (range 0 n)))))
      (/ count (+ n 0.0)))))


;; ════════════════════════════════════════════════════════════════════════
;; Multi-timeframe helpers
;; ════════════════════════════════════════════════════════════════════════

(define (tf-close-val [buf : RingBuffer] [fallback : f64])
  : f64
  (if (= (ring-len buf) 0) fallback (ring-newest buf)))

(define (tf-ret-val [buf : RingBuffer] [close : f64])
  : f64
  ; Return from oldest to newest in the buffer.
  (if (< (ring-len buf) 2)
    0.0
    (let* ((first (ring-oldest buf)))
      (if (< (abs first) 1e-10) 0.0 (/ (- close first) first)))))

(define (tf-body-val [buf : RingBuffer] [close : f64])
  : f64
  ; Absolute body = |close - open| / open over the timeframe.
  (if (< (ring-len buf) 2)
    0.0
    (let* ((first (ring-oldest buf)))
      (if (< (abs first) 1e-10) 0.0 (/ (abs (- close first)) first)))))


;; ════════════════════════════════════════════════════════════════════════
;; VWAP distance — (close - VWAP) / close
;; ════════════════════════════════════════════════════════════════════════

(define (compute-vwap-distance [cum-pv : f64] [cum-vol : f64] [close : f64])
  : f64
  (if (< cum-vol 1e-10)
    0.0
    (let* ((vwap (/ cum-pv cum-vol)))
      (if (< (abs close) 1e-10)
        0.0
        (/ (- close vwap) close)))))


;; ════════════════════════════════════════════════════════════════════════
;; Hurst exponent — rescaled range analysis
;; ════════════════════════════════════════════════════════════════════════

(define (compute-hurst [buf : RingBuffer])
  : f64
  ; Simplified Hurst exponent via rescaled range (R/S) analysis.
  ; Returns 0.5 (random walk) if not enough data.
  ; H > 0.5 = trending, H < 0.5 = mean-reverting.
  (if (< (ring-len buf) 20)
    0.5
    (let* ((vals (ring-to-list buf))
           (n (length vals))
           ;; Compute returns
           (returns (map (lambda (i)
                          (let* ((prev (nth vals (- i 1)))
                                 (curr (nth vals i)))
                            (if (< (abs prev) 1e-10) 0.0
                              (/ (- curr prev) prev))))
                        (range 1 n)))
           ;; Use two sub-series lengths for log-log regression
           (half-n  (/ n 2))
           (qtr-n   (/ n 4))
           ;; R/S for a sub-series of length k
           (rs-for  (lambda (k)
                      (if (< k 4)
                        1.0
                        (let* ((sub  (take k returns))
                               (mean (/ (fold + 0.0 sub) (+ k 0.0)))
                               (devs (map (lambda (r) (- r mean)) sub))
                               ;; Cumulative deviations
                               (cum  (fold-left (lambda (acc d)
                                                  (append acc (list (+ (last acc) d))))
                                                (list 0.0) devs))
                               (range-val (- (fold max f64-neg-infinity cum)
                                             (fold min f64-infinity cum)))
                               (stddev (sqrt (max 1e-20
                                               (/ (fold + 0.0
                                                    (map (lambda (d) (* d d)) devs))
                                                  (+ k 0.0))))))
                          (/ range-val (max stddev 1e-10))))))
           (rs1 (rs-for (max 4 qtr-n)))
           (rs2 (rs-for (max 8 half-n)))
           ;; H = log(RS2/RS1) / log(n2/n1)
           (n1 (max 4 qtr-n))
           (n2 (max 8 half-n)))
      (if (or (< rs1 1e-10) (< rs2 1e-10) (<= n1 0) (<= n2 n1))
        0.5
        (let* ((h (/ (ln (/ rs2 rs1)) (ln (/ (+ n2 0.0) (+ n1 0.0))))))
          (clamp h 0.0 1.0))))))


;; ════════════════════════════════════════════════════════════════════════
;; Autocorrelation — lag-1
;; ════════════════════════════════════════════════════════════════════════

(define (compute-autocorrelation [buf : RingBuffer])
  : f64
  ; Lag-1 autocorrelation of returns. [-1, 1]. 0 if not enough data.
  (if (< (ring-len buf) 10)
    0.0
    (let* ((vals (ring-to-list buf))
           (n (length vals))
           (returns (map (lambda (i)
                          (let* ((prev (nth vals (- i 1)))
                                 (curr (nth vals i)))
                            (if (< (abs prev) 1e-10) 0.0
                              (/ (- curr prev) prev))))
                        (range 1 n)))
           (m (length returns))
           (mean (/ (fold + 0.0 returns) (+ m 0.0)))
           (centered (map (lambda (r) (- r mean)) returns))
           ;; Variance
           (var (/ (fold + 0.0 (map (lambda (c) (* c c)) centered))
                   (+ m 0.0)))
           ;; Lag-1 covariance
           (cov (/ (fold + 0.0
                     (map (lambda (i) (* (nth centered i) (nth centered (- i 1))))
                          (range 1 (length centered))))
                   (+ m 0.0))))
      (if (< var 1e-20) 0.0
        (clamp (/ cov var) -1.0 1.0)))))


;; ════════════════════════════════════════════════════════════════════════
;; KAMA Efficiency Ratio — direction / volatility
;; ════════════════════════════════════════════════════════════════════════

(define (compute-kama-er [buf : RingBuffer])
  : f64
  ; ER = |close - close_10_ago| / sum(|close_i - close_{i-1}|). [0, 1].
  (if (< (ring-len buf) 10)
    0.0
    (let* ((vals (ring-to-list buf))
           (n (length vals))
           (direction (abs (- (last vals) (first vals))))
           (volatility (fold + 0.0
                         (map (lambda (i) (abs (- (nth vals i) (nth vals (- i 1)))))
                              (range 1 n)))))
      (if (< volatility 1e-10) 1.0
        (/ direction volatility)))))


;; ════════════════════════════════════════════════════════════════════════
;; Choppiness Index — 14-period ATR sum / (high-low range)
;; ════════════════════════════════════════════════════════════════════════

(define (compute-choppiness [chop-buf : RingBuffer]
                            [range-high : RingBuffer]
                            [range-low : RingBuffer])
  : f64
  ; CI = 100 * log10(sum(ATR_14) / (highest_high - lowest_low)) / log10(14).
  ; Returns 50.0 if not enough data. Range [0, 100].
  (if (not (ring-full? chop-buf))
    50.0
    (let* ((atr-sum (ring-sum chop-buf))
           (hi (ring-max range-high))
           (lo (ring-min range-low))
           (range (max (- hi lo) 1e-10)))
      (clamp (* 100.0 (/ (ln (/ atr-sum range)) (ln 14.0)))
             0.0 100.0))))


;; ════════════════════════════════════════════════════════════════════════
;; DFA — Detrended Fluctuation Analysis
;; ════════════════════════════════════════════════════════════════════════

(define (compute-dfa [buf : RingBuffer])
  : f64
  ; Simplified DFA exponent alpha. 0.5 = random walk.
  ; > 0.5 trending (persistent), < 0.5 anti-persistent.
  ; Uses two box sizes for log-log regression.
  (if (< (ring-len buf) 20)
    0.5
    (let* ((vals (ring-to-list buf))
           (n (length vals))
           (mean (/ (fold + 0.0 vals) (+ n 0.0)))
           ;; Cumulative deviation profile
           (profile (fold-left (lambda (acc v)
                                 (append acc (list (+ (last acc) (- v mean)))))
                               (list 0.0) vals))
           ;; Fluctuation for a given box size
           (fluctuation
             (lambda (box-size)
               (let* ((num-boxes (/ (- n 1) box-size))
                      (norm (/ (- (+ n 0.0) 1.0) (* (+ num-boxes 0.0) (+ box-size 0.0)))))
                 (if (< num-boxes 1) 1e-10
                   (let* ((flucts
                            (map (lambda (b)
                                   (let* ((start (* b box-size))
                                          (seg (map (lambda (j) (nth profile (+ start j)))
                                                    (range 0 (min box-size (- (length profile) start)))))
                                          (seg-len (length seg))
                                          ;; Linear detrend: fit y = a + b*x, compute RMS residual
                                          (slope (linreg-slope seg))
                                          (intercept (- (/ (fold + 0.0 seg) (+ seg-len 0.0))
                                                        (* slope (/ (- (+ seg-len 0.0) 1.0) 2.0))))
                                          (rms (sqrt (/ (fold + 0.0
                                                          (map (lambda (j)
                                                                 (let* ((trend (+ intercept (* slope (+ j 0.0))))
                                                                        (resid (- (nth seg j) trend)))
                                                                   (* resid resid)))
                                                               (range 0 seg-len)))
                                                        (max (+ seg-len 0.0) 1.0)))))
                                     rms))
                                 (range 0 num-boxes))))
                     (/ (fold + 0.0 flucts) (+ num-boxes 0.0)))))))
           ;; Two box sizes
           (s1 (max 4 (/ n 8)))
           (s2 (max 8 (/ n 4)))
           (f1 (fluctuation s1))
           (f2 (fluctuation s2)))
      (if (or (< f1 1e-10) (< f2 1e-10) (<= s1 0) (<= s2 s1))
        0.5
        (clamp (/ (ln (/ f2 f1)) (ln (/ (+ s2 0.0) (+ s1 0.0))))
               0.0 2.0)))))


;; ════════════════════════════════════════════════════════════════════════
;; Variance ratio — variance at scale N / (N * variance at scale 1)
;; ════════════════════════════════════════════════════════════════════════

(define (compute-variance-ratio [buf : RingBuffer])
  : f64
  ; Variance ratio test. 1.0 = random walk. > 1 trending. < 1 mean-reverting.
  (if (< (ring-len buf) 10)
    1.0
    (let* ((vals (ring-to-list buf))
           (n (length vals))
           ;; 1-period returns
           (ret1 (map (lambda (i)
                        (let* ((prev (nth vals (- i 1)))
                               (curr (nth vals i)))
                          (if (< (abs prev) 1e-10) 0.0
                            (ln (/ curr (max prev 1e-10))))))
                      (range 1 n)))
           (m1 (length ret1))
           (mean1 (/ (fold + 0.0 ret1) (+ m1 0.0)))
           (var1  (/ (fold + 0.0 (map (lambda (r) (* (- r mean1) (- r mean1))) ret1))
                     (+ m1 0.0)))
           ;; 5-period returns (scale = 5)
           (scale 5)
           (ret5 (filter-map
                   (lambda (i)
                     (if (>= (+ i scale) n)
                       None
                       (let* ((v0 (nth vals i))
                              (v5 (nth vals (+ i scale))))
                         (if (< (abs v0) 1e-10) None
                           (Some (ln (/ v5 (max v0 1e-10))))))))
                   (range 0 (- n scale))))
           (m5 (length ret5))
           (mean5 (if (= m5 0) 0.0 (/ (fold + 0.0 ret5) (+ m5 0.0))))
           (var5  (if (= m5 0) 0.0
                    (/ (fold + 0.0 (map (lambda (r) (* (- r mean5) (- r mean5))) ret5))
                       (+ m5 0.0)))))
      (if (< var1 1e-20) 1.0
        (/ var5 (* (+ scale 0.0) var1))))))


;; ════════════════════════════════════════════════════════════════════════
;; Entropy rate — conditional entropy of discretized returns
;; ════════════════════════════════════════════════════════════════════════

(define (compute-entropy-rate [buf : RingBuffer])
  : f64
  ; Discretize returns into bins, compute conditional entropy H(X_t | X_{t-1}).
  ; Higher = more random. Lower = more predictable.
  (if (< (ring-len buf) 10)
    1.0
    (let* ((vals (ring-to-list buf))
           (n (length vals))
           ;; Discretize returns into 3 bins: down (-1), flat (0), up (1)
           (bins (map (lambda (i)
                        (let* ((prev (nth vals (- i 1)))
                               (curr (nth vals i))
                               (ret (if (< (abs prev) 1e-10) 0.0
                                      (/ (- curr prev) prev))))
                          (cond
                            ((< ret -0.001) -1)
                            ((> ret  0.001)  1)
                            (true            0))))
                      (range 1 n)))
           (m (length bins))
           ;; Count transitions: pair (bins[i-1], bins[i])
           ;; 3x3 matrix, indexed by (prev+1, curr+1)
           (counts (zeros 9))
           (_  (for-each (lambda (i)
                           (let* ((prev-bin (+ (nth bins (- i 1)) 1))
                                  (curr-bin (+ (nth bins i) 1))
                                  (idx (+ (* prev-bin 3) curr-bin)))
                             (set! counts idx (+ (nth counts idx) 1.0))))
                         (range 1 m)))
           ;; Row sums (marginal counts for each prev state)
           (row-sums (map (lambda (r)
                            (+ (nth counts (* r 3))
                               (nth counts (+ (* r 3) 1))
                               (nth counts (+ (* r 3) 2))))
                          (range 0 3)))
           ;; Conditional entropy H(X|Y) = -sum P(x,y) log P(x|y)
           (total (+ m 0.0 -1.0))
           (h (if (< total 1.0) 1.0
                (- 0.0
                   (fold + 0.0
                     (map (lambda (idx)
                            (let* ((c (nth counts idx))
                                   (r (/ idx 3))
                                   (rs (nth row-sums r)))
                              (if (or (< c 0.5) (< rs 0.5))
                                0.0
                                (* (/ c total) (ln (/ c rs))))))
                          (range 0 9)))))))
      (max 0.0 h))))


;; ════════════════════════════════════════════════════════════════════════
;; Aroon — how recent was the high/low?
;; ════════════════════════════════════════════════════════════════════════

(define (compute-aroon-up [buf : RingBuffer])
  : f64
  ; Aroon Up = 100 * (period - periods_since_highest) / period.
  ; buf contains the last 25 highs.
  (if (< (ring-len buf) 2)
    50.0
    (let* ((n (ring-len buf))
           (max-idx (ring-argmax buf))
           (periods-since (- n 1 max-idx)))
      (* 100.0 (/ (- (+ n 0.0) 1.0 (+ periods-since 0.0)) (- (+ n 0.0) 1.0))))))

(define (compute-aroon-down [buf : RingBuffer])
  : f64
  ; Aroon Down = 100 * (period - periods_since_lowest) / period.
  (if (< (ring-len buf) 2)
    50.0
    (let* ((n (ring-len buf))
           (min-idx (ring-argmin buf))
           (periods-since (- n 1 min-idx)))
      (* 100.0 (/ (- (+ n 0.0) 1.0 (+ periods-since 0.0)) (- (+ n 0.0) 1.0))))))


;; ════════════════════════════════════════════════════════════════════════
;; Fractal dimension — Higuchi method
;; ════════════════════════════════════════════════════════════════════════

(define (compute-fractal-dim [buf : RingBuffer])
  : f64
  ; Higuchi fractal dimension. 1.0 = smooth trend. 2.0 = pure noise.
  ; Uses k=1 and k=4 for log-log regression.
  (if (< (ring-len buf) 16)
    1.5
    (let* ((vals (ring-to-list buf))
           (n (length vals))
           ;; Length for a given k (interval)
           (curve-length
             (lambda (k)
               (let* ((m-count (/ (- n 1) k))
                      (norm (/ (- (+ n 0.0) 1.0) (* (+ m-count 0.0) (+ k 0.0))))
                      ;; Average over m starting points
                      (avg (/ (fold + 0.0
                                (map (lambda (m)
                                       (* norm
                                          (fold + 0.0
                                            (map (lambda (i)
                                                   (abs (- (nth vals (min (+ m (* (+ i 1) k)) (- n 1)))
                                                           (nth vals (min (+ m (* i k)) (- n 1))))))
                                                 (range 0 (min m-count (/ (- n m) k)))))))
                                     (range 0 k)))
                              (+ k 0.0))))
                 (max avg 1e-20))))
           ;; Two scales
           (l1 (curve-length 1))
           (l4 (curve-length 4)))
      (if (or (< l1 1e-10) (< l4 1e-10))
        1.5
        (clamp (/ (ln (/ l1 l4)) (ln 4.0))
               1.0 2.0)))))


;; ════════════════════════════════════════════════════════════════════════
;; RSI divergence — via structural peak/trough detection
;; ════════════════════════════════════════════════════════════════════════

(define (compute-rsi-divergence [price-buf : RingBuffer]
                                [rsi-buf : RingBuffer])
  : (f64 f64)
  ; Returns (bull-divergence, bear-divergence) magnitudes.
  ; Bull: price makes lower low but RSI makes higher low.
  ; Bear: price makes higher high but RSI makes lower high.
  (if (< (ring-len price-buf) 10)
    (list 0.0 0.0)
    (let* ((prices (ring-to-list price-buf))
           (rsis   (ring-to-list rsi-buf))
           (n      (length prices))
           ;; Find recent troughs (local minima) — simplified: compare with neighbors
           (troughs
             (filter-map
               (lambda (i)
                 (if (and (> i 1) (< i (- n 1))
                          (< (nth prices i) (nth prices (- i 1)))
                          (< (nth prices i) (nth prices (+ i 1))))
                   (Some (list i (nth prices i) (nth rsis i)))
                   None))
               (range 1 (- n 1))))
           ;; Find recent peaks (local maxima)
           (peaks
             (filter-map
               (lambda (i)
                 (if (and (> i 1) (< i (- n 1))
                          (> (nth prices i) (nth prices (- i 1)))
                          (> (nth prices i) (nth prices (+ i 1))))
                   (Some (list i (nth prices i) (nth rsis i)))
                   None))
               (range 1 (- n 1))))
           ;; Bullish: last two troughs — price lower, RSI higher
           (bull (if (< (length troughs) 2) 0.0
                   (let* ((prev-trough (nth troughs (- (length troughs) 2)))
                          (last-trough (last troughs))
                          (price-lower (< (second last-trough) (second prev-trough)))
                          (rsi-higher  (> (nth last-trough 2) (nth prev-trough 2))))
                     (if (and price-lower rsi-higher)
                       (- (nth last-trough 2) (nth prev-trough 2))
                       0.0))))
           ;; Bearish: last two peaks — price higher, RSI lower
           (bear (if (< (length peaks) 2) 0.0
                   (let* ((prev-peak (nth peaks (- (length peaks) 2)))
                          (last-peak (last peaks))
                          (price-higher (> (second last-peak) (second prev-peak)))
                          (rsi-lower    (< (nth last-peak 2) (nth prev-peak 2))))
                     (if (and price-higher rsi-lower)
                       (abs (- (nth last-peak 2) (nth prev-peak 2)))
                       0.0)))))
      (list (max bull 0.0) (max bear 0.0)))))


;; ════════════════════════════════════════════════════════════════════════
;; Timeframe agreement — 5m, 1h, 4h direction alignment
;; ════════════════════════════════════════════════════════════════════════

(define (compute-tf-agreement [five-min-ret : f64]
                              [one-h-ret : f64]
                              [four-h-ret : f64])
  : f64
  ; Score: how many timeframes agree on direction?
  ; Each pair that agrees contributes +1/3. Range [0, 1].
  (let* ((s5 (signum five-min-ret))
         (s1 (signum one-h-ret))
         (s4 (signum four-h-ret))
         (agree-5-1 (if (= s5 s1) 1.0 0.0))
         (agree-5-4 (if (= s5 s4) 1.0 0.0))
         (agree-1-4 (if (= s1 s4) 1.0 0.0)))
    (/ (+ agree-5-1 agree-5-4 agree-1-4) 3.0)))


;; ════════════════════════════════════════════════════════════════════════
;; Constructor
;; ════════════════════════════════════════════════════════════════════════

(define (make-indicator-bank)
  : IndicatorBank
  (indicator-bank
    ;; Moving averages
    (make-sma 20)                 ; sma20
    (make-sma 50)                 ; sma50
    (make-sma 200)                ; sma200
    (make-ema 20)                 ; ema20
    ;; Bollinger
    (make-rolling-stddev 20)      ; bb-stddev
    ;; Oscillators
    (make-rsi 14)                 ; rsi
    (make-macd)                   ; macd
    (make-dmi 14)                 ; dmi
    (make-atr 14)                 ; atr
    (make-stoch 14)               ; stoch
    (make-cci 20)                 ; cci
    (make-mfi 14)                 ; mfi
    (make-obv 12)                 ; obv
    (make-sma 20)                 ; volume-sma20
    ;; ROC
    (make-ring-buffer 12)         ; roc-buf
    ;; Range position
    (make-ring-buffer 12) (make-ring-buffer 12)   ; range 12
    (make-ring-buffer 24) (make-ring-buffer 24)   ; range 24
    (make-ring-buffer 48) (make-ring-buffer 48)   ; range 48
    ;; Trend consistency
    (make-ring-buffer 24)         ; trend-buf-24
    ;; ATR history
    (make-ring-buffer 12)         ; atr-history
    ;; Multi-timeframe
    (make-ring-buffer 12) (make-ring-buffer 12) (make-ring-buffer 12)  ; 1h
    (make-ring-buffer 48) (make-ring-buffer 48) (make-ring-buffer 48)  ; 4h
    ;; Ichimoku
    (make-ichimoku)
    ;; Persistence
    (make-ring-buffer 48)         ; close-buf-48
    ;; VWAP
    0.0                           ; vwap-cum-vol
    0.0                           ; vwap-cum-pv
    ;; Regime
    (make-ring-buffer 10)         ; kama-er-buf
    0.0                           ; chop-atr-sum
    (make-ring-buffer 14)         ; chop-buf
    (make-ring-buffer 48)         ; dfa-buf
    (make-ring-buffer 30)         ; var-ratio-buf
    (make-ring-buffer 30)         ; entropy-buf
    (make-ring-buffer 25)         ; aroon-high-buf
    (make-ring-buffer 25)         ; aroon-low-buf
    (make-ring-buffer 32)         ; fractal-buf
    ;; Divergence
    (make-ring-buffer 30)         ; rsi-peak-buf
    (make-ring-buffer 30)         ; price-peak-buf
    ;; Cross deltas
    0.0                           ; prev-tk-spread
    0.0                           ; prev-stoch-kd
    ;; Price action
    0.0                           ; prev-range
    0                             ; consecutive-up-count
    0                             ; consecutive-down-count
    ;; Timeframe agreement
    0.0                           ; prev-tf-1h-ret
    0.0                           ; prev-tf-4h-ret
    ;; Previous values
    0.0                           ; prev-close
    ;; Counter
    0))                           ; count


;; ════════════════════════════════════════════════════════════════════════
;; tick — the main function. Advances everything by one raw candle.
;; ════════════════════════════════════════════════════════════════════════

(define (tick [bank : IndicatorBank]
              [raw  : RawCandle])
  : Candle
  ; Advances all streaming indicators by one raw candle.
  ; Returns an enriched Candle with raw OHLCV + all computed indicators.

  (let* (;; ── 1. Extract raw OHLCV ──────────────────────────────────────
         (ts     (:ts raw))
         (open   (:open raw))
         (high   (:high raw))
         (low    (:low raw))
         (close  (:close raw))
         (volume (:volume raw))

         ;; ── 2. Step streaming primitives ───────────────────────────────

         ;; Moving averages
         (sma20  (sma-step! (:sma20 bank) close))
         (sma50  (sma-step! (:sma50 bank) close))
         (sma200 (sma-step! (:sma200 bank) close))
         (ema20  (ema-step! (:ema20 bank) close))

         ;; Bollinger Bands — stddev over 20-period window
         (bb-std (rolling-stddev-step! (:bb-stddev bank) close))
         (bb-upper (+ sma20 (* 2.0 bb-std)))
         (bb-lower (- sma20 (* 2.0 bb-std)))
         (bb-width (if (> (abs sma20) 1e-10)
                     (/ (- bb-upper bb-lower) sma20)
                     0.0))
         (bb-pos   (if (> (abs (- bb-upper bb-lower)) 1e-10)
                     (/ (- close bb-lower) (- bb-upper bb-lower))
                     0.5))

         ;; RSI
         (rsi (rsi-step! (:rsi bank) close))

         ;; MACD
         (macd-result (macd-step! (:macd bank) close))
         (macd-line   (first macd-result))
         (macd-signal (second macd-result))
         (macd-hist   (nth macd-result 2))

         ;; DMI / ADX
         (dmi-result (dmi-step! (:dmi bank) high low close))
         (plus-di    (first dmi-result))
         (minus-di   (second dmi-result))
         (adx        (nth dmi-result 2))

         ;; ATR
         (atr (atr-step! (:atr bank) high low close))
         (atr-r (if (> (abs close) 1e-10) (/ atr close) 0.0))

         ;; Stochastic / Williams %R
         (stoch-result (stoch-step! (:stoch bank) high low close))
         (stoch-k     (first stoch-result))
         (stoch-d     (second stoch-result))
         (williams-r  (nth stoch-result 2))

         ;; CCI
         (cci (cci-step! (:cci bank) high low close))

         ;; MFI
         (mfi (mfi-step! (:mfi bank) high low close volume))

         ;; OBV slope
         (obv-slope-12 (obv-step! (:obv bank) close volume))

         ;; Volume SMA for acceleration
         (vol-sma20 (sma-step! (:volume-sma20 bank) volume))
         (vol-accel (if (> (abs vol-sma20) 1e-10)
                      (/ volume vol-sma20)
                      1.0))

         ;; ── 3. Keltner Channels ────────────────────────────────────────
         (kelt-upper (+ ema20 (* 1.5 atr)))
         (kelt-lower (- ema20 (* 1.5 atr)))
         (kelt-range (max (- kelt-upper kelt-lower) 1e-10))
         (kelt-pos   (/ (- close kelt-lower) kelt-range))

         ;; Squeeze: Bollinger inside Keltner
         (squeeze (and (< bb-upper kelt-upper) (> bb-lower kelt-lower)))

         ;; ── 4. ROC — rate of change ────────────────────────────────────
         (_ (ring-push! (:roc-buf bank) close))
         (roc-1  (compute-roc (:roc-buf bank) close 1))
         (roc-3  (compute-roc (:roc-buf bank) close 3))
         (roc-6  (compute-roc (:roc-buf bank) close 6))
         (roc-12 (if (ring-full? (:roc-buf bank))
                   (let* ((old (ring-oldest (:roc-buf bank))))
                     (if (< (abs old) 1e-10) 0.0 (/ (- close old) old)))
                   0.0))

         ;; ── 5. Range position ──────────────────────────────────────────
         (_ (ring-push! (:range-high-12 bank) high))
         (_ (ring-push! (:range-low-12 bank) low))
         (_ (ring-push! (:range-high-24 bank) high))
         (_ (ring-push! (:range-low-24 bank) low))
         (_ (ring-push! (:range-high-48 bank) high))
         (_ (ring-push! (:range-low-48 bank) low))
         (range-pos-12 (compute-range-pos (:range-high-12 bank) (:range-low-12 bank) close))
         (range-pos-24 (compute-range-pos (:range-high-24 bank) (:range-low-24 bank) close))
         (range-pos-48 (compute-range-pos (:range-high-48 bank) (:range-low-48 bank) close))

         ;; ── 6. Trend consistency ───────────────────────────────────────
         (trend-val (if (and (> (:count bank) 0) (> close (:prev-close bank)))
                      1.0 0.0))
         (_ (ring-push! (:trend-buf-24 bank) trend-val))
         (trend-consistency-6  (compute-trend-consistency (:trend-buf-24 bank) 6))
         (trend-consistency-12 (compute-trend-consistency (:trend-buf-24 bank) 12))
         (trend-consistency-24 (compute-trend-consistency (:trend-buf-24 bank) 24))

         ;; ── 7. ATR rate of change ──────────────────────────────────────
         (_ (ring-push! (:atr-history bank) atr))
         (atr-roc-6  (compute-roc (:atr-history bank) atr 6))
         (atr-roc-12 (if (ring-full? (:atr-history bank))
                       (let* ((old (ring-oldest (:atr-history bank))))
                         (if (< (abs old) 1e-10) 0.0 (/ (- atr old) old)))
                       0.0))

         ;; ── 8. Multi-timeframe ─────────────────────────────────────────
         (_ (ring-push! (:tf-1h-buf bank) close))
         (_ (ring-push! (:tf-1h-high bank) high))
         (_ (ring-push! (:tf-1h-low bank) low))
         (_ (ring-push! (:tf-4h-buf bank) close))
         (_ (ring-push! (:tf-4h-high bank) high))
         (_ (ring-push! (:tf-4h-low bank) low))

         (tf-1h-close (tf-close-val (:tf-1h-buf bank) close))
         (tf-1h-high  (ring-max (:tf-1h-high bank)))
         (tf-1h-low   (ring-min (:tf-1h-low bank)))
         (tf-1h-ret   (tf-ret-val (:tf-1h-buf bank) close))
         (tf-1h-body  (tf-body-val (:tf-1h-buf bank) close))

         (tf-4h-close (tf-close-val (:tf-4h-buf bank) close))
         (tf-4h-high  (ring-max (:tf-4h-high bank)))
         (tf-4h-low   (ring-min (:tf-4h-low bank)))
         (tf-4h-ret   (tf-ret-val (:tf-4h-buf bank) close))
         (tf-4h-body  (tf-body-val (:tf-4h-buf bank) close))

         ;; ── 9. Ichimoku Cloud ──────────────────────────────────────────
         (ichi-result (ichimoku-step! (:ichimoku bank) high low))
         (tenkan-sen    (first ichi-result))
         (kijun-sen     (second ichi-result))
         (senkou-span-a (nth ichi-result 2))
         (senkou-span-b (nth ichi-result 3))
         (cloud-top     (nth ichi-result 4))
         (cloud-bottom  (nth ichi-result 5))

         ;; ── 10. Persistence — Hurst + autocorrelation ──────────────────
         (_ (ring-push! (:close-buf-48 bank) close))
         (hurst           (compute-hurst (:close-buf-48 bank)))
         (autocorrelation (compute-autocorrelation (:close-buf-48 bank)))

         ;; ── 11. VWAP distance ──────────────────────────────────────────
         (tp-for-vwap (/ (+ high low close) 3.0))
         (_ (set! (:vwap-cum-vol bank) (+ (:vwap-cum-vol bank) volume)))
         (_ (set! (:vwap-cum-pv bank) (+ (:vwap-cum-pv bank) (* tp-for-vwap volume))))
         (vwap-distance (compute-vwap-distance (:vwap-cum-pv bank) (:vwap-cum-vol bank) close))

         ;; ── 12. Regime indicators ──────────────────────────────────────

         ;; KAMA Efficiency Ratio
         (_ (ring-push! (:kama-er-buf bank) close))
         (kama-er (compute-kama-er (:kama-er-buf bank)))

         ;; Choppiness Index — needs a 14-period high/low buffer; reuse range-high-24/low-24
         ;; which covers 24 > 14, but chop-buf tracks ATR values
         (chop-atr-old (if (ring-full? (:chop-buf bank))
                         (ring-oldest (:chop-buf bank))
                         0.0))
         (_ (ring-push! (:chop-buf bank) atr))
         (_ (set! (:chop-atr-sum bank)
                  (+ (- (:chop-atr-sum bank) (if (ring-full? (:chop-buf bank)) chop-atr-old 0.0))
                     atr)))
         (choppiness (compute-choppiness (:chop-buf bank) (:range-high-24 bank) (:range-low-24 bank)))

         ;; DFA
         (_ (ring-push! (:dfa-buf bank) close))
         (dfa-alpha (compute-dfa (:dfa-buf bank)))

         ;; Variance Ratio
         (_ (ring-push! (:var-ratio-buf bank) close))
         (variance-ratio (compute-variance-ratio (:var-ratio-buf bank)))

         ;; Entropy Rate
         (_ (ring-push! (:entropy-buf bank) close))
         (entropy-rate (compute-entropy-rate (:entropy-buf bank)))

         ;; Aroon
         (_ (ring-push! (:aroon-high-buf bank) high))
         (_ (ring-push! (:aroon-low-buf bank) low))
         (aroon-up   (compute-aroon-up (:aroon-high-buf bank)))
         (aroon-down (compute-aroon-down (:aroon-low-buf bank)))

         ;; Fractal Dimension
         (_ (ring-push! (:fractal-buf bank) close))
         (fractal-dim (compute-fractal-dim (:fractal-buf bank)))

         ;; ── 13. Divergence ─────────────────────────────────────────────
         (_ (ring-push! (:rsi-peak-buf bank) rsi))
         (_ (ring-push! (:price-peak-buf bank) close))
         (div-result (compute-rsi-divergence (:price-peak-buf bank) (:rsi-peak-buf bank)))
         (rsi-divergence-bull (first div-result))
         (rsi-divergence-bear (second div-result))

         ;; ── 14. Cross deltas ───────────────────────────────────────────
         ;; Ichimoku TK cross delta
         (tk-spread (- tenkan-sen kijun-sen))
         (tk-cross-delta (- tk-spread (:prev-tk-spread bank)))
         (_ (set! (:prev-tk-spread bank) tk-spread))

         ;; Stochastic cross delta
         (stoch-kd-spread (- stoch-k stoch-d))
         (stoch-cross-delta (- stoch-kd-spread (:prev-stoch-kd bank)))
         (_ (set! (:prev-stoch-kd bank) stoch-kd-spread))

         ;; ── 15. Price action ───────────────────────────────────────────
         (candle-range (- high low))

         ;; Range ratio — current range / prev range
         (range-ratio (if (> (:prev-range bank) 1e-10)
                        (/ candle-range (:prev-range bank))
                        1.0))
         (_ (set! (:prev-range bank) candle-range))

         ;; Gap: (open - prev close) / prev close
         (gap (if (> (abs (:prev-close bank)) 1e-10)
                (/ (- open (:prev-close bank)) (:prev-close bank))
                0.0))

         ;; Consecutive up/down counts
         (_ (cond
              ((> close open)
               (set! (:consecutive-up-count bank) (+ (:consecutive-up-count bank) 1))
               (set! (:consecutive-down-count bank) 0))
              ((< close open)
               (set! (:consecutive-down-count bank) (+ (:consecutive-down-count bank) 1))
               (set! (:consecutive-up-count bank) 0))
              (else
               (set! (:consecutive-up-count bank) 0)
               (set! (:consecutive-down-count bank) 0))))
         (consecutive-up   (+ (:consecutive-up-count bank) 0.0))
         (consecutive-down (+ (:consecutive-down-count bank) 0.0))

         ;; ── 16. Timeframe agreement ────────────────────────────────────
         ;; 5-minute return = roc-1 (one candle = 5 min)
         (five-min-ret roc-1)
         (tf-agreement (compute-tf-agreement five-min-ret tf-1h-ret tf-4h-ret))

         ;; Save prev TF returns for next candle
         (_ (set! (:prev-tf-1h-ret bank) tf-1h-ret))
         (_ (set! (:prev-tf-4h-ret bank) tf-4h-ret))

         ;; ── 17. Time — circular scalars ────────────────────────────────
         (minute       (parse-minute ts))
         (hour         (parse-hour ts))
         (day-of-week  (parse-day-of-week ts))
         (day-of-month (parse-day-of-month ts))
         (month-of-year (parse-month ts))

         ;; ── 18. Advance bank state ─────────────────────────────────────
         (_ (set! (:prev-close bank) close))
         (_ (inc! (:count bank))))

    ;; ── 19. Assemble the enriched Candle ──────────────────────────────
    (candle
      ;; Raw
      ts open high low close volume
      ;; Moving averages
      sma20 sma50 sma200
      ;; Bollinger
      bb-upper bb-lower bb-width bb-pos
      ;; RSI, MACD, DMI, ATR
      rsi macd-line macd-signal macd-hist
      plus-di minus-di adx atr atr-r
      ;; Stochastic, CCI, MFI, OBV, Williams %R
      stoch-k stoch-d williams-r cci mfi
      obv-slope-12 vol-accel
      ;; Keltner, squeeze
      kelt-upper kelt-lower kelt-pos squeeze
      ;; Rate of change
      roc-1 roc-3 roc-6 roc-12
      ;; ATR rate of change
      atr-roc-6 atr-roc-12
      ;; Trend consistency
      trend-consistency-6 trend-consistency-12 trend-consistency-24
      ;; Range position
      range-pos-12 range-pos-24 range-pos-48
      ;; Multi-timeframe
      tf-1h-close tf-1h-high tf-1h-low tf-1h-ret tf-1h-body
      tf-4h-close tf-4h-high tf-4h-low tf-4h-ret tf-4h-body
      ;; Ichimoku
      tenkan-sen kijun-sen senkou-span-a senkou-span-b cloud-top cloud-bottom
      ;; Persistence
      hurst autocorrelation vwap-distance
      ;; Regime
      kama-er choppiness dfa-alpha variance-ratio entropy-rate
      aroon-up aroon-down fractal-dim
      ;; Divergence
      rsi-divergence-bull rsi-divergence-bear
      ;; Cross deltas
      tk-cross-delta stoch-cross-delta
      ;; Price action
      range-ratio gap consecutive-up consecutive-down
      ;; Timeframe agreement
      tf-agreement
      ;; Time
      minute hour day-of-week day-of-month month-of-year)))
