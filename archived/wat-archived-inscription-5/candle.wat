;; candle.wat — the enriched Candle struct
;; Depends on: indicator-bank (conceptually — this is the output of tick)
;; Raw OHLCV in, 100+ computed indicators out.

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
  [obv-slope-12 : f64]         ; 12-period linear regression slope of OBV
  [volume-accel : f64]         ; volume / volume_sma20 — volume acceleration
  ;; Keltner, squeeze
  [kelt-upper : f64] [kelt-lower : f64] [kelt-pos : f64]
  [squeeze : f64]              ; bb-width / kelt-width ratio — continuous, not bool
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
  [hurst : f64]                ; Hurst exponent — trending vs mean-reverting
  [autocorrelation : f64]      ; lag-1 autocorrelation — signed
  [vwap-distance : f64]        ; (close - VWAP) / close — signed distance
  ;; Regime
  [kama-er : f64]              ; Kaufman Adaptive Moving Average Efficiency Ratio [0, 1]
  [choppiness : f64]           ; Choppiness Index [0, 100]
  [dfa-alpha : f64]            ; Detrended Fluctuation Analysis exponent
  [variance-ratio : f64]       ; variance at scale N / (N × variance at scale 1)
  [entropy-rate : f64]         ; conditional entropy of discretized returns
  [aroon-up : f64]             ; Aroon up [0, 100]
  [aroon-down : f64]           ; Aroon down [0, 100]
  [fractal-dim : f64]          ; fractal dimension — 1.0 trending, 2.0 noisy
  ;; Divergence
  [rsi-divergence-bull : f64]  ; bullish divergence magnitude
  [rsi-divergence-bear : f64]  ; bearish divergence magnitude
  ;; Ichimoku cross delta
  [tk-cross-delta : f64]       ; (tenkan - kijun) change from prev candle — signed
  ;; Stochastic cross delta
  [stoch-cross-delta : f64]    ; (%K - %D) change from prev candle — signed
  ;; Price action
  [range-ratio : f64]          ; current range / prev range
  [gap : f64]                  ; signed — (open - prev close) / prev close
  [consecutive-up : f64]       ; run count of consecutive bullish closes
  [consecutive-down : f64]     ; run count of consecutive bearish closes
  ;; Timeframe agreement
  [tf-agreement : f64]         ; inter-timeframe agreement score
  ;; Time — circular scalars
  [minute : f64]               ; mod 60
  [hour : f64]                 ; mod 24
  [day-of-week : f64]          ; mod 7
  [day-of-month : f64]         ; mod 31
  [month-of-year : f64])       ; mod 12
