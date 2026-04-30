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
  (sma20        :wat::core::f64)
  (sma50        :wat::core::f64)
  (sma200       :wat::core::f64)
  (tenkan-sen   :wat::core::f64)
  (kijun-sen    :wat::core::f64)
  (cloud-top    :wat::core::f64)
  (cloud-bottom :wat::core::f64))

;; Volatility bands + ATR + squeeze.
(:wat::core::struct :trading::types::Candle::Volatility
  (bb-width   :wat::core::f64)
  (bb-pos     :wat::core::f64)
  (kelt-upper :wat::core::f64)
  (kelt-lower :wat::core::f64)
  (kelt-pos   :wat::core::f64)
  (squeeze    :wat::core::f64)
  (atr-ratio  :wat::core::f64))

;; Momentum indicators — RSI, MACD, DMI, Stochastic, CCI, MFI, Williams %R,
;; OBV, volume-accel.
(:wat::core::struct :trading::types::Candle::Momentum
  (rsi          :wat::core::f64)
  (macd-hist    :wat::core::f64)
  (plus-di      :wat::core::f64)
  (minus-di     :wat::core::f64)
  (adx          :wat::core::f64)
  (stoch-k      :wat::core::f64)
  (stoch-d      :wat::core::f64)
  (williams-r   :wat::core::f64)
  (cci          :wat::core::f64)
  (mfi          :wat::core::f64)
  (obv-slope-12 :wat::core::f64)
  (volume-accel :wat::core::f64))

;; Divergence + cross deltas — the accountability of momentum shifts.
(:wat::core::struct :trading::types::Candle::Divergence
  (rsi-divergence-bull :wat::core::f64)
  (rsi-divergence-bear :wat::core::f64)
  (tk-cross-delta      :wat::core::f64)
  (stoch-cross-delta   :wat::core::f64))

;; Rate-of-change over multiple windows + position within range.
(:wat::core::struct :trading::types::Candle::RateOfChange
  (roc-1        :wat::core::f64)
  (roc-3        :wat::core::f64)
  (roc-6        :wat::core::f64)
  (roc-12       :wat::core::f64)
  (range-pos-12 :wat::core::f64)
  (range-pos-24 :wat::core::f64)
  (range-pos-48 :wat::core::f64))

;; Long-memory / correlation structure.
(:wat::core::struct :trading::types::Candle::Persistence
  (hurst           :wat::core::f64)
  (autocorrelation :wat::core::f64)
  (vwap-distance   :wat::core::f64))

;; Regime classifiers — KAMA-ER, choppiness, entropy, fractal dimension.
(:wat::core::struct :trading::types::Candle::Regime
  (kama-er        :wat::core::f64)
  (choppiness     :wat::core::f64)
  (dfa-alpha      :wat::core::f64)
  (variance-ratio :wat::core::f64)
  (entropy-rate   :wat::core::f64)
  (aroon-up       :wat::core::f64)
  (aroon-down     :wat::core::f64)
  (fractal-dim    :wat::core::f64))

;; Candle-local price action — range, gap, consecutive-move counts.
(:wat::core::struct :trading::types::Candle::PriceAction
  (range-ratio      :wat::core::f64)
  (gap              :wat::core::f64)
  (consecutive-up   :wat::core::f64)
  (consecutive-down :wat::core::f64))

;; Multi-timeframe aggregation.
(:wat::core::struct :trading::types::Candle::Timeframe
  (tf-1h-ret    :wat::core::f64)
  (tf-1h-body   :wat::core::f64)
  (tf-4h-ret    :wat::core::f64)
  (tf-4h-body   :wat::core::f64)
  (tf-agreement :wat::core::f64))

;; Calendar position — circular scalars (minute of hour through month of year).
(:wat::core::struct :trading::types::Candle::Time
  (minute        :wat::core::f64)
  (hour          :wat::core::f64)
  (day-of-week   :wat::core::f64)
  (day-of-month  :wat::core::f64)
  (month-of-year :wat::core::f64))

;; Phase labeler — Proposal 049.
(:wat::core::struct :trading::types::Candle::Phase
  (label     :trading::types::PhaseLabel)
  (direction :trading::types::PhaseDirection)
  (duration  :wat::core::i64)
  (history   :trading::types::PhaseRecords))

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

;; Candles — vector of enriched candles. Plural-via-typealias per
;; the user direction "expressivity wins". Window-based vocabs
;; (standard.wat) consume this; future regime/broker callers will
;; too.
(:wat::core::typealias
  :trading::types::Candles
  :Vec<trading::types::Candle>)
