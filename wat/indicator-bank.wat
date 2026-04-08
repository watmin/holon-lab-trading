; indicator-bank.wat — streaming state machine. Advances all indicators by one raw candle.
;
; Depends on: nothing (produces Candle via tick).
;
; Stateful — ring buffers, EMA accumulators, Wilder smoothers.
; One per post (one per asset pair). The streaming primitives are the
; building blocks of indicator state.

(require primitives)

;; ── Streaming primitives — leaves, depend on nothing ──────────────────

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
  [started    : bool])

;; ── Depend on RingBuffer ──────────────────────────────────────────────

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
  [k-buf    : RingBuffer])

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

;; ── Depend on EmaState ────────────────────────────────────────────────

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

;; ── IndicatorBank — composed from the streaming primitives ────────────

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
  [vwap-cum-pv  : f64]         ; cumulative price x volume
  ;; Regime — state for regime.wat fields
  [kama-er-buf : RingBuffer]   ; 10-period close buffer for KAMA efficiency ratio
  [chop-atr-sum : f64]         ; running sum of ATR over choppiness period
  [chop-buf : RingBuffer]      ; 14-period ATR buffer for Choppiness Index
  [dfa-buf : RingBuffer]       ; close buffer for Detrended Fluctuation Analysis
  [var-ratio-buf : RingBuffer] ; close buffer for variance ratio (two scales)
  [entropy-buf : RingBuffer]   ; discretized return buffer for conditional entropy
  [aroon-high-buf : RingBuffer] ; 25-period high buffer for Aroon up
  [aroon-low-buf : RingBuffer]  ; 25-period low buffer for Aroon down
  [fractal-buf : RingBuffer]   ; close buffer for fractal dimension
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

;; ── Interface ─────────────────────────────────────────────────────────

(define (make-indicator-bank)
  : IndicatorBank
  ;; All streaming primitives initialize to zero/empty state.
  ;; Ring buffers start with the appropriate capacity.
  ;; The Rust implementation handles the initialization details.
  ;; This constructor creates a bank ready to accept its first raw candle.
  (make-indicator-bank
    ;; Moving averages
    (make-sma-state 20) (make-sma-state 50) (make-sma-state 200)
    (make-ema-state 20)
    ;; Bollinger
    (make-rolling-stddev 20)
    ;; Oscillators
    (make-rsi-state) (make-macd-state) (make-dmi-state 14) (make-atr-state)
    (make-stoch-state) (make-cci-state) (make-mfi-state) (make-obv-state)
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
    (make-ring-buffer 48)
    ;; Multi-timeframe
    (make-ring-buffer 12) (make-ring-buffer 12) (make-ring-buffer 12)
    (make-ring-buffer 48) (make-ring-buffer 48) (make-ring-buffer 48)
    ;; Ichimoku
    (make-ichimoku-state)
    ;; Persistence
    (make-ring-buffer 48)
    ;; VWAP
    0.0 0.0
    ;; Regime
    (make-ring-buffer 10) 0.0 (make-ring-buffer 14)
    (make-ring-buffer 48) (make-ring-buffer 48) (make-ring-buffer 48)
    (make-ring-buffer 25) (make-ring-buffer 25) (make-ring-buffer 48)
    ;; Divergence
    (make-ring-buffer 48) (make-ring-buffer 48)
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

;; tick: advance all indicators by one raw candle. Returns enriched Candle.
;; The Rust implementation drives each streaming primitive forward and
;; assembles the Candle struct from the updated state.
(define (tick [bank : IndicatorBank]
              [raw : RawCandle])
  : Candle
  ;; Implementation: advance each streaming primitive with the raw OHLCV,
  ;; compute all derived indicators, assemble and return the Candle.
  ;; The bank is mutated in place — streaming state advances.
  )
