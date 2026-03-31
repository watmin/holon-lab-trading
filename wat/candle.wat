;; ── candle.wat — the enterprise's sensory input ─────────────────────
;;
;; Raw price data in. Named indicators out.
;; The enterprise builds its own senses from OHLCV.

(require core/structural)

;; ── Raw input ───────────────────────────────────────────────────────

(struct raw-candle ts open high low close volume)

;; Everything below is derived from raw-candle by the indicator engine.
;; (field name computation) declares what each indicator IS and how
;; it's computed. These become the streaming indicator reducers
;; (proposal 004).

;; ── Indicators ──────────────────────────────────────────────────────

;; Moving averages
(field sma20    (sma close 20))
(field sma50    (sma close 50))
(field sma200   (sma close 200))

;; Bollinger Bands (20-period, 2σ)
(field bb-upper (+ sma20 (* 2.0 (stddev close 20))))
(field bb-lower (- sma20 (* 2.0 (stddev close 20))))
(field bb-width (/ (- bb-upper bb-lower) sma20))   ; normalized width

;; RSI (14-period Wilder smoothing)
(field rsi (wilder-rsi close 14))

;; MACD (12, 26, 9)
(field macd-line   (- (ema close 12) (ema close 26)))
(field macd-signal (ema macd-line 9))
(field macd-hist   (- macd-line macd-signal))

;; DMI / ADX (14-period)
(field dmi-plus  (wilder-dmi-plus 14))
(field dmi-minus (wilder-dmi-minus 14))
(field adx       (wilder-adx 14))

;; ATR (14-period, as ratio of close)
(field atr   (wilder-atr 14))
(field atr-r (/ atr close))

;; ── New indicators (missing from current struct) ────────────────────
;;
;; These exist in the Python DB but are recomputed by vocab modules
;; from raw candles every call. Computing them once at load time and
;; storing on the Candle struct is faster and cleaner.

;; Stochastic (14-period)
(field stoch-k (stochastic-k 14))
(field stoch-d (sma stoch-k 3))

;; Williams %R (14-period)
(field williams-r (williams-r 14))

;; CCI (20-period)
(field cci (cci 20))

;; Money Flow Index (14-period)
(field mfi (mfi 14))

;; Rate of change at multiple scales
(field roc-1  (roc close 1))
(field roc-3  (roc close 3))
(field roc-6  (roc close 6))
(field roc-12 (roc close 12))

;; OBV slope (12-period linear regression slope of OBV)
(field obv-slope-12 (slope (obv) 12))

;; Volume SMA for relative volume
(field volume-sma-20 (sma volume 20))

;; ── Multi-timeframe ─────────────────────────────────────────────────
;;
;; The enterprise sees 5-minute candles. But hourly and 4-hour
;; structure carries signal the 5-minute view misses.
;; Computed by aggregating raw candles, not by loading a separate DB.

;; 1-hour aggregation (12 candles)
(field tf-1h-close  (last-close 12))
(field tf-1h-high   (max-high 12))
(field tf-1h-low    (min-low 12))
(field tf-1h-ret    (ret-pct 12))         ; return over last hour
(field tf-1h-body   (body-ratio 12))      ; |close-open|/range

;; 4-hour aggregation (48 candles)
(field tf-4h-close  (last-close 48))
(field tf-4h-high   (max-high 48))
(field tf-4h-low    (min-low 48))
(field tf-4h-ret    (ret-pct 48))
(field tf-4h-body   (body-ratio 48))

;; ── Derived features ────────────────────────────────────────────────
;;
;; Cross-indicator features the vocab modules currently compute live.
;; Pre-computing saves redundant work across expert profiles.

;; Bollinger position: where is close within the bands? [0,1]
(field bb-pos (/ (- close bb-lower) (- bb-upper bb-lower)))

;; Keltner position + squeeze
(field kelt-upper (+ (ema close 20) (* 1.5 atr)))
(field kelt-lower (- (ema close 20) (* 1.5 atr)))
(field kelt-pos   (/ (- close kelt-lower) (- kelt-upper kelt-lower)))
(field squeeze    (< bb-width (* 1.5 (/ atr (ema close 20)))))

;; Range position at multiple scales
(field range-pos-12 (range-position 12))
(field range-pos-24 (range-position 24))
(field range-pos-48 (range-position 48))

;; Trend consistency: what fraction of last N candles closed in the same direction?
(field trend-consistency-6  (trend-consistency 6))
(field trend-consistency-12 (trend-consistency 12))
(field trend-consistency-24 (trend-consistency 24))

;; Volatility acceleration
(field atr-roc-6  (roc atr 6))
(field atr-roc-12 (roc atr 12))

;; Volume acceleration
(field vol-accel (/ volume volume-sma-20))

;; Time (for circular encoding)
(field hour (parse-hour ts))
(field day-of-week (parse-day ts))

;; ── Causality ───────────────────────────────────────────────────────
;;
;; The first law: every field at candle t must be computable from
;; candles [0, t] only. No lookahead. No future data.
;;
;; Moving averages: backward-looking window [t-period, t].
;; EMA/Wilder: initialized from early candles, propagated forward.
;; Slope/regression: fit over [t-period, t], never beyond t.
;; Multi-timeframe: aggregate the LAST N candles, not a window around t.
;; Z-scores: rolling mean/stddev ending at t, not full-series.
;;
;; Labels (oracle) inherently look ahead — they are prophetic, not causal.
;; They must be clearly separated from indicator fields and never
;; contaminate the computation of any indicator.
;;
;; The test: removing all candles after t must produce the same indicator
;; value at t. If it doesn't, the enterprise sees the future.

;; ── What we do NOT pre-compute ──────────────────────────────────────
;;
;; - PELT changepoints: window-dependent, computed per expert at their scale
;; - Ichimoku: the tenkan/kijun/span computation is window-dependent
;; - Fibonacci: swing detection depends on the candle window
;; - Divergence: requires PELT structural peaks, window-dependent
;; - Hurst/DFA/entropy/fractal: computed from the observation window, not per-candle
;;
;; These are expert thoughts, not candle properties. They live in vocab modules.

;; ── The build tool ──────────────────────────────────────────────────
;;
;; A Rust binary that:
;;   1. Reads raw OHLCV from parquet (or CSV)
;;   2. Computes all fields above
;;   3. Writes to SQLite (same schema the enterprise reads)
;;   4. Replaces the Python-generated analysis.db
;;
;; One binary. One source. No Python chains.
;;
;; ./enterprise.sh build-candles data/btc_5m_raw.parquet → data/analysis.db
