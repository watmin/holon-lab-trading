"""Build the analysis SQLite database from raw BTC 5-minute candle data.

Creates holon-lab-trading/data/analysis.db with:
  - candles:       ~652K rows, all OHLCV + indicators + geometry + oracle labels
  - feature_stats: per-feature normalization stats from 2019-2020 training period
  - vectors:       empty, for on-demand hypervector caching
  - residuals:     empty, for on-demand subspace residual storage

Usage:
    ./scripts/run_with_venv.sh python holon-lab-trading/scripts/build_analysis_db.py
"""

from __future__ import annotations

import sqlite3
import sys
import time
from pathlib import Path

import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).parent.parent))

from trading.features import TechnicalFeatureFactory

DB_PATH = Path(__file__).parent.parent / "data" / "analysis.db"
PARQUET_PATH = Path(__file__).parent.parent / "data" / "btc_5m_raw.parquet"
HORIZON = 36  # 3 hours at 5-min candles
MIN_MOVES = [0.2, 0.5, 1.0, 2.0]


def log(msg: str):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def find_opportunities(close: np.ndarray, min_move_pct: float, horizon: int) -> np.ndarray:
    """Label each candle as BUY/SELL/QUIET using future knowledge.

    BUY:  price rises >= min_move_pct% within horizon candles (and before falling that much)
    SELL: price falls >= min_move_pct% within horizon candles (and before rising that much)
    QUIET: neither condition met
    """
    n = len(close)
    labels = np.full(n, "QUIET", dtype=object)

    for i in range(n - 1):
        end = min(i + 1 + horizon, n)
        if end <= i + 1:
            continue
        entry = close[i]
        tu = entry * (1 + min_move_pct / 100)
        td = entry * (1 - min_move_pct / 100)

        bh = sh = -1
        for j in range(i + 1, end):
            if bh < 0 and close[j] >= tu:
                bh = j
            if sh < 0 and close[j] <= td:
                sh = j
            if bh >= 0 and sh >= 0:
                break

        if bh >= 0 and (sh < 0 or bh <= sh):
            labels[i] = "BUY"
        elif sh >= 0:
            labels[i] = "SELL"

    return labels


def compute_geometry(df: pd.DataFrame) -> pd.DataFrame:
    """Add raw candle geometry columns."""
    o = df["open"].values.astype(float)
    h = df["high"].values.astype(float)
    lo = df["low"].values.astype(float)
    c = df["close"].values.astype(float)
    v = df["volume"].values.astype(float)

    rng = np.maximum(h - lo, 1e-10)

    df = df.copy()
    df["body"] = (c - o) / rng
    df["upper_wick"] = (h - np.maximum(o, c)) / rng
    df["lower_wick"] = (np.minimum(o, c) - lo) / rng
    df["close_pos"] = (c - lo) / rng

    vol_sma = pd.Series(v, index=df.index).rolling(20, min_periods=1).mean().values
    df["vol_rel"] = v / np.maximum(vol_sma, 1e-10)

    raw_rng = h - lo
    range_chg = np.zeros(len(df))
    safe = raw_rng[:-1] > 1e-10
    range_chg[1:] = np.where(safe, raw_rng[1:] / np.maximum(raw_rng[:-1], 1e-10) - 1, 0)
    df["range_chg"] = range_chg
    df["range_raw"] = raw_rng

    bb_span = (df["bb_upper"] - df["bb_lower"]).values
    safe_span = np.where(np.abs(bb_span) > 1e-10, bb_span, np.nan)
    df["bb_pos"] = np.where(
        np.abs(bb_span) > 1e-10,
        (c - df["bb_lower"].values) / safe_span,
        0.5,
    )

    return df


