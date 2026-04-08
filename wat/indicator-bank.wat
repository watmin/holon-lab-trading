; indicator-bank.wat — streaming indicator state machine. Depends on: RawCandle.
;
; Advances all indicators by one raw candle. Stateful — ring buffers,
; EMA accumulators, Wilder smoothers. One per post (one per asset pair).
; Consumes raw candles, produces enriched Candles.

(require primitives)
(require raw-candle)

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
  [period    : usize])

(struct rsi-state
  [avg-gain   : f64]
  [avg-loss   : f64]
  [period     : usize]
  [prev-close : f64])

(struct atr-state
  [atr        : f64]
  [period     : usize]
  [prev-close : f64])

(struct obv-state
  [obv        : f64]
  [prev-close : f64]
  [history    : RingBuffer])  ; for computing obv-slope-12 via linear regression

;; Depend on RingBuffer
(struct sma-state
  [buffer : RingBuffer]
  [sum    : f64]
  [period : usize])

(struct rolling-stddev
  [buffer : RingBuffer]
  [sum    : f64]
  [sum-sq : f64])

(struct stoch-state
  [high-buf : RingBuffer]
  [low-buf  : RingBuffer]
  [k-buf    : RingBuffer])  ; %K history for computing %D (3-period SMA of %K)

(struct cci-state
  [tp-buf : RingBuffer])

(struct mfi-state
  [pos-flow-buf : RingBuffer]
  [neg-flow-buf : RingBuffer]
  [prev-tp      : f64])

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
  [plus-dm-smooth  : f64]
  [minus-dm-smooth : f64]
  [tr-smooth       : f64]
  [dx-ema          : EmaState]
  [prev-high       : f64]
  [prev-low        : f64])

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
  [vwap-cum-pv  : f64]         ; cumulative price × volume
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
  [prev-range : f64]           ; previous candle range (high - low) for inside/outside bar
  [consecutive-up-count : usize]  ; running count of consecutive bullish closes
  [consecutive-down-count : usize] ; running count of consecutive bearish closes
  ;; Timeframe agreement — prev returns for direction comparison
  [prev-tf-1h-ret : f64]       ; previous 1h return for direction tracking
  [prev-tf-4h-ret : f64]       ; previous 4h return for direction tracking
  ;; Previous values
  [prev-close : f64]
  ;; Counter
  [count : usize])

;; Interface

(define (make-indicator-bank)
  : IndicatorBank
  ; Creates a fresh indicator bank with zeroed accumulators.
  (make-indicator-bank))

(define (tick [bank : IndicatorBank]
              [raw  : RawCandle])
  : Candle
  ; Advances all streaming indicators by one raw candle.
  ; Returns an enriched Candle with raw OHLCV + 100+ computed indicators.
  (tick bank raw))
