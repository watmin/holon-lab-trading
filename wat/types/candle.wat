;; wat/types/candle.wat — Phase 1.6 (2026-04-22, revised from the
;; flat-73-fields port after the builder's "break Candle into sub-
;; structs" direction).
;;
;; The enriched candle — raw OHLCV + 60+ computed indicator scalars
;; + phase-labeler state. The 10-sub-struct split groups fields by
;; the vocab-file family that consumes them:
;;
;;   vocab/market/ichimoku.rs   ← Candle::Trend (SMAs + Ichimoku)
;;   vocab/market/keltner.rs    ← Candle::Volatility (Bollinger + Keltner + ATR)
;;   vocab/market/momentum.rs   ← Candle::Momentum (RSI, MACD, DMI, ...)
;;   vocab/market/oscillators.rs ← Candle::Momentum (shared)
;;   vocab/market/stochastic.rs  ← Candle::Momentum (shared)
;;   vocab/market/divergence.rs  ← Candle::Divergence
;;   vocab/market/persistence.rs ← Candle::Persistence
;;   vocab/market/regime.rs      ← Candle::Regime
;;   vocab/market/price_action.rs ← Candle::PriceAction
;;   vocab/market/timeframe.rs    ← Candle::Timeframe
;;   vocab/shared/time.rs         ← Candle::Time
;;
;; Raw OHLCV + identity lives directly on the existing :trading::types::Ohlcv
;; (Phase 1.3) — no reason to duplicate. Candle composes Ohlcv + groups.
;;
;; Rate-of-change fields (roc_N + range_pos_N) form their own
;; Candle::RateOfChange since they read from multiple vocab files.

;; Self-load dependencies (arc 027 slice 4): candle references
;; :trading::types::Ohlcv and the PhaseLabel / PhaseDirection /
;; PhaseRecord types from pivot. `./` relative paths resolve against
;; this file's directory regardless of caller's scope. Canonical-
;; path dedup (arc 027 slice 1) makes a second load of either file
;; a no-op.
(:wat::load-file! "./ohlcv.wat")
(:wat::load-file! "./pivot.wat")

;; ─── Indicator family sub-structs ──────────────────────────────────────

;; Moving averages + Ichimoku cloud.
(:wat::core::struct :trading::types::Candle::Trend
  (sma20        :f64)
  (sma50        :f64)
  (sma200       :f64)
  (tenkan-sen   :f64)
  (kijun-sen    :f64)
  (cloud-top    :f64)
  (cloud-bottom :f64))

;; Volatility bands + ATR + squeeze.
(:wat::core::struct :trading::types::Candle::Volatility
  (bb-width   :f64)
  (bb-pos     :f64)
  (kelt-upper :f64)
  (kelt-lower :f64)
  (kelt-pos   :f64)
  (squeeze    :f64)
  (atr-ratio  :f64))

;; Momentum indicators — RSI, MACD, DMI, Stochastic, CCI, MFI, Williams %R,
;; OBV, volume-accel.
(:wat::core::struct :trading::types::Candle::Momentum
  (rsi          :f64)
  (macd-hist    :f64)
  (plus-di      :f64)
  (minus-di     :f64)
  (adx          :f64)
  (stoch-k      :f64)
  (stoch-d      :f64)
  (williams-r   :f64)
  (cci          :f64)
  (mfi          :f64)
  (obv-slope-12 :f64)
  (volume-accel :f64))

;; Divergence + cross deltas — the accountability of momentum shifts.
(:wat::core::struct :trading::types::Candle::Divergence
  (rsi-divergence-bull :f64)
  (rsi-divergence-bear :f64)
  (tk-cross-delta      :f64)
  (stoch-cross-delta   :f64))

;; Rate-of-change over multiple windows + position within range.
(:wat::core::struct :trading::types::Candle::RateOfChange
  (roc-1        :f64)
  (roc-3        :f64)
  (roc-6        :f64)
  (roc-12       :f64)
  (range-pos-12 :f64)
  (range-pos-24 :f64)
  (range-pos-48 :f64))

;; Long-memory / correlation structure.
(:wat::core::struct :trading::types::Candle::Persistence
  (hurst           :f64)
  (autocorrelation :f64)
  (vwap-distance   :f64))

;; Regime classifiers — KAMA-ER, choppiness, entropy, fractal dimension.
(:wat::core::struct :trading::types::Candle::Regime
  (kama-er        :f64)
  (choppiness     :f64)
  (dfa-alpha      :f64)
  (variance-ratio :f64)
  (entropy-rate   :f64)
  (aroon-up       :f64)
  (aroon-down     :f64)
  (fractal-dim    :f64))

;; Candle-local price action — range, gap, consecutive-move counts.
(:wat::core::struct :trading::types::Candle::PriceAction
  (range-ratio      :f64)
  (gap              :f64)
  (consecutive-up   :f64)
  (consecutive-down :f64))

;; Multi-timeframe aggregation.
(:wat::core::struct :trading::types::Candle::Timeframe
  (tf-1h-ret    :f64)
  (tf-1h-body   :f64)
  (tf-4h-ret    :f64)
  (tf-4h-body   :f64)
  (tf-agreement :f64))

;; Calendar position — circular scalars (minute of hour through month of year).
(:wat::core::struct :trading::types::Candle::Time
  (minute        :f64)
  (hour          :f64)
  (day-of-week   :f64)
  (day-of-month  :f64)
  (month-of-year :f64))

;; Phase labeler — Proposal 049.
(:wat::core::struct :trading::types::Candle::Phase
  (label     :trading::types::PhaseLabel)
  (direction :trading::types::PhaseDirection)
  (duration  :i64)
  (history   :Vec<trading::types::PhaseRecord>))

;; ─── Candle — composed of Ohlcv + 11 indicator-family sub-structs ──────

(:wat::core::struct :trading::types::Candle
  (ohlcv        :trading::types::Ohlcv)
  (trend        :trading::types::Candle::Trend)
  (volatility   :trading::types::Candle::Volatility)
  (momentum     :trading::types::Candle::Momentum)
  (divergence   :trading::types::Candle::Divergence)
  (roc          :trading::types::Candle::RateOfChange)
  (persistence  :trading::types::Candle::Persistence)
  (regime       :trading::types::Candle::Regime)
  (price-action :trading::types::Candle::PriceAction)
  (timeframe    :trading::types::Candle::Timeframe)
  (time         :trading::types::Candle::Time)
  (phase        :trading::types::Candle::Phase))