def compute_extended_features(df: pd.DataFrame) -> pd.DataFrame:
    """Add extended features beyond standard TA.

    These are designed to capture directional signal that standard indicators miss.
    All features are price-regime-independent (ratios, normalized values).
    """
    df = df.copy()
    close = df["close"]
    high = df["high"]
    low = df["low"]
    volume = df["volume"]
    o = df["open"]

    # --- More EMAs (price-relative) ---
    for span in [5, 9, 21, 100]:
        ema = close.ewm(span=span, adjust=False).mean()
        df[f"ema{span}_r"] = close / ema - 1

    # --- EMA crossovers (spread between fast/slow) ---
    ema9 = close.ewm(span=9, adjust=False).mean()
    ema21 = close.ewm(span=21, adjust=False).mean()
    df["ema_cross_9_21"] = (ema9 - ema21) / close
    df["sma_cross_20_50"] = (df["sma20"] - df["sma50"]) / close
    df["sma_cross_50_200"] = (df["sma50"] - df["sma200"]) / close

    # --- Stochastic %K / %D ---
    for period in [14, 5]:
        low_roll = low.rolling(period).min()
        high_roll = high.rolling(period).max()
        denom = (high_roll - low_roll).replace(0, np.nan)
        stoch_k = ((close - low_roll) / denom * 100).fillna(50)
        stoch_d = stoch_k.rolling(3).mean().fillna(50)
        sfx = "" if period == 14 else f"_{period}"
        df[f"stoch_k{sfx}"] = stoch_k
        df[f"stoch_d{sfx}"] = stoch_d

    # --- Williams %R ---
    high14 = high.rolling(14).max()
    low14 = low.rolling(14).min()
    denom = (high14 - low14).replace(0, np.nan)
    df["williams_r"] = (((high14 - close) / denom) * -100).fillna(-50)

    # --- CCI (Commodity Channel Index) ---
    tp = (high + low + close) / 3
    tp_sma = tp.rolling(20).mean()
    tp_mad = tp.rolling(20).apply(lambda x: np.abs(x - x.mean()).mean(), raw=True)
    df["cci"] = ((tp - tp_sma) / (0.015 * tp_mad.replace(0, np.nan))).fillna(0)

    # --- Rate of Change at multiple horizons ---
    for n in [1, 3, 6, 12, 24]:
        df[f"roc_{n}"] = close.pct_change(n).fillna(0)

    # --- Multi-bar return sums (momentum over windows) ---
    ret = close.pct_change().fillna(0)
    for n in [3, 6, 12]:
        df[f"ret_sum_{n}"] = ret.rolling(n).sum().fillna(0)

    # --- Consecutive up/down candle count ---
    is_up = (close > o).astype(int)
    consec_up = is_up.copy()
    consec_dn = (1 - is_up).copy()
    for i in range(1, len(df)):
        if is_up.iloc[i]:
            consec_up.iloc[i] = consec_up.iloc[i - 1] + 1
            consec_dn.iloc[i] = 0
        else:
            consec_dn.iloc[i] = consec_dn.iloc[i - 1] + 1
            consec_up.iloc[i] = 0
    df["consec_up"] = consec_up
    df["consec_dn"] = consec_dn

    # --- Higher highs / lower lows (trend structure) ---
    df["hh"] = (high > high.shift(1)).astype(float)
    df["ll"] = (low < low.shift(1)).astype(float)
    df["hl"] = (low > low.shift(1)).astype(float)  # higher low
    df["lh"] = (high < high.shift(1)).astype(float)  # lower high
    for n in [3, 6]:
        df[f"hh_count_{n}"] = df["hh"].rolling(n).sum().fillna(0)
        df[f"ll_count_{n}"] = df["ll"].rolling(n).sum().fillna(0)
        df[f"hl_count_{n}"] = df["hl"].rolling(n).sum().fillna(0)
        df[f"lh_count_{n}"] = df["lh"].rolling(n).sum().fillna(0)

    # --- Price position relative to recent range ---
    for n in [12, 24, 48]:
        rng_high = high.rolling(n).max()
        rng_low = low.rolling(n).min()
        rng_span = (rng_high - rng_low).replace(0, np.nan)
        df[f"range_pos_{n}"] = ((close - rng_low) / rng_span).fillna(0.5)

    # --- Volume trend (up-vol vs down-vol) ---
    up_vol = (volume * (close > o).astype(float)).rolling(12).sum().fillna(0)
    dn_vol = (volume * (close <= o).astype(float)).rolling(12).sum().fillna(0)
    total_vol = (up_vol + dn_vol).replace(0, np.nan)
    df["vol_up_ratio_12"] = (up_vol / total_vol).fillna(0.5)

    # --- OBV slope (on-balance volume trend) ---
    obv_sign = np.sign(close.diff()).fillna(0)
    obv = (obv_sign * volume).cumsum()
    obv_sma = obv.rolling(12).mean()
    obv_std = obv.rolling(12).std().replace(0, np.nan)
    df["obv_slope_12"] = ((obv - obv_sma) / obv_std).fillna(0)

    # --- MFI (Money Flow Index) ---
    tp = (high + low + close) / 3
    raw_mf = tp * volume
    pos_mf = pd.Series(np.where(tp > tp.shift(), raw_mf, 0), index=df.index)
    neg_mf = pd.Series(np.where(tp < tp.shift(), raw_mf, 0), index=df.index)
    pos_sum = pos_mf.rolling(14).sum()
    neg_sum = neg_mf.rolling(14).sum().replace(0, np.nan)
    df["mfi"] = (100 - 100 / (1 + pos_sum / neg_sum)).fillna(50)

    # --- Keltner Channel position ---
    ema20 = close.ewm(span=20, adjust=False).mean()
    kelt_atr = df["atr"] if "atr" in df.columns else (high - low).rolling(14).mean()
    kelt_upper = ema20 + 2 * kelt_atr
    kelt_lower = ema20 - 2 * kelt_atr
    kelt_span = (kelt_upper - kelt_lower).replace(0, np.nan)
    df["kelt_pos"] = ((close - kelt_lower) / kelt_span).fillna(0.5)

    # --- Squeeze: BB inside Keltner = low vol about to expand ---
    df["squeeze"] = (df["bb_upper"] < kelt_upper).astype(float) * (df["bb_lower"] > kelt_lower).astype(float)

    # --- Candle patterns (multi-bar) ---
    prev_body = (close.shift(1) - o.shift(1))
    curr_body = (close - o)
    df["engulfing"] = np.where(
        (curr_body > 0) & (prev_body < 0) & (curr_body.abs() > prev_body.abs()),
        1.0,
        np.where(
            (curr_body < 0) & (prev_body > 0) & (curr_body.abs() > prev_body.abs()),
            -1.0,
            0.0,
        ),
    )

    # --- Relative volume on up vs down moves (3-bar) ---
    vol3 = volume.rolling(3).mean().fillna(volume)
    up_candle = (close > o).astype(float)
    df["vol_direction_bias_3"] = (
        (volume * up_candle).rolling(3).sum() /
        volume.rolling(3).sum().replace(0, np.nan)
    ).fillna(0.5)

    # --- Distance from recent swing high/low ---
    for n in [12, 24]:
        swing_high = high.rolling(n).max()
        swing_low = low.rolling(n).min()
        df[f"dist_swing_high_{n}"] = (close - swing_high) / close
        df[f"dist_swing_low_{n}"] = (close - swing_low) / close

    # ===================================================================
    # UNCONVENTIONAL / NON-STANDARD FEATURES
    # ===================================================================

    # --- Volatility acceleration (is vol expanding or contracting?) ---
    atr_col = df["atr"] if "atr" in df.columns else (high - low).rolling(14).mean()
    atr_sma6 = atr_col.rolling(6).mean()
    atr_sma24 = atr_col.rolling(24).mean()
    df["vol_accel"] = (atr_sma6 / atr_sma24.replace(0, np.nan) - 1).fillna(0)
    df["atr_roc_6"] = atr_col.pct_change(6).fillna(0)
    df["atr_roc_12"] = atr_col.pct_change(12).fillna(0)

    # --- Volume-price divergence ---
    # Price going up but volume declining (or vice versa)
    ret_12 = close.pct_change(12).fillna(0)
    vol_chg_12 = volume.pct_change(12).fillna(0)
    df["vol_price_div"] = ret_12 - vol_chg_12
    vol_chg_6 = volume.pct_change(6).fillna(0)
    ret_6 = close.pct_change(6).fillna(0)
    df["vol_price_div_6"] = ret_6 - vol_chg_6

    # --- Volume on up candles vs volume on down candles (longer windows) ---
    for n in [6, 24]:
        up_v = (volume * (close > o).astype(float)).rolling(n).sum()
        dn_v = (volume * (close <= o).astype(float)).rolling(n).sum()
        total = (up_v + dn_v).replace(0, np.nan)
        df[f"vol_up_ratio_{n}"] = (up_v / total).fillna(0.5)

    # --- Surprise metrics (how unusual is this candle?) ---
    ret_series = close.pct_change().fillna(0)
    ret_mean_20 = ret_series.rolling(20).mean().fillna(0)
    ret_std_20 = ret_series.rolling(20).std().replace(0, np.nan).fillna(1)
    df["ret_zscore"] = ((ret_series - ret_mean_20) / ret_std_20).fillna(0)

    vol_mean_20 = volume.rolling(20).mean()
    vol_std_20 = volume.rolling(20).std().replace(0, np.nan).fillna(1)
    df["vol_zscore"] = ((volume - vol_mean_20) / vol_std_20).fillna(0)

    rng_series = high - low
    rng_mean_20 = rng_series.rolling(20).mean()
    rng_std_20 = rng_series.rolling(20).std().replace(0, np.nan).fillna(1)
    df["range_zscore"] = ((rng_series - rng_mean_20) / rng_std_20).fillna(0)

    # --- Body surprise (is the body size unusual?) ---
    body_abs = (close - o).abs()
    body_mean_20 = body_abs.rolling(20).mean()
    body_std_20 = body_abs.rolling(20).std().replace(0, np.nan).fillna(1)
    df["body_zscore"] = ((body_abs - body_mean_20) / body_std_20).fillna(0)

    # --- Time-of-day / day-of-week ---
    ts = pd.to_datetime(df["ts"])
    df["hour"] = ts.dt.hour
    df["dow"] = ts.dt.dayofweek  # 0=Mon, 6=Sun
    hour_rad = 2 * np.pi * ts.dt.hour / 24
    df["hour_sin"] = np.sin(hour_rad)
    df["hour_cos"] = np.cos(hour_rad)
    dow_rad = 2 * np.pi * ts.dt.dayofweek / 7
    df["dow_sin"] = np.sin(dow_rad)
    df["dow_cos"] = np.cos(dow_rad)

    # --- Multi-timeframe context (what does the 1h and 4h chart look like?) ---
    # 1h = 12 candles, 4h = 48 candles
    for tf_bars, tf_name in [(12, "1h"), (48, "4h")]:
        tf_close = close.rolling(tf_bars).apply(lambda x: x.iloc[-1], raw=False)
        tf_open = o.rolling(tf_bars).apply(lambda x: x.iloc[0], raw=False)
        tf_high = high.rolling(tf_bars).max()
        tf_low = low.rolling(tf_bars).min()
        tf_rng = (tf_high - tf_low).replace(0, np.nan)
        df[f"tf_{tf_name}_body"] = ((tf_close - tf_open) / tf_rng).fillna(0)
        df[f"tf_{tf_name}_close_pos"] = ((close - tf_low) / tf_rng).fillna(0.5)
        tf_ret = close.pct_change(tf_bars).fillna(0)
        df[f"tf_{tf_name}_ret"] = tf_ret

    # --- Trend consistency (what fraction of recent returns agree on direction?) ---
    for n in [6, 12, 24]:
        ret_signs = ret_series.rolling(n).apply(lambda x: (x > 0).mean(), raw=True)
        df[f"trend_consistency_{n}"] = ret_signs.fillna(0.5)

    # --- Gap analysis (open vs prior close) ---
    df["gap"] = (o - close.shift(1)) / close.shift(1)
    df["gap"] = df["gap"].fillna(0)

    # --- Intrabar volatility ratio (range relative to absolute return) ---
    abs_ret = (close - o).abs()
    bar_range = high - low
    df["intrabar_vol_ratio"] = (bar_range / abs_ret.replace(0, np.nan)).fillna(1).clip(0, 50)

    # --- Acceleration of momentum (second derivative of price) ---
    mom_12 = close.diff(12)
    df["mom_accel"] = mom_12.diff(6).fillna(0) / close

    # --- Clean up NaN from new rolling calculations ---
    df = df.fillna(0)

    return df


