;; rune:assay(prose) — build-candles.wat describes the pipeline (read parquet,
;; compute indicators, write SQLite) but does not express the computation loop,
;; the Wilder smoothing state machine, or the SQLite write phase. Two struct
;; declarations; the rest is narration.

;; ── bin/build-candles.wat — the enterprise builds its own senses ─
;;
;; One binary. One source. No Python chains.
;; Raw OHLCV in parquet. Computed candles out in SQLite.
;; Every indicator at candle t uses only candles [0, t]. No lookahead.
;;
;; Usage:
;;   cargo run --release --bin build-candles --features parquet -- \
;;     --input data/btc_5m_raw.parquet --output data/candles.db

;; ── CLI ────────────────────────────────────────────────────────

(struct args
  input                  ; PathBuf -- parquet file (ts, open, high, low, close, volume)
  output)                ; PathBuf -- SQLite database

;; ── Pipeline ───────────────────────────────────────────────────
;;
;; Three phases, single forward pass:
;;   1. Read parquet → Vec<RawCandle>
;;   2. Compute indicators → Vec<ComputedCandle>
;;   3. Write SQLite (WAL mode, batched inserts)

(struct raw-candle [ts open high low close volume])

;; ── Phase 2: indicator computation ─────────────────────────────
;;
;; All indicators computed in one forward pass over the raw candles.
;; Each uses only data at or before the current index.

;; Helper functions (stateless, causal):
;;   sma(values, period, idx)          — simple moving average
;;   stddev(values, period, idx)       — rolling standard deviation
;;   ema_series(values, period)        — exponential moving average (full series)
;;   roc(closes, period, idx)          — rate of change
;;   range_position(highs, lows, close, period, idx) — [0,1] position in range
;;   trend_consistency(closes, period, idx)           — fraction of up-closes

;; Wilder smoothing (stateful, forward-only):
;;   Accumulation phase: first `period` values averaged.
;;   Then Wilder smooth: (prev * (p-1) + curr) / p.
;;   Produces: RSI, ATR, DMI+, DMI-, ADX.

;; Pre-computed series:
;;   EMA 12, 26, 20      — for MACD and Keltner
;;   MACD line, signal    — ema12 - ema26, ema(macd, 9)
;;   Wilder (period=14)   — RSI, ATR, ATR/close, DMI+, DMI-, ADX
;;   OBV                  — cumulative on-balance volume
;;   Stochastic %K (14)   — (close - low) / (high - low) * 100
;;   Williams %R (14)     — -100 * (high - close) / (high - low)
;;   CCI (20)             — (tp - mean_tp) / (0.015 * mean_deviation)
;;   MFI (14)             — money flow index

;; ── Computed candle fields ─────────────────────────────────────
;;
;; See candle.wat for the full field list.
;; build-candles computes ALL of them:
;;
;;   Raw:         ts, year, open, high, low, close, volume
;;   MAs:         sma20, sma50, sma200
;;   Bollinger:   bb_upper, bb_lower, bb_width, bb_pos
;;   RSI:         rsi (14-period Wilder)
;;   MACD:        macd_line, macd_signal, macd_hist
;;   DMI/ADX:     dmi_plus, dmi_minus, adx
;;   ATR:         atr, atr_r
;;   Stochastic:  stoch_k, stoch_d
;;   Williams:    williams_r
;;   CCI:         cci
;;   MFI:         mfi
;;   ROC:         roc_1, roc_3, roc_6, roc_12
;;   OBV:         obv_slope_12
;;   Volume:      volume_sma_20, vol_accel
;;   Keltner:     kelt_upper, kelt_lower, kelt_pos, squeeze
;;   Range:       range_pos_12, range_pos_24, range_pos_48
;;   Trend:       trend_consistency_6, _12, _24
;;   Vol accel:   atr_roc_6, atr_roc_12
;;   Time:        hour, day_of_week
;;   Timeframe:   tf_1h_*, tf_4h_* (backward-looking aggregation)
;;   Label:       label_oracle_10 (prophetic, not causal)

;; ── Oracle label ───────────────────────────────────────────────
;;
;; label_oracle_10: looks 10 candles ahead.
;;   future_pct > +0.5%  → "Buy"
;;   future_pct < -0.5%  → "Sell"
;;   else                → "Noise"
;;
;; Prophetic. Separated from causal indicators. Never contaminates
;; the computation of any indicator. The test: removing all candles
;; after t must produce the same indicator value at t.

;; ── Phase 3: SQLite write ──────────────────────────────────────
;;
;; PRAGMA journal_mode=WAL; synchronous=OFF;
;; CREATE TABLE candles (60 columns).
;; Batched inserts (COMMIT every 100k rows).
;; Replaces existing DB if present.

;; ── What build-candles does NOT do ─────────────────────────────
;; - Does NOT compute PELT changepoints (window-dependent, per expert)
;; - Does NOT compute Ichimoku (window-dependent, per expert)
;; - Does NOT compute Fibonacci (swing-dependent, per expert)
;; - Does NOT compute Hurst/DFA/entropy (window-dependent, per expert)
;; - Does NOT encode to vectors (that's the thought layer)
;; - Does NOT train anything (it computes, it stores, it's done)
;; - One binary. One forward pass. One SQLite file.
