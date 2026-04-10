;; candle.wat — the enriched candle
;; Depends on: raw-candle (via indicator-bank)
;; Raw OHLCV in, 100+ computed indicators out.
;; Produced by IndicatorBank.tick(raw-candle).

(require primitives)

(struct candle
  ;; Raw
  [ts : String] [open : f64] [high : f64] [low : f64] [close : f64] [volume : f64]
  ;; Moving averages
  [sma20 : f64] [sma50 : f64] [sma200 : f64]
  ;; Bollinger
  [bb-upper : f64] [bb-lower : f64] [bb-width : f64] [bb-pos : f64]
  ;; RSI, MACD, DMI, ATR
  [rsi : f64] [macd : f64] [macd-signal : f64] [macd-hist : f64]
  [plus-di : f64] [minus-di : f64] [adx : f64] [atr : f64] [atr-r : f64]
  ;; Stochastic, CCI, MFI, OBV, Williams %R
  [stoch-k : f64] [stoch-d : f64] [williams-r : f64] [cci : f64] [mfi : f64]
  [obv-slope-12 : f64]
  [volume-accel : f64]
  ;; Keltner, squeeze
  [kelt-upper : f64] [kelt-lower : f64] [kelt-pos : f64]
  [squeeze : f64]
  ;; Rate of Change
  [roc-1 : f64] [roc-3 : f64] [roc-6 : f64] [roc-12 : f64]
  ;; ATR rate of change
  [atr-roc-6 : f64] [atr-roc-12 : f64]
  ;; Trend consistency
  [trend-consistency-6 : f64] [trend-consistency-12 : f64] [trend-consistency-24 : f64]
  ;; Range position
  [range-pos-12 : f64] [range-pos-24 : f64] [range-pos-48 : f64]
  ;; Multi-timeframe
  [tf-1h-close : f64] [tf-1h-high : f64] [tf-1h-low : f64] [tf-1h-ret : f64] [tf-1h-body : f64]
  [tf-4h-close : f64] [tf-4h-high : f64] [tf-4h-low : f64] [tf-4h-ret : f64] [tf-4h-body : f64]
  ;; Ichimoku
  [tenkan-sen : f64] [kijun-sen : f64] [senkou-span-a : f64] [senkou-span-b : f64]
  [cloud-top : f64] [cloud-bottom : f64]
  ;; Persistence
  [hurst : f64] [autocorrelation : f64] [vwap-distance : f64]
  ;; Regime
  [kama-er : f64] [choppiness : f64] [dfa-alpha : f64] [variance-ratio : f64]
  [entropy-rate : f64] [aroon-up : f64] [aroon-down : f64] [fractal-dim : f64]
  ;; Divergence
  [rsi-divergence-bull : f64] [rsi-divergence-bear : f64]
  ;; Cross deltas
  [tk-cross-delta : f64] [stoch-cross-delta : f64]
  ;; Price action
  [range-ratio : f64] [gap : f64] [consecutive-up : f64] [consecutive-down : f64]
  ;; Timeframe agreement
  [tf-agreement : f64]
  ;; Time — circular scalars
  [minute : f64] [hour : f64] [day-of-week : f64] [day-of-month : f64] [month-of-year : f64])