def create_schema(conn: sqlite3.Connection):
    """Create all tables and indexes."""
    conn.executescript("""
        DROP TABLE IF EXISTS candles;
        DROP TABLE IF EXISTS feature_stats;
        DROP TABLE IF EXISTS vectors;
        DROP TABLE IF EXISTS residuals;

        CREATE TABLE candles (
            ts TEXT PRIMARY KEY,
            -- OHLCV
            open REAL, high REAL, low REAL, close REAL, volume REAL,
            -- Standard indicators
            sma20 REAL, sma50 REAL, sma200 REAL,
            sma20_r REAL, sma50_r REAL, sma200_r REAL,
            bb_upper REAL, bb_lower REAL, bb_width REAL,
            macd_line REAL, macd_signal REAL, macd_hist REAL,
            macd_line_r REAL, macd_signal_r REAL, macd_hist_r REAL,
            rsi REAL,
            atr REAL, atr_r REAL,
            dmi_plus REAL, dmi_minus REAL, adx REAL,
            ret REAL,
            vol_r REAL,
            open_r REAL, high_r REAL, low_r REAL,
            -- Geometry
            body REAL, upper_wick REAL, lower_wick REAL, close_pos REAL,
            vol_rel REAL, range_chg REAL, range_raw REAL, bb_pos REAL,
            -- Extended EMAs
            ema5_r REAL, ema9_r REAL, ema21_r REAL, ema100_r REAL,
            -- EMA/SMA crossovers
            ema_cross_9_21 REAL, sma_cross_20_50 REAL, sma_cross_50_200 REAL,
            -- Stochastic
            stoch_k REAL, stoch_d REAL, stoch_k_5 REAL, stoch_d_5 REAL,
            -- Williams %R
            williams_r REAL,
            -- CCI
            cci REAL,
            -- Rate of change
            roc_1 REAL, roc_3 REAL, roc_6 REAL, roc_12 REAL, roc_24 REAL,
            -- Multi-bar momentum
            ret_sum_3 REAL, ret_sum_6 REAL, ret_sum_12 REAL,
            -- Consecutive candles
            consec_up REAL, consec_dn REAL,
            -- Trend structure
            hh REAL, ll REAL, hl REAL, lh REAL,
            hh_count_3 REAL, ll_count_3 REAL, hl_count_3 REAL, lh_count_3 REAL,
            hh_count_6 REAL, ll_count_6 REAL, hl_count_6 REAL, lh_count_6 REAL,
            -- Price position in range
            range_pos_12 REAL, range_pos_24 REAL, range_pos_48 REAL,
            -- Volume structure
            vol_up_ratio_12 REAL, obv_slope_12 REAL, mfi REAL,
            vol_direction_bias_3 REAL,
            -- Keltner / Squeeze
            kelt_pos REAL, squeeze REAL,
            -- Candlestick patterns
            engulfing REAL,
            -- Swing distance
            dist_swing_high_12 REAL, dist_swing_low_12 REAL,
            dist_swing_high_24 REAL, dist_swing_low_24 REAL,
            -- Volatility dynamics
            vol_accel REAL, atr_roc_6 REAL, atr_roc_12 REAL,
            -- Volume-price divergence
            vol_price_div REAL, vol_price_div_6 REAL,
            vol_up_ratio_6 REAL, vol_up_ratio_24 REAL,
            -- Surprise metrics
            ret_zscore REAL, vol_zscore REAL, range_zscore REAL, body_zscore REAL,
            -- Time
            hour INTEGER, dow INTEGER,
            hour_sin REAL, hour_cos REAL, dow_sin REAL, dow_cos REAL,
            -- Multi-timeframe
            tf_1h_body REAL, tf_1h_close_pos REAL, tf_1h_ret REAL,
            tf_4h_body REAL, tf_4h_close_pos REAL, tf_4h_ret REAL,
            -- Trend consistency
            trend_consistency_6 REAL, trend_consistency_12 REAL, trend_consistency_24 REAL,
            -- Microstructure
            gap REAL, intrabar_vol_ratio REAL, mom_accel REAL,
            -- Labels
            label_oracle_02 TEXT, label_oracle_05 TEXT,
            label_oracle_10 TEXT, label_oracle_20 TEXT,
            -- Convenience
            year INTEGER
        );

        CREATE TABLE feature_stats (
            feature TEXT PRIMARY KEY,
            mean REAL, std REAL, min REAL, max REAL,
            p01 REAL, p99 REAL
        );

        CREATE TABLE vectors (
            ts TEXT,
            scheme TEXT,
            stripe_idx INTEGER,
            vec BLOB,
            PRIMARY KEY (ts, scheme, stripe_idx)
        );

        CREATE TABLE residuals (
            ts TEXT,
            model TEXT,
            residual REAL,
            PRIMARY KEY (ts, model)
        );
    """)


