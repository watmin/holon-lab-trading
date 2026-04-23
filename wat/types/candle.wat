;; wat/types/candle.wat — Phase 1.6 (2026-04-22, was originally
;; 1.5 in rewrite-backlog — reordered after pivot so pivot types
;; are in scope).
;;
;; Port of archived/pre-wat-native/src/types/candle.rs. The
;; enriched candle — raw OHLCV in, 70+ computed indicator scalars
;; out + phase-labeler state. Produced by IndicatorBank.tick()
;; (ships in Phase 5).
;;
;; Indicator fields stay :f64 (not newtyped). Price/Amount
;; newtypes guard the money boundary at Phase 1.2; indicator
;; values are intermediate computation — newtypes for each would
;; be verbose noise with no type-safety gain. See the archive's
;; "rune:forge(bare-type)" note at candle.rs:3.
;;
;; `usize` → `:i64` for phase_duration. `Vec<PhaseRecord>` stays
;; `:Vec<T>` via wat's built-in parametric Vec.

(:wat::core::struct :trading::types::Candle
  ;; Identity — which asset pair this candle describes.
  (source-asset :trading::types::Asset)
  (target-asset :trading::types::Asset)
  ;; Raw.
  (ts     :String)
  (open   :f64)
  (high   :f64)
  (low    :f64)
  (close  :f64)
  (volume :f64)
  ;; Moving averages.
  (sma20  :f64)
  (sma50  :f64)
  (sma200 :f64)
  ;; Bollinger.
  (bb-width :f64)
  (bb-pos   :f64)
  ;; RSI, MACD, DMI, ATR.
  (rsi       :f64)
  (macd-hist :f64)
  (plus-di   :f64)
  (minus-di  :f64)
  (adx       :f64)
  (atr-ratio :f64)
  ;; Stochastic, CCI, MFI, OBV, Williams %R.
  (stoch-k      :f64)
  (stoch-d      :f64)
  (williams-r   :f64)
  (cci          :f64)
  (mfi          :f64)
  (obv-slope-12 :f64)
  (volume-accel :f64)
  ;; Keltner, squeeze.
  (kelt-upper :f64)
  (kelt-lower :f64)
  (kelt-pos   :f64)
  (squeeze    :f64)
  ;; Rate of Change.
  (roc-1  :f64)
  (roc-3  :f64)
  (roc-6  :f64)
  (roc-12 :f64)
  ;; Range position.
  (range-pos-12 :f64)
  (range-pos-24 :f64)
  (range-pos-48 :f64)
  ;; Multi-timeframe.
  (tf-1h-ret  :f64)
  (tf-1h-body :f64)
  (tf-4h-ret  :f64)
  (tf-4h-body :f64)
  ;; Ichimoku.
  (tenkan-sen   :f64)
  (kijun-sen    :f64)
  (cloud-top    :f64)
  (cloud-bottom :f64)
  ;; Persistence.
  (hurst           :f64)
  (autocorrelation :f64)
  (vwap-distance   :f64)
  ;; Regime.
  (kama-er        :f64)
  (choppiness     :f64)
  (dfa-alpha      :f64)
  (variance-ratio :f64)
  (entropy-rate   :f64)
  (aroon-up       :f64)
  (aroon-down     :f64)
  (fractal-dim    :f64)
  ;; Divergence.
  (rsi-divergence-bull :f64)
  (rsi-divergence-bear :f64)
  ;; Cross deltas.
  (tk-cross-delta    :f64)
  (stoch-cross-delta :f64)
  ;; Price action.
  (range-ratio      :f64)
  (gap              :f64)
  (consecutive-up   :f64)
  (consecutive-down :f64)
  ;; Timeframe agreement.
  (tf-agreement :f64)
  ;; Time — circular scalars.
  (minute        :f64)
  (hour          :f64)
  (day-of-week   :f64)
  (day-of-month  :f64)
  (month-of-year :f64)
  ;; Phase labeler — Proposal 049.
  (phase-label     :trading::types::PhaseLabel)
  (phase-direction :trading::types::PhaseDirection)
  (phase-duration  :i64)
  (phase-history   :Vec<trading::types::PhaseRecord>))
