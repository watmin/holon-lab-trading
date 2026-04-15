;; market-observer-thought.wat — what one market observer produces per candle.
;; Lens: dow-trend. ~33 facts. The vocabulary modules selected by the lens.
;;
;; The market observer encodes these facts, bundles them, feeds them to its
;; reckoner, and predicts Up or Down. The anomaly vector is what the noise
;; subspace cannot explain. Both the raw thought and the anomaly flow
;; downstream to the position observer.

(bundle
  ;; Trend facts — SMA relations
  (bind (atom "close-sma20")     (linear 0.023 1.0))   ; close is 2.3% above SMA20
  (bind (atom "close-sma50")     (linear 0.041 1.0))   ; close is 4.1% above SMA50
  (bind (atom "close-sma200")    (linear 0.12 1.0))    ; close is 12% above SMA200
  (bind (atom "sma20-sma50")     (linear 0.018 1.0))   ; SMA20 is 1.8% above SMA50

  ;; Bollinger
  (bind (atom "bb-pos")          (linear 0.82 1.0))    ; price near upper band
  (bind (atom "bb-width")        (linear 0.047 1.0))   ; moderate bandwidth

  ;; RSI
  (bind (atom "rsi")             (linear 0.68 1.0))    ; approaching overbought

  ;; MACD
  (bind (atom "macd-hist")       (linear 12.5 1.0))    ; positive histogram

  ;; DMI
  (bind (atom "plus-di")         (linear 28.0 1.0))
  (bind (atom "minus-di")        (linear 18.0 1.0))
  (bind (atom "adx")             (linear 32.0 1.0))    ; trending

  ;; ATR
  (bind (atom "atr-ratio")       (linear 0.015 1.0))   ; 1.5% volatility

  ;; Stochastic
  (bind (atom "stoch-k")         (linear 78.0 1.0))
  (bind (atom "stoch-d")         (linear 72.0 1.0))

  ;; Rate of change
  (bind (atom "roc-1")           (linear 0.003 1.0))   ; +0.3% last candle
  (bind (atom "roc-3")           (linear 0.008 1.0))   ; +0.8% last 3 candles
  (bind (atom "roc-6")           (linear 0.015 1.0))
  (bind (atom "roc-12")          (linear 0.028 1.0))

  ;; Range position
  (bind (atom "range-pos-12")    (linear 0.85 1.0))    ; near 12-candle high
  (bind (atom "range-pos-24")    (linear 0.72 1.0))
  (bind (atom "range-pos-48")    (linear 0.68 1.0))

  ;; Ichimoku
  (bind (atom "tenkan-kijun")    (linear 0.005 1.0))   ; tenkan above kijun
  (bind (atom "cloud-pos")       (linear 0.03 1.0))    ; price above cloud

  ;; Persistence
  (bind (atom "hurst")           (linear 0.62 1.0))    ; trending (> 0.5)
  (bind (atom "autocorrelation") (linear 0.15 1.0))

  ;; Volume
  (bind (atom "obv-slope")       (linear 0.8 1.0))     ; OBV rising
  (bind (atom "volume-accel")    (linear 1.3 1.0))     ; volume accelerating

  ;; Divergence
  (bind (atom "rsi-div-bull")    (linear 0.0 1.0))     ; no bullish divergence
  (bind (atom "rsi-div-bear")    (linear 0.0 1.0))     ; no bearish divergence

  ;; Time — circular scalars: parts, and the composition.
  ;; The noise subspace decides which level carries signal.
  (bind (atom "hour")            (circular 14.0 24.0))  ; 2pm UTC
  (bind (atom "day-of-week")     (circular 3.0 7.0))    ; Wednesday
  (bind                                                  ; 2pm-on-Wednesday — unique direction
    (bind (atom "hour") (circular 14.0 24.0))
    (bind (atom "day-of-week") (circular 3.0 7.0)))

  ;; Price action
  (bind (atom "consecutive-up")  (linear 3.0 1.0))     ; 3 green candles in a row
  (bind (atom "range-ratio")     (linear 1.1 1.0)))    ; slightly expanded range