def create_indexes(conn: sqlite3.Connection):
    """Create indexes after bulk insert for speed."""
    log("Creating indexes...")
    conn.executescript("""
        CREATE INDEX IF NOT EXISTS idx_candles_year ON candles(year);
        CREATE INDEX IF NOT EXISTS idx_candles_oracle05 ON candles(label_oracle_05);
        CREATE INDEX IF NOT EXISTS idx_candles_year_oracle05 ON candles(year, label_oracle_05);
        CREATE INDEX IF NOT EXISTS idx_vectors_ts_scheme ON vectors(ts, scheme);
        CREATE INDEX IF NOT EXISTS idx_residuals_ts_model ON residuals(ts, model);
    """)


def compute_feature_stats(conn: sqlite3.Connection):
    """Compute per-feature normalization stats from 2019-2020 training period."""
    log("Computing feature stats from 2019-2020...")

    feature_cols = [
        # Original
        "sma20_r", "sma50_r", "sma200_r", "bb_width",
        "macd_line_r", "macd_signal_r", "macd_hist_r",
        "rsi", "atr_r", "dmi_plus", "dmi_minus", "adx",
        "ret", "vol_r", "open_r", "high_r", "low_r",
        "body", "upper_wick", "lower_wick", "close_pos",
        "vol_rel", "range_chg", "bb_pos",
        # Extended EMAs
        "ema5_r", "ema9_r", "ema21_r", "ema100_r",
        # Crossovers
        "ema_cross_9_21", "sma_cross_20_50", "sma_cross_50_200",
        # Oscillators
        "stoch_k", "stoch_d", "stoch_k_5", "stoch_d_5",
        "williams_r", "cci", "mfi",
        # Rate of change
        "roc_1", "roc_3", "roc_6", "roc_12", "roc_24",
        # Momentum sums
        "ret_sum_3", "ret_sum_6", "ret_sum_12",
        # Consecutive
        "consec_up", "consec_dn",
        # Trend structure
        "hh", "ll", "hl", "lh",
        "hh_count_3", "ll_count_3", "hl_count_3", "lh_count_3",
        "hh_count_6", "ll_count_6", "hl_count_6", "lh_count_6",
        # Range position
        "range_pos_12", "range_pos_24", "range_pos_48",
        # Volume structure
        "vol_up_ratio_12", "obv_slope_12", "vol_direction_bias_3",
        # Keltner / Squeeze
        "kelt_pos", "squeeze",
        # Patterns
        "engulfing",
        # Swing distance
        "dist_swing_high_12", "dist_swing_low_12",
        "dist_swing_high_24", "dist_swing_low_24",
        # Volatility dynamics
        "vol_accel", "atr_roc_6", "atr_roc_12",
        # Volume-price divergence
        "vol_price_div", "vol_price_div_6",
        "vol_up_ratio_6", "vol_up_ratio_24",
        # Surprise metrics
        "ret_zscore", "vol_zscore", "range_zscore", "body_zscore",
        # Time
        "hour_sin", "hour_cos", "dow_sin", "dow_cos",
        # Multi-timeframe
        "tf_1h_body", "tf_1h_close_pos", "tf_1h_ret",
        "tf_4h_body", "tf_4h_close_pos", "tf_4h_ret",
        # Trend consistency
        "trend_consistency_6", "trend_consistency_12", "trend_consistency_24",
        # Microstructure
        "gap", "intrabar_vol_ratio", "mom_accel",
    ]

    for col in feature_cols:
        vals = conn.execute(f"""
            SELECT {col} FROM candles
            WHERE year BETWEEN 2019 AND 2020 AND {col} IS NOT NULL
        """).fetchall()

        if vals:
            arr = np.array([v[0] for v in vals], dtype=float)
            mean_val = float(np.mean(arr))
            std_val = float(np.std(arr))
            min_val = float(np.min(arr))
            max_val = float(np.max(arr))
            p01 = float(np.percentile(arr, 1))
            p99 = float(np.percentile(arr, 99))
        else:
            mean_val, std_val, min_val, max_val, p01, p99 = 0.0, 1.0, 0.0, 0.0, 0.0, 0.0

        conn.execute(
            "INSERT INTO feature_stats (feature, mean, std, min, max, p01, p99) VALUES (?, ?, ?, ?, ?, ?, ?)",
            (col, mean_val, std_val, min_val, max_val, p01, p99),
        )

    conn.commit()
    n = conn.execute("SELECT COUNT(*) FROM feature_stats").fetchone()[0]
    log(f"  Stored stats for {n} features")


