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

;; ── Indicator vocabulary ───────────────────────────────────────────
;;
;; (field name computation) declares a named indicator on the Candle struct.
;; Each field is computed once at load time from raw OHLCV and prior fields.
;; The Rust struct stores these as pre-computed f64 columns in SQLite.
;;
;; field: declares a named indicator. (field name expr) means "candle.name = expr".
;;        The computation is the BUILD-TIME definition; at runtime, it's a struct field.

;; ── Streaming reducers ────────────────────────────────────────────
;;
;; These are windowed computations over the candle history [0, t].
;; Each takes a source series and a period, maintaining state across candles.
;; The Python DB pre-computes them; the Rust loads pre-computed values.

(define (sma series period)
  "Simple moving average: mean of last `period` values of `series`."
  (/ (sum (last-n series period)) period))

(define (ema series period)
  "Exponential moving average. alpha = 2/(period+1). Recursive: ema_t = alpha*x + (1-alpha)*ema_{t-1}."
  (let ((alpha (/ 2.0 (+ period 1))))
    (+ (* alpha (current series)) (* (- 1.0 alpha) (prev-ema)))))

(define (stddev series period)
  "Standard deviation of last `period` values."
  (sqrt (/ (sum (map (lambda (x) (expt (- x (sma series period)) 2))
                     (last-n series period)))
           period)))

(define (wilder-rsi series period)
  "Wilder RSI. Smoothed avg-gain / avg-loss ratio, mapped to [0, 100].
   Uses Wilder smoothing: avg_t = ((period-1)*avg_{t-1} + current) / period."
  (let ((avg-gain (wilder-smooth gains period))
        (avg-loss (wilder-smooth losses period)))
    (- 100.0 (/ 100.0 (+ 1.0 (/ avg-gain (max avg-loss 1e-10)))))))

(define (wilder-dmi-plus period)
  "Wilder +DI: smoothed +DM / ATR * 100. +DM = max(high-prev_high, 0) when > -DM."
  (/ (* (wilder-smooth plus-dm period) 100.0) (wilder-atr period)))

(define (wilder-dmi-minus period)
  "Wilder -DI: smoothed -DM / ATR * 100. -DM = max(prev_low-low, 0) when > +DM."
  (/ (* (wilder-smooth minus-dm period) 100.0) (wilder-atr period)))

(define (wilder-adx period)
  "Average Directional Index: Wilder-smoothed |+DI - -DI| / (+DI + -DI) * 100."
  (wilder-smooth (/ (* (abs (- (wilder-dmi-plus period) (wilder-dmi-minus period))) 100.0)
                    (max (+ (wilder-dmi-plus period) (wilder-dmi-minus period)) 1e-10))
                 period))

(define (wilder-atr period)
  "Average True Range: Wilder-smoothed true range. TR = max(high-low, |high-prev_close|, |low-prev_close|)."
  (wilder-smooth true-range period))

(define (stochastic-k period)
  "Stochastic %K: (close - min-low) / (max-high - min-low) * 100 over `period` candles."
  (let ((lo (min-low period))
        (hi (max-high period)))
    (* (/ (- close lo) (max (- hi lo) 1e-10)) 100.0)))

(define (williams-r period)
  "Williams %R: (max-high - close) / (max-high - min-low) * -100 over `period` candles."
  (let ((lo (min-low period))
        (hi (max-high period)))
    (* (/ (- hi close) (max (- hi lo) 1e-10)) -100.0)))

(define (cci period)
  "Commodity Channel Index: (typical - SMA(typical)) / (0.015 * mean-deviation) over `period`."
  (let ((typical (/ (+ high low close) 3.0)))
    (/ (- typical (sma typical period))
       (* 0.015 (mean-abs-deviation typical period)))))

(define (mfi period)
  "Money Flow Index: RSI formula applied to money flow (typical * volume) over `period`."
  (let ((typical (/ (+ high low close) 3.0))
        (mf (* typical volume)))
    (wilder-rsi mf period)))

(define (roc series period)
  "Rate of change: (current - prev) / prev * 100, looking back `period` candles."
  (* (/ (- (current series) (nth-back series period))
        (max (abs (nth-back series period)) 1e-10))
     100.0))

(define (slope series period)
  "Linear regression slope of `series` over last `period` values.
   Least-squares fit: slope = cov(t, y) / var(t)."
  (let ((ys (last-n series period))
        (xs (range 0 period)))
    (/ (covariance xs ys) (variance xs))))

(define (obv)
  "On-Balance Volume: cumulative sum of signed volume.
   +volume when close > prev_close, -volume when close < prev_close."
  (cumulative-sum (map (lambda (c) (if (> (:close c) (:prev-close c))
                                       (:volume c) (- (:volume c))))
                       candles)))

;; ── Multi-timeframe aggregators ───────────────────────────────────

(define (last-close n)
  "Close price of the candle `n` periods ago."
  (nth-back close n))

(define (max-high n)
  "Maximum high over the last `n` candles."
  (max (map high (last-n candles n))))

(define (min-low n)
  "Minimum low over the last `n` candles."
  (min (map low (last-n candles n))))

(define (ret-pct n)
  "Return percentage over last `n` candles: (close - close_n_ago) / close_n_ago."
  (/ (- close (nth-back close n)) (max (abs (nth-back close n)) 1e-10)))

(define (body-ratio n)
  "Body-to-range ratio over last `n` candles: |close - open_n_ago| / (max_high - min_low)."
  (let ((hi (max-high n)) (lo (min-low n)))
    (/ (abs (- close (nth-back open n))) (max (- hi lo) 1e-10))))

(define (range-position n)
  "Where close sits within the [min-low, max-high] range over `n` candles. [0, 1]."
  (let ((hi (max-high n)) (lo (min-low n)))
    (/ (- close lo) (max (- hi lo) 1e-10))))

(define (trend-consistency n)
  "Fraction of last `n` candles that closed in the majority direction.
   1.0 = all same direction. 0.5 = split."
  (let ((ups (count (lambda (c) (> (:close c) (:open c))) (last-n candles n))))
    (/ (max ups (- n ups)) n)))

;; ── Timestamp parsing ─────────────────────────────────────────────

(define (parse-hour ts)
  "Extract hour-of-day from timestamp string 'YYYY-MM-DD HH:MM:SS'. Returns f64 [0, 23]."
  (or (parse-f64 (substring ts 11 13)) 12.0))

(define (parse-day ts)
  "Day-of-week from timestamp. 0=Sunday..6=Saturday. Zeller formula."
  (let ((y (or (parse-i32 (substring ts 0 4)) 2019))
        (m (or (parse-i32 (substring ts 5 7)) 1))
        (d (or (parse-i32 (substring ts 8 10)) 1))
        (t [0 3 2 5 0 3 5 1 4 6 2 4])
        (y2 (if (< m 3) (- y 1) y)))
    (mod (+ y2 (/ y2 4) (- (/ y2 100)) (/ y2 400) (nth t (- m 1)) d) 7)))

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
