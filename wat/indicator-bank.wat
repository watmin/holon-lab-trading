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
  [prev-close : f64])

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