def main():
    log("=" * 70)
    log("Building analysis database")
    log("=" * 70)

    # Load raw data
    log(f"Loading {PARQUET_PATH}...")
    df_raw = pd.read_parquet(PARQUET_PATH)
    log(f"  {len(df_raw):,} raw candles, {df_raw['ts'].min()} to {df_raw['ts'].max()}")

    # Compute indicators
    log("Computing technical indicators...")
    factory = TechnicalFeatureFactory()
    df_ind = factory.compute_indicators(df_raw)
    log(f"  {len(df_ind):,} candles after dropna (lost {len(df_raw) - len(df_ind):,} to indicator warmup)")

    # Compute geometry
    log("Computing candle geometry...")
    df = compute_geometry(df_ind)

    # Compute extended features
    log("Computing extended features...")
    df = compute_extended_features(df)

    # Compute oracle labels at 4 thresholds
    close = df["close"].values.astype(float)
    for min_move in MIN_MOVES:
        col = f"label_oracle_{str(min_move).replace('.', '')}"
        # Normalize column name: 0.2 -> 02, 0.5 -> 05, 1.0 -> 10, 2.0 -> 20
        if min_move == 0.2:
            col = "label_oracle_02"
        elif min_move == 0.5:
            col = "label_oracle_05"
        elif min_move == 1.0:
            col = "label_oracle_10"
        elif min_move == 2.0:
            col = "label_oracle_20"

        log(f"  Labeling oracle {min_move}% / {HORIZON} candles -> {col}...")
        t0 = time.time()
        labels = find_opportunities(close, min_move, HORIZON)
        n_buy = (labels == "BUY").sum()
        n_sell = (labels == "SELL").sum()
        n_quiet = (labels == "QUIET").sum()
        elapsed = time.time() - t0
        log(f"    {n_buy:,} BUY / {n_sell:,} SELL / {n_quiet:,} QUIET ({elapsed:.1f}s)")
        df[col] = labels

    # Add year column
    df["year"] = pd.to_datetime(df["ts"]).dt.year

    # Write to SQLite
    log(f"Writing to {DB_PATH}...")
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    if DB_PATH.exists():
        DB_PATH.unlink()

    conn = sqlite3.connect(str(DB_PATH))
    create_schema(conn)

    # Select columns in schema order
    candle_cols = [
        "ts", "open", "high", "low", "close", "volume",
        "sma20", "sma50", "sma200",
        "sma20_r", "sma50_r", "sma200_r",
        "bb_upper", "bb_lower", "bb_width",
        "macd_line", "macd_signal", "macd_hist",
        "macd_line_r", "macd_signal_r", "macd_hist_r",
        "rsi", "atr", "atr_r",
        "dmi_plus", "dmi_minus", "adx",
        "ret", "vol_r", "open_r", "high_r", "low_r",
        "body", "upper_wick", "lower_wick", "close_pos",
        "vol_rel", "range_chg", "range_raw", "bb_pos",
        # Extended EMAs
        "ema5_r", "ema9_r", "ema21_r", "ema100_r",
        # EMA/SMA crossovers
        "ema_cross_9_21", "sma_cross_20_50", "sma_cross_50_200",
        # Stochastic
        "stoch_k", "stoch_d", "stoch_k_5", "stoch_d_5",
        # Williams %R
        "williams_r",
        # CCI
        "cci",
        # Rate of change
        "roc_1", "roc_3", "roc_6", "roc_12", "roc_24",
        # Multi-bar momentum
        "ret_sum_3", "ret_sum_6", "ret_sum_12",
        # Consecutive candles
        "consec_up", "consec_dn",
        # Trend structure
        "hh", "ll", "hl", "lh",
        "hh_count_3", "ll_count_3", "hl_count_3", "lh_count_3",
        "hh_count_6", "ll_count_6", "hl_count_6", "lh_count_6",
        # Price position in range
        "range_pos_12", "range_pos_24", "range_pos_48",
        # Volume structure
        "vol_up_ratio_12", "obv_slope_12", "mfi",
        "vol_direction_bias_3",
        # Keltner / Squeeze
        "kelt_pos", "squeeze",
        # Candlestick patterns
        "engulfing",
        # Swing distance
        "dist_swing_high_12", "dist_swing_low_12",
        "dist_swing_high_24", "dist_swing_low_24",
        # Volatility dynamics
        "vol_accel", "atr_roc_6", "atr_roc_12",
        # Volume-price divergence
        "vol_price_div", "vol_price_div_6",
        "vol_up_ratio_6", "vol_up_ratio_24",
        # Surprise metrics
        "ret_zscore", "vol_zscore", "range_zscore", "body_zscore",
        # Time
        "hour", "dow",
        "hour_sin", "hour_cos", "dow_sin", "dow_cos",
        # Multi-timeframe
        "tf_1h_body", "tf_1h_close_pos", "tf_1h_ret",
        "tf_4h_body", "tf_4h_close_pos", "tf_4h_ret",
        # Trend consistency
        "trend_consistency_6", "trend_consistency_12", "trend_consistency_24",
        # Microstructure
        "gap", "intrabar_vol_ratio", "mom_accel",
        # Labels
        "label_oracle_02", "label_oracle_05",
        "label_oracle_10", "label_oracle_20",
        "year",
    ]

    # Convert ts to string for SQLite
    df["ts"] = pd.to_datetime(df["ts"]).dt.strftime("%Y-%m-%d %H:%M:%S")

    placeholders = ",".join(["?"] * len(candle_cols))
    insert_sql = f"INSERT INTO candles ({','.join(candle_cols)}) VALUES ({placeholders})"

    log("  Inserting candles...")
    t0 = time.time()
    batch_size = 50_000
    rows = df[candle_cols].values.tolist()
    for start in range(0, len(rows), batch_size):
        batch = rows[start : start + batch_size]
        conn.executemany(insert_sql, batch)
        conn.commit()
        log(f"    {min(start + batch_size, len(rows)):,} / {len(rows):,}")

    elapsed = time.time() - t0
    log(f"  Inserted {len(rows):,} candles in {elapsed:.1f}s")

    # Create indexes
    create_indexes(conn)

    # Compute feature stats
    compute_feature_stats(conn)

    # Final stats
    n = conn.execute("SELECT COUNT(*) FROM candles").fetchone()[0]
    years = conn.execute("SELECT DISTINCT year FROM candles ORDER BY year").fetchall()
    log(f"\nDatabase ready: {n:,} candles, years {[y[0] for y in years]}")

    # Quick label distribution
    for label_col in ["label_oracle_02", "label_oracle_05", "label_oracle_10", "label_oracle_20"]:
        dist = conn.execute(f"""
            SELECT {label_col}, COUNT(*), ROUND(100.0 * COUNT(*) / (SELECT COUNT(*) FROM candles), 1)
            FROM candles GROUP BY {label_col}
        """).fetchall()
        log(f"  {label_col}: {dict((r[0], f'{r[1]:,} ({r[2]}%)') for r in dist)}")

    db_size = DB_PATH.stat().st_size / 1e6
    log(f"\n  DB size: {db_size:.1f} MB")
    log(f"  Path: {DB_PATH}")

    conn.close()
    log("DONE")


if __name__ == "__main__":
    main()
