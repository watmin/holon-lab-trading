"""Categorical Algebra Refinement — Symbolic market state encoding.

Instead of encoding numerical TA values (which produce 99.6% similar vectors),
encode categorical FACTS about the market state:
  - Price position relative to moving averages (above/below)
  - RSI zone (oversold/neutral/overbought)
  - MACD state (bullish/bearish crossover, histogram direction)
  - Trend strength and direction from DMI/ADX
  - Bollinger Band zone
  - Candlestick type
  - Volume regime

Facts are conditionally present — only true statements appear in the encoding.
This produces maximally different vectors for different market states, because
"close_above_sma200" and "close_below_sma200" are orthogonal atoms, not
nearby points on a LinearScale.

Usage:
    ./scripts/run_with_venv.sh python holon-lab-trading/scripts/categorical_refine.py \\
        --n 5000 --workers 6
"""

from __future__ import annotations

import argparse
import multiprocessing as mp
import sqlite3
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Set, Tuple

import numpy as np

sys.path.insert(0, str(Path(__file__).parent.parent))

from holon import (
    DeterministicVectorManager,
    Encoder,
    StripedSubspace,
    amplify,
    cosine_similarity,
    difference,
    grover_amplify,
    reject,
    resonance,
)

DB_PATH = Path(__file__).parent.parent / "data" / "analysis.db"
SUPERVISED_YEARS = {2019, 2020}
RESOLUTION_CANDLES = 36
MIN_MOVE_PCT = 1.0

ALL_DB_COLS = [
    "ts", "year", "close", "open", "high", "low", "volume",
    "sma20", "sma50", "sma200",
    "bb_upper", "bb_lower",
    "rsi",
    "macd_line", "macd_signal", "macd_hist",
    "dmi_plus", "dmi_minus", "adx",
    "atr_r",
    "stoch_k", "stoch_d", "williams_r", "cci", "mfi",
    "roc_1", "roc_3", "roc_6", "roc_12",
    "consec_up", "consec_dn",
    "hh", "ll", "squeeze", "engulfing",
    "ret_zscore", "vol_zscore",
    "tf_1h_ret", "tf_4h_ret",
    "vol_up_ratio_12", "obv_slope_12",
    "label_oracle_10",
]


def log(msg: str):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def sf(v):
    return 0.0 if v is None else float(v)


# =========================================================================
# Categorical market state extraction
# =========================================================================

def candle_facts(c: dict) -> dict:
    """Extract categorical facts from a single candle's raw values."""
    close = sf(c.get("close"))
    open_ = sf(c.get("open"))
    high = sf(c.get("high"))
    low = sf(c.get("low"))
    sma20 = sf(c.get("sma20"))
    sma50 = sf(c.get("sma50"))
    sma200 = sf(c.get("sma200"))
    bb_upper = sf(c.get("bb_upper"))
    bb_lower = sf(c.get("bb_lower"))
    rsi = sf(c.get("rsi"))
    macd_line = sf(c.get("macd_line"))
    macd_signal = sf(c.get("macd_signal"))
    macd_hist = sf(c.get("macd_hist"))
    dmi_plus = sf(c.get("dmi_plus"))
    dmi_minus = sf(c.get("dmi_minus"))
    adx = sf(c.get("adx"))
    volume = sf(c.get("volume"))

    facts: dict = {}

    # --- Price position (set of true facts) ---
    positions: Set[str] = set()
    if close > 0 and sma20 > 0:
        positions.add("close_above_sma20" if close > sma20 else "close_below_sma20")
    if close > 0 and sma50 > 0:
        positions.add("close_above_sma50" if close > sma50 else "close_below_sma50")
    if close > 0 and sma200 > 0:
        positions.add("close_above_sma200" if close > sma200 else "close_below_sma200")

    # MA alignment
    if sma20 > 0 and sma50 > 0:
        positions.add("sma20_above_sma50" if sma20 > sma50 else "sma20_below_sma50")
    if sma50 > 0 and sma200 > 0:
        positions.add("sma50_above_sma200" if sma50 > sma200 else "sma50_below_sma200")
    if sma20 > 0 and sma200 > 0:
        positions.add("sma20_above_sma200" if sma20 > sma200 else "sma20_below_sma200")

    if positions:
        facts["position"] = positions

    # --- Bollinger Band zone ---
    if bb_upper > 0 and bb_lower > 0 and close > 0:
        bb_mid = (bb_upper + bb_lower) / 2.0
        bb_width = bb_upper - bb_lower
        if bb_width > 0:
            bb_pct = (close - bb_lower) / bb_width
            if bb_pct > 1.0:
                facts["bb_zone"] = "above_upper"
            elif bb_pct > 0.8:
                facts["bb_zone"] = "upper"
            elif bb_pct > 0.5:
                facts["bb_zone"] = "mid_upper"
            elif bb_pct > 0.2:
                facts["bb_zone"] = "mid_lower"
            elif bb_pct > 0.0:
                facts["bb_zone"] = "lower"
            else:
                facts["bb_zone"] = "below_lower"

            # BB squeeze detection
            avg_price = (high + low) / 2.0 if (high + low) > 0 else 1.0
            bb_width_pct = bb_width / avg_price
            if bb_width_pct < 0.02:
                facts["bb_squeeze"] = "tight"
            elif bb_width_pct > 0.08:
                facts["bb_squeeze"] = "wide"

    # --- RSI zone ---
    if rsi > 0:
        if rsi < 20:
            facts["rsi"] = "extreme_oversold"
        elif rsi < 30:
            facts["rsi"] = "oversold"
        elif rsi < 45:
            facts["rsi"] = "weak"
        elif rsi < 55:
            facts["rsi"] = "neutral"
        elif rsi < 70:
            facts["rsi"] = "strong"
        elif rsi < 80:
            facts["rsi"] = "overbought"
        else:
            facts["rsi"] = "extreme_overbought"

    # --- MACD state ---
    macd_facts: Set[str] = set()
    if macd_line != 0 or macd_signal != 0:
        macd_facts.add("line_above_signal" if macd_line > macd_signal
                       else "line_below_signal")
        macd_facts.add("line_positive" if macd_line > 0 else "line_negative")
    if macd_hist != 0:
        macd_facts.add("hist_positive" if macd_hist > 0 else "hist_negative")
    if macd_facts:
        facts["macd"] = macd_facts

    # --- DMI/ADX trend ---
    if dmi_plus > 0 or dmi_minus > 0:
        facts["trend_dir"] = ("bullish" if dmi_plus > dmi_minus
                              else "bearish")
    if adx > 0:
        if adx < 15:
            facts["trend_strength"] = "absent"
        elif adx < 25:
            facts["trend_strength"] = "weak"
        elif adx < 40:
            facts["trend_strength"] = "moderate"
        elif adx < 55:
            facts["trend_strength"] = "strong"
        else:
            facts["trend_strength"] = "extreme"

    # --- Candlestick type ---
    if close > 0 and open_ > 0:
        body = abs(close - open_)
        wick = high - low if high > low else 0.001
        body_ratio = body / wick if wick > 0 else 0

        if body_ratio < 0.1:
            facts["candle"] = "doji"
        elif close > open_:
            facts["candle"] = "bullish"
        else:
            facts["candle"] = "bearish"

        # Shadow analysis
        if close >= open_:
            upper_shadow = high - close
            lower_shadow = open_ - low
        else:
            upper_shadow = high - open_
            lower_shadow = close - low

        if wick > 0:
            if lower_shadow / wick > 0.6 and body_ratio < 0.3:
                facts["candle_pattern"] = "hammer"
            elif upper_shadow / wick > 0.6 and body_ratio < 0.3:
                facts["candle_pattern"] = "shooting_star"

    # =================================================================
    # Conditional-only keys — ABSENT when condition is false.
    # Key absence changes the encoded vector structure, mirroring the
    # spectral firewall's conditional key presence pattern.
    # =================================================================

    # RSI extremes (conditional — only present at extremes)
    if rsi > 0 and rsi < 30:
        facts["oversold"] = True
    if rsi > 0 and rsi > 70:
        facts["overbought"] = True

    # BB breakout (conditional)
    if close > 0 and bb_upper > 0 and close > bb_upper:
        facts["bb_breakout_up"] = True
    if close > 0 and bb_lower > 0 and close < bb_lower:
        facts["bb_breakout_down"] = True

    # Stochastic extremes
    stoch_k = sf(c.get("stoch_k"))
    if stoch_k > 0:
        if stoch_k < 20:
            facts["stoch_oversold"] = True
        elif stoch_k > 80:
            facts["stoch_overbought"] = True

    # Williams %R extremes
    williams_r = sf(c.get("williams_r"))
    if williams_r != 0:
        if williams_r < -80:
            facts["williams_oversold"] = True
        elif williams_r > -20:
            facts["williams_overbought"] = True

    # CCI extremes
    cci = sf(c.get("cci"))
    if cci != 0:
        if cci < -100:
            facts["cci_oversold"] = True
        elif cci > 100:
            facts["cci_overbought"] = True

    # MFI extremes
    mfi = sf(c.get("mfi"))
    if mfi > 0:
        if mfi < 20:
            facts["mfi_oversold"] = True
        elif mfi > 80:
            facts["mfi_overbought"] = True

    # Squeeze firing
    squeeze = sf(c.get("squeeze"))
    if squeeze > 0:
        facts["squeeze_active"] = True

    # Engulfing pattern
    engulfing = sf(c.get("engulfing"))
    if engulfing > 0:
        facts["engulfing_bull"] = True
    elif engulfing < 0:
        facts["engulfing_bear"] = True

    # Extreme returns (z-score based)
    ret_z = sf(c.get("ret_zscore"))
    if ret_z > 2.0:
        facts["return_extreme_up"] = True
    elif ret_z < -2.0:
        facts["return_extreme_down"] = True

    # Extreme volume
    vol_z = sf(c.get("vol_zscore"))
    if vol_z > 2.0:
        facts["vol_extreme"] = True

    # Consecutive candle streaks
    consec_up = sf(c.get("consec_up"))
    consec_dn = sf(c.get("consec_dn"))
    if consec_up >= 3:
        facts["streak_up"] = True
    if consec_dn >= 3:
        facts["streak_down"] = True

    # Structure: higher-high / lower-low
    if sf(c.get("hh")) > 0:
        facts["higher_high"] = True
    if sf(c.get("ll")) > 0:
        facts["lower_low"] = True

    # Momentum from ROC-12
    roc_12 = sf(c.get("roc_12"))
    if roc_12 != 0:
        if roc_12 > 2.0:
            facts["momentum"] = "strong_up"
        elif roc_12 > 0.5:
            facts["momentum"] = "up"
        elif roc_12 > -0.5:
            facts["momentum"] = "flat"
        elif roc_12 > -2.0:
            facts["momentum"] = "down"
        else:
            facts["momentum"] = "strong_down"

    # Multi-timeframe direction
    tf_1h = sf(c.get("tf_1h_ret"))
    if tf_1h != 0:
        facts["tf_1h"] = "up" if tf_1h > 0 else "down"
    tf_4h = sf(c.get("tf_4h_ret"))
    if tf_4h != 0:
        facts["tf_4h"] = "up" if tf_4h > 0 else "down"

    return facts


def build_categorical_data(candles: list, idx: int, window_size: int) -> dict:
    """Build categorical Holon encoding for a window of candles."""
    start = max(0, idx - window_size + 1)
    window = candles[start:idx + 1]
    if len(window) < window_size:
        window = [window[0]] * (window_size - len(window)) + list(window)

    data = {}
    prev_macd_hist = None
    prev_volume = None

    for t, c in enumerate(window):
        facts = candle_facts(c)

        # Temporal MACD histogram direction (needs prev candle)
        macd_hist = sf(c.get("macd_hist"))
        if prev_macd_hist is not None:
            if "macd" not in facts:
                facts["macd"] = set()
            if isinstance(facts["macd"], set):
                facts["macd"].add(
                    "hist_growing" if abs(macd_hist) > abs(prev_macd_hist)
                    else "hist_shrinking"
                )
        prev_macd_hist = macd_hist

        # Volume relative to previous candle
        vol = sf(c.get("volume"))
        if prev_volume is not None and prev_volume > 0:
            vol_ratio = vol / prev_volume
            if vol_ratio > 2.0:
                facts["volume"] = "spike"
                facts["volume_spike"] = True
            elif vol_ratio > 1.3:
                facts["volume"] = "above_avg"
            elif vol_ratio > 0.7:
                facts["volume"] = "normal"
            else:
                facts["volume"] = "low"
        prev_volume = vol

        # MACD cross (conditional — only present at crossover)
        macd_hist = sf(c.get("macd_hist"))
        if prev_macd_hist is not None:
            if macd_hist > 0 and prev_macd_hist <= 0:
                facts["macd_cross_bull"] = True
            elif macd_hist < 0 and prev_macd_hist >= 0:
                facts["macd_cross_bear"] = True

        if facts:
            data[f"t{t}"] = facts

    return data


# =========================================================================
# Visual monitor encoding — spatial grid + shape descriptors
# =========================================================================

N_ROWS = 20  # grid resolution per panel


def _to_row(val_01: float) -> str:
    """Discretize a 0-1 value into a row label."""
    idx = int(val_01 * (N_ROWS - 1) + 0.5)
    return f"r{max(0, min(N_ROWS - 1, idx))}"


def _lin_slope(values: list) -> str:
    """Classify the slope of a value series."""
    n = len(values)
    if n < 3:
        return "flat"
    xs = np.arange(n, dtype=np.float64)
    ys = np.array(values, dtype=np.float64)
    valid = ys > 0
    if valid.sum() < 3:
        return "flat"
    xs, ys = xs[valid], ys[valid]
    mean_x = xs.mean()
    mean_y = ys.mean()
    denom = ((xs - mean_x) ** 2).sum()
    if denom < 1e-12:
        return "flat"
    slope = ((xs - mean_x) * (ys - mean_y)).sum() / denom
    rel = slope / (mean_y + 1e-10)
    if rel > 0.02:
        return "strong_up"
    elif rel > 0.005:
        return "up"
    elif rel > -0.005:
        return "flat"
    elif rel > -0.02:
        return "down"
    return "strong_down"


def _direction(slope_label: str) -> int:
    if slope_label in ("strong_up", "up"):
        return 1
    if slope_label in ("strong_down", "down"):
        return -1
    return 0


def compute_shapes(window: list) -> dict:
    """Compute cross-time shape descriptors over a candle window."""
    shapes: dict = {}
    n = len(window)

    closes = [sf(c.get("close")) for c in window]
    rsis = [sf(c.get("rsi")) for c in window]
    macds = [sf(c.get("macd_hist")) for c in window]
    volumes = [sf(c.get("volume")) for c in window]
    bb_ups = [sf(c.get("bb_upper")) for c in window]
    bb_los = [sf(c.get("bb_lower")) for c in window]

    for span in (6, 12, 24):
        if n < span:
            continue
        tail = closes[-span:]
        shapes[f"price_slope_{span}"] = _lin_slope(tail)
        shapes[f"rsi_slope_{span}"] = _lin_slope(rsis[-span:])

    price_dir = _direction(shapes.get("price_slope_12", "flat"))
    rsi_dir = _direction(shapes.get("rsi_slope_12", "flat"))
    macd_slope = _lin_slope(macds[-12:]) if n >= 12 else "flat"
    shapes["macd_slope_12"] = macd_slope
    macd_dir = _direction(macd_slope)

    if price_dir != 0 and rsi_dir != 0 and price_dir != rsi_dir:
        shapes["divergence_rsi"] = "bearish" if price_dir > 0 else "bullish"
    if price_dir != 0 and macd_dir != 0 and price_dir != macd_dir:
        shapes["divergence_macd"] = "bearish" if price_dir > 0 else "bullish"

    # BB state: squeeze vs expansion
    if n >= 12:
        early_widths = [
            bb_ups[i] - bb_los[i]
            for i in range(0, min(6, n))
            if bb_ups[i] > 0 and bb_los[i] > 0
        ]
        late_widths = [
            bb_ups[i] - bb_los[i]
            for i in range(n - 6, n)
            if bb_ups[i] > 0 and bb_los[i] > 0
        ]
        if early_widths and late_widths:
            ew = sum(early_widths) / len(early_widths)
            lw = sum(late_widths) / len(late_widths)
            ratio = lw / (ew + 1e-10)
            if ratio < 0.7:
                shapes["bb_state"] = "squeezing"
            elif ratio > 1.4:
                shapes["bb_state"] = "expanding"
            else:
                shapes["bb_state"] = "stable"

    last = window[-1]
    last_close = sf(last.get("close"))
    last_bb_up = sf(last.get("bb_upper"))
    last_bb_lo = sf(last.get("bb_lower"))
    if last_bb_up > 0 and last_bb_lo > 0 and last_close > 0:
        bb_range = last_bb_up - last_bb_lo
        if bb_range > 0:
            pos = (last_close - last_bb_lo) / bb_range
            if pos > 0.9:
                shapes["bb_position"] = "walking_upper"
            elif pos < 0.1:
                shapes["bb_position"] = "walking_lower"
            else:
                shapes["bb_position"] = "inside"

    # Price structure: higher-highs/lower-lows detection
    if n >= 12:
        q = n // 4
        highs = [sf(c.get("high")) for c in window]
        lows = [sf(c.get("low")) for c in window]
        seg_highs = [max(highs[i * q:(i + 1) * q] or [0]) for i in range(4)]
        seg_lows = [min(lows[i * q:(i + 1) * q] or [1e18]) for i in range(4)]

        hh = all(seg_highs[i] <= seg_highs[i + 1] for i in range(3))
        ll = all(seg_lows[i] >= seg_lows[i + 1] for i in range(3))
        hl = all(seg_lows[i] <= seg_lows[i + 1] for i in range(3))
        lh = all(seg_highs[i] >= seg_highs[i + 1] for i in range(3))

        if hh and hl:
            shapes["price_structure"] = "uptrend"
        elif ll and lh:
            shapes["price_structure"] = "downtrend"
        elif hl and not hh:
            shapes["price_structure"] = "ascending_triangle"
        elif lh and not ll:
            shapes["price_structure"] = "descending_triangle"
        else:
            shapes["price_structure"] = "ranging"

    # Volume profile
    if n >= 12:
        vol_early = volumes[:n // 2]
        vol_late = volumes[n // 2:]
        avg_early = sum(vol_early) / (len(vol_early) or 1)
        avg_late = sum(vol_late) / (len(vol_late) or 1)
        max_vol = max(volumes) if volumes else 1
        last_vol = volumes[-1]

        if last_vol > avg_late * 2.5 and last_vol == max_vol:
            shapes["volume_profile"] = "climax"
        elif avg_late > avg_early * 1.3 and price_dir != 0:
            shapes["volume_profile"] = "confirmation"
        elif avg_late < avg_early * 0.7 and price_dir != 0:
            shapes["volume_profile"] = "divergence"
        else:
            shapes["volume_profile"] = "neutral"

    # MACD histogram trend
    if n >= 6:
        recent_hist = macds[-6:]
        valid_hist = [h for h in recent_hist if h != 0]
        if len(valid_hist) >= 3:
            abs_trend = [abs(valid_hist[i + 1]) - abs(valid_hist[i])
                         for i in range(len(valid_hist) - 1)]
            growing = sum(1 for d in abs_trend if d > 0)
            if macds[-1] > 0 and macds[-2] <= 0:
                shapes["macd_hist_event"] = "crossed_zero_up"
            elif macds[-1] < 0 and macds[-2] >= 0:
                shapes["macd_hist_event"] = "crossed_zero_down"
            elif growing > len(abs_trend) // 2:
                shapes["macd_hist_trend"] = "growing"
            else:
                shapes["macd_hist_trend"] = "shrinking"

    return shapes


def build_monitor_data(candles: list, idx: int, window_size: int) -> dict:
    """Build visual monitor encoding: spatial grid positions + shape descriptors."""
    start = max(0, idx - window_size + 1)
    window = candles[start:idx + 1]
    if len(window) < window_size:
        window = [window[0]] * (window_size - len(window)) + list(window)

    # --- Collect raw values for normalization ---
    closes = [sf(c.get("close")) for c in window]
    opens = [sf(c.get("open")) for c in window]
    highs = [sf(c.get("high")) for c in window]
    lows = [sf(c.get("low")) for c in window]
    sma20s = [sf(c.get("sma20")) for c in window]
    sma50s = [sf(c.get("sma50")) for c in window]
    sma200s = [sf(c.get("sma200")) for c in window]
    bb_ups = [sf(c.get("bb_upper")) for c in window]
    bb_los = [sf(c.get("bb_lower")) for c in window]
    volumes = [sf(c.get("volume")) for c in window]
    rsis = [sf(c.get("rsi")) for c in window]
    macd_lines = [sf(c.get("macd_line")) for c in window]
    macd_sigs = [sf(c.get("macd_signal")) for c in window]
    macd_hists = [sf(c.get("macd_hist")) for c in window]

    # --- Price panel viewport ---
    vp_vals = []
    for vs in (closes, opens, highs, lows, sma20s, sma50s, sma200s):
        vp_vals.extend(v for v in vs if v > 0)
    if not vp_vals:
        vp_vals = [1.0]
    vp_lo, vp_hi = min(vp_vals), max(vp_vals)
    vp_range = vp_hi - vp_lo
    margin = vp_range * 0.05
    vp_lo -= margin
    vp_hi += margin
    vp_range = vp_hi - vp_lo if (vp_hi - vp_lo) > 1e-10 else 1.0

    def price_norm(v):
        if v <= 0:
            return 0.5
        return max(0.0, min(1.0, (v - vp_lo) / vp_range))

    # --- Volume panel ---
    vol_max = max(volumes) if volumes else 1.0
    vol_max = vol_max if vol_max > 0 else 1.0

    # --- MACD panel ---
    macd_all = macd_lines + macd_sigs + macd_hists
    m_lo = min(macd_all) if macd_all else 0.0
    m_hi = max(macd_all) if macd_all else 1.0
    m_range = m_hi - m_lo if (m_hi - m_lo) > 1e-10 else 1.0

    # --- Build spatial grid ---
    data: dict = {}

    price_panel: dict = {}
    vol_panel: dict = {}
    rsi_panel: dict = {}
    macd_panel: dict = {}

    for t in range(len(window)):
        c = window[t]
        tk = f"t{t}"

        # Price panel: close, open, high, low, sma20, sma50, sma200, bb
        p: dict = {}
        p["close"] = _to_row(price_norm(closes[t]))
        p["open"] = _to_row(price_norm(opens[t]))
        p["high"] = _to_row(price_norm(highs[t]))
        p["low"] = _to_row(price_norm(lows[t]))
        if sma20s[t] > 0:
            p["sma20"] = _to_row(price_norm(sma20s[t]))
        if sma50s[t] > 0:
            p["sma50"] = _to_row(price_norm(sma50s[t]))
        if sma200s[t] > 0:
            p["sma200"] = _to_row(price_norm(sma200s[t]))
        if bb_ups[t] > 0:
            p["bb_up"] = _to_row(price_norm(bb_ups[t]))
        if bb_los[t] > 0:
            p["bb_lo"] = _to_row(price_norm(bb_los[t]))

        # Candle body type
        if closes[t] > opens[t]:
            p["body"] = "bull"
        elif closes[t] < opens[t]:
            p["body"] = "bear"
        else:
            p["body"] = "doji"

        price_panel[tk] = p

        # Volume panel
        vol_panel[tk] = {"bar": _to_row(volumes[t] / vol_max)}

        # RSI panel (fixed 0-100)
        rsi_panel[tk] = {"line": _to_row(rsis[t] / 100.0)}

        # MACD panel
        mp: dict = {}
        mp["line"] = _to_row((macd_lines[t] - m_lo) / m_range)
        mp["signal"] = _to_row((macd_sigs[t] - m_lo) / m_range)
        hist_norm = (macd_hists[t] - m_lo) / m_range
        if macd_hists[t] >= 0:
            mp["hist_up"] = _to_row(hist_norm)
        else:
            mp["hist_dn"] = _to_row(hist_norm)
        macd_panel[tk] = mp

    data["price"] = price_panel
    data["vol"] = vol_panel
    data["rsi"] = rsi_panel
    data["macd"] = macd_panel

    # --- Shape descriptors ---
    data["shape"] = compute_shapes(window)

    return data


# =========================================================================
# Pixel chart encoding — literal raster rendering with colors
# =========================================================================

PX_ROWS = 50  # rows per panel


def _px_row(val_01: float) -> int:
    """Map a 0-1 value to a pixel row index, or -1 if off-screen."""
    if val_01 < 0.0 or val_01 > 1.0:
        return -1
    return max(0, min(PX_ROWS - 1, int(val_01 * (PX_ROWS - 1) + 0.5)))


def _px_add(panel: dict, col_key: str, row: int, color: str):
    """Add a colored pixel to the canvas. Handles overlaps via sets."""
    if row < 0 or row >= PX_ROWS:
        return
    rk = f"r{row}"
    col = panel.setdefault(col_key, {})
    if rk in col:
        if isinstance(col[rk], set):
            col[rk].add(color)
        else:
            col[rk] = {col[rk], color}
    else:
        col[rk] = {color}


def build_pixel_data(candles: list, idx: int, window_size: int) -> dict:
    """Render a 4-panel trading chart as colored pixels.

    Each pixel is a set of color tokens. Empty pixels are not encoded.
    Viewport for price panel uses OHLC+SMAs only; BB bands can go off-screen.
    """
    start = max(0, idx - window_size + 1)
    window = candles[start:idx + 1]
    if len(window) < window_size:
        window = [window[0]] * (window_size - len(window)) + list(window)

    n = len(window)

    closes = [sf(c.get("close")) for c in window]
    opens = [sf(c.get("open")) for c in window]
    highs = [sf(c.get("high")) for c in window]
    lows = [sf(c.get("low")) for c in window]
    sma20s = [sf(c.get("sma20")) for c in window]
    sma50s = [sf(c.get("sma50")) for c in window]
    sma200s = [sf(c.get("sma200")) for c in window]
    bb_ups = [sf(c.get("bb_upper")) for c in window]
    bb_los = [sf(c.get("bb_lower")) for c in window]
    volumes = [sf(c.get("volume")) for c in window]
    rsis = [sf(c.get("rsi")) for c in window]
    macd_lines = [sf(c.get("macd_line")) for c in window]
    macd_sigs = [sf(c.get("macd_signal")) for c in window]
    macd_hists = [sf(c.get("macd_hist")) for c in window]

    # --- Price viewport: OHLC + SMAs only (BB can go off-screen) ---
    vp_vals = []
    for vs in (closes, opens, highs, lows, sma20s, sma50s, sma200s):
        vp_vals.extend(v for v in vs if v > 0)
    if not vp_vals:
        vp_vals = [1.0]
    vp_lo, vp_hi = min(vp_vals), max(vp_vals)
    vp_range = vp_hi - vp_lo
    margin = vp_range * 0.05
    vp_lo -= margin
    vp_hi += margin
    vp_range = vp_hi - vp_lo if (vp_hi - vp_lo) > 1e-10 else 1.0

    def pn(v):
        if v <= 0:
            return -1
        return (v - vp_lo) / vp_range

    # --- Volume viewport ---
    vol_max = max(volumes) if volumes else 1.0
    vol_max = vol_max if vol_max > 0 else 1.0

    # --- MACD viewport ---
    macd_all = macd_lines + macd_sigs + macd_hists
    m_lo = min(macd_all) if macd_all else 0.0
    m_hi = max(macd_all) if macd_all else 1.0
    m_range = m_hi - m_lo if (m_hi - m_lo) > 1e-10 else 1.0

    # --- Render panels ---
    price_px: dict = {}
    vol_px: dict = {}
    rsi_px: dict = {}
    macd_px: dict = {}

    for t in range(n):
        ck = f"c{t}"
        cl = closes[t]
        op = opens[t]
        hi = highs[t]
        lo = lows[t]

        is_bull = cl >= op
        body_color = "gs" if is_bull else "rs"
        wick_color = "gw" if is_bull else "rw"

        # Candle body: fill rows from open to close
        r_open = _px_row(pn(op))
        r_close = _px_row(pn(cl))
        if r_open >= 0 and r_close >= 0:
            r_lo_body = min(r_open, r_close)
            r_hi_body = max(r_open, r_close)
            if r_lo_body == r_hi_body:
                _px_add(price_px, ck, r_lo_body, "dj")
            else:
                for r in range(r_lo_body, r_hi_body + 1):
                    _px_add(price_px, ck, r, body_color)

            # Wicks
            r_high = _px_row(pn(hi))
            r_low = _px_row(pn(lo))
            if r_high >= 0:
                for r in range(r_hi_body + 1, r_high + 1):
                    _px_add(price_px, ck, r, wick_color)
            if r_low >= 0:
                for r in range(r_low, r_lo_body):
                    _px_add(price_px, ck, r, wick_color)

        # SMA20 / BB middle
        if sma20s[t] > 0:
            _px_add(price_px, ck, _px_row(pn(sma20s[t])), "yl")
        # SMA50
        if sma50s[t] > 0:
            _px_add(price_px, ck, _px_row(pn(sma50s[t])), "rl")
        # SMA200
        if sma200s[t] > 0:
            _px_add(price_px, ck, _px_row(pn(sma200s[t])), "gl")
        # BB upper/lower — can go off-screen
        if bb_ups[t] > 0:
            _px_add(price_px, ck, _px_row(pn(bb_ups[t])), "wu")
        if bb_los[t] > 0:
            _px_add(price_px, ck, _px_row(pn(bb_los[t])), "wl")

        # --- Volume panel ---
        vol_height = _px_row(volumes[t] / vol_max)
        vol_color = "vg" if is_bull else "vr"
        if vol_height >= 0:
            for r in range(0, vol_height + 1):
                _px_add(vol_px, ck, r, vol_color)

        # --- RSI panel ---
        rsi_val = rsis[t]
        if rsi_val > 0:
            r_rsi = _px_row(rsi_val / 100.0)
            _px_add(rsi_px, ck, r_rsi, "rb")
            if rsi_val > 70:
                _px_add(rsi_px, ck, r_rsi, "ro")
            elif rsi_val < 30:
                _px_add(rsi_px, ck, r_rsi, "rn")

        # --- MACD panel ---
        ml_norm = (macd_lines[t] - m_lo) / m_range
        ms_norm = (macd_sigs[t] - m_lo) / m_range
        mh_norm = (macd_hists[t] - m_lo) / m_range
        center = _px_row((-m_lo) / m_range) if m_range > 1e-10 else PX_ROWS // 2

        _px_add(macd_px, ck, _px_row(ml_norm), "ml")
        _px_add(macd_px, ck, _px_row(ms_norm), "ms")

        r_hist = _px_row(mh_norm)
        if r_hist >= 0 and center >= 0:
            hist_color = "mhg" if macd_hists[t] >= 0 else "mhr"
            lo_h, hi_h = min(center, r_hist), max(center, r_hist)
            for r in range(lo_h, hi_h + 1):
                _px_add(macd_px, ck, r, hist_color)

    return {
        "price": price_px,
        "vol": vol_px,
        "rsi": rsi_px,
        "macd": macd_px,
    }


# =========================================================================
# Parallel encoding
# =========================================================================

_g_candles = None
_g_window = None
_g_dim = None
_g_stripes = None
_g_encoder = None


def _worker_init():
    global _g_encoder
    _g_encoder = Encoder(DeterministicVectorManager(dimensions=_g_dim))


def _worker_encode(idx):
    data = build_categorical_data(_g_candles, idx, _g_window)
    stripe_list = _g_encoder.encode_walkable_striped(data, _g_stripes)
    return idx, np.stack(stripe_list)


# =========================================================================
# Classification and evaluation (same as algebra_refine.py)
# =========================================================================

def compute_actual(candles, queue_idx):
    entry_price = sf(candles[queue_idx].get("close"))
    if entry_price <= 0:
        return "QUIET"
    target_up = entry_price * (1 + MIN_MOVE_PCT / 100)
    target_down = entry_price * (1 - MIN_MOVE_PCT / 100)
    first_buy = first_sell = -1
    end = min(queue_idx + 1 + RESOLUTION_CANDLES, len(candles))
    for j in range(queue_idx + 1, end):
        close_j = sf(candles[j].get("close"))
        if first_buy < 0 and close_j >= target_up:
            first_buy = j
        if first_sell < 0 and close_j <= target_down:
            first_sell = j
        if first_buy >= 0 and first_sell >= 0:
            break
    if first_buy >= 0 and (first_sell < 0 or first_buy <= first_sell):
        return "BUY"
    elif first_sell >= 0:
        return "SELL"
    return "QUIET"


@dataclass
class StripeSignals:
    discriminants: List[np.ndarray]
    midpoints: List[np.ndarray]
    name: str


def build_strategies(
    buy_means: List[np.ndarray],
    sell_means: List[np.ndarray],
    n_stripes: int,
) -> Dict[str, StripeSignals]:
    strategies = {}

    discs, mids = [], []
    for s in range(n_stripes):
        d = buy_means[s] - sell_means[s]
        mid = (buy_means[s] + sell_means[s]) / 2.0
        discs.append(d)
        mids.append(mid)
    strategies["1_raw_disc"] = StripeSignals(discs, mids, "Raw mean discriminant")

    buy_uniques, sell_uniques = [], []
    discs2, mids2 = [], []
    for s in range(n_stripes):
        market = (buy_means[s] + sell_means[s]) / 2.0
        bu = reject(buy_means[s], [market])
        su = reject(sell_means[s], [market])
        d = bu - su
        mid = (bu + su) / 2.0
        buy_uniques.append(bu)
        sell_uniques.append(su)
        discs2.append(d)
        mids2.append(mid)
    strategies["2_reject"] = StripeSignals(discs2, mids2, "Reject shared structure")

    discs3, mids3 = [], []
    for s in range(n_stripes):
        disc = difference(buy_means[s], sell_means[s])
        buy_ref = amplify(buy_uniques[s], disc, strength=2.0)
        sell_ref = amplify(sell_uniques[s], disc, strength=2.0)
        d = buy_ref - sell_ref
        mid = (buy_ref + sell_ref) / 2.0
        discs3.append(d)
        mids3.append(mid)
    strategies["3_diff_amp"] = StripeSignals(discs3, mids3, "Difference + amplify")

    discs4, mids4 = [], []
    for s in range(n_stripes):
        buy_sig = grover_amplify(buy_uniques[s], sell_means[s], iterations=2)
        sell_sig = grover_amplify(sell_uniques[s], buy_means[s], iterations=2)
        d = buy_sig - sell_sig
        mid = (buy_sig + sell_sig) / 2.0
        discs4.append(d)
        mids4.append(mid)
    strategies["4_grover"] = StripeSignals(discs4, mids4, "Grover amplification")

    discs5, mids5 = [], []
    for s in range(n_stripes):
        disc = difference(buy_means[s], sell_means[s])
        buy_res = resonance(buy_uniques[s], disc)
        sell_res = resonance(sell_uniques[s], disc)
        d = buy_res - sell_res
        mid = (buy_res + sell_res) / 2.0
        discs5.append(d)
        mids5.append(mid)
    strategies["5_resonance"] = StripeSignals(discs5, mids5, "Resonance filtering")

    return strategies


def classify_one(stripe_vecs, signals):
    score = 0.0
    for s, (vec, disc, mid) in enumerate(
        zip(stripe_vecs, signals.discriminants, signals.midpoints)
    ):
        disc_norm = np.linalg.norm(disc)
        if disc_norm < 1e-12:
            continue
        centered = vec.astype(np.float64) - mid
        score += np.dot(centered, disc) / disc_norm
    return "BUY" if score > 0 else "SELL"


def evaluate(indices, vec_cache, labels, signals, n_stripes):
    correct = wrong = buy_correct = sell_correct = 0
    for idx in indices:
        actual = labels.get(idx)
        if actual not in ("BUY", "SELL"):
            continue
        arr = vec_cache[idx]
        svecs = [arr[s] for s in range(n_stripes)]
        pred = classify_one(svecs, signals)
        if pred == actual:
            correct += 1
            if actual == "BUY":
                buy_correct += 1
            else:
                sell_correct += 1
        else:
            wrong += 1
    return correct, wrong, buy_correct, sell_correct


def per_year_eval(indices, vec_cache, labels, candles, signals, n_stripes):
    by_year: Dict[int, List[int]] = {}
    for idx in indices:
        if labels.get(idx) not in ("BUY", "SELL"):
            continue
        year = candles[idx].get("year")
        by_year.setdefault(year, []).append(idx)

    results = {}
    for year in sorted(by_year.keys()):
        yidx = by_year[year]
        c, w, _, _ = evaluate(yidx, vec_cache, labels, signals, n_stripes)
        total = c + w
        acc = c / total * 100 if total > 0 else 0
        results[year] = (acc, total)
    return results


# =========================================================================
# Main
# =========================================================================

def main():
    global _g_candles, _g_window, _g_dim, _g_stripes

    parser = argparse.ArgumentParser(
        description="Categorical Algebra Refinement Classifier"
    )
    parser.add_argument("--n", type=int, default=5000,
                        help="Sample N supervised + N adaptive for quick test")
    parser.add_argument("--label", default="label_oracle_10")
    parser.add_argument("--vol-threshold", type=float, default=0.002)
    parser.add_argument("--window", type=int, default=48)
    parser.add_argument("--dims", type=int, default=1024)
    parser.add_argument("--stripes", type=int, default=16)
    parser.add_argument("--k", type=int, default=20)
    parser.add_argument("--workers", type=int, default=mp.cpu_count())
    parser.add_argument("--save-cache", type=str, default=None)
    parser.add_argument("--load-cache", type=str, default=None)
    args = parser.parse_args()

    log("=" * 80)
    log("CATEGORICAL ALGEBRA REFINEMENT")
    log("  Encoding: symbolic market facts (sets, enums)")
    log(f"  Stripes: {args.stripes} × {args.dims}D")
    log("=" * 80)

    # ------------------------------------------------------------------
    # Load data
    # ------------------------------------------------------------------
    conn = sqlite3.connect(str(DB_PATH))
    seen = set()
    cols = []
    for c in ALL_DB_COLS + [args.label]:
        if c not in seen:
            cols.append(c)
            seen.add(c)
    all_rows = conn.execute(
        f"SELECT {', '.join(cols)} FROM candles ORDER BY ts"
    ).fetchall()
    conn.close()
    candles = [{cols[j]: r[j] for j in range(len(cols))} for r in all_rows]
    log(f"Loaded {len(candles):,} candles")

    # ------------------------------------------------------------------
    # Identify tradeable indices
    # ------------------------------------------------------------------
    sup_all, adp_all = [], []
    for i in range(args.window - 1, len(candles)):
        atr_r = candles[i].get("atr_r") or 0
        if atr_r <= args.vol_threshold:
            continue
        year = candles[i].get("year")
        if year in SUPERVISED_YEARS:
            sup_all.append(i)
        else:
            adp_all.append(i)

    # ------------------------------------------------------------------
    # Sample or use all
    # ------------------------------------------------------------------
    np.random.seed(42)
    n = args.n
    sup_sample = sorted(np.random.choice(
        sup_all, size=min(n, len(sup_all)), replace=False
    ).tolist())
    adp_sample = sorted(np.random.choice(
        adp_all, size=min(n, len(adp_all)), replace=False
    ).tolist())
    all_to_encode = sup_sample + adp_sample
    log(f"Sample: {len(sup_sample):,} supervised + "
        f"{len(adp_sample):,} adaptive = {len(all_to_encode):,}")

    # ------------------------------------------------------------------
    # Show example encoding
    # ------------------------------------------------------------------
    example_idx = sup_sample[0]
    example_data = build_categorical_data(candles, example_idx, args.window)
    last_key = f"t{args.window - 1}"
    log(f"\n--- Example encoding (candle {example_idx}, {last_key}) ---")
    if last_key in example_data:
        for k, v in sorted(example_data[last_key].items()):
            log(f"  {k}: {v}")

    # Count average leaves per encoding
    test_data = build_categorical_data(candles, sup_sample[0], args.window)
    leaf_count = 0
    for t_key, facts in test_data.items():
        for k, v in facts.items():
            if isinstance(v, set):
                leaf_count += len(v)
            else:
                leaf_count += 1
    log(f"  Leaf count: ~{leaf_count} per window")
    log(f"  Per stripe: ~{leaf_count / args.stripes:.0f} "
        f"(capacity ratio {args.dims / (leaf_count / args.stripes):.0f}:1)")

    # ------------------------------------------------------------------
    # Encode
    # ------------------------------------------------------------------
    if args.load_cache:
        log(f"\nLoading cache: {args.load_cache}")
        cached = np.load(args.load_cache)
        vec_cache = {int(cached["indices"][i]): cached["vectors"][i]
                     for i in range(len(cached["indices"]))}
        n_stripes = cached["vectors"].shape[1]
        dim = cached["vectors"].shape[2]
        log(f"  {len(vec_cache):,} vectors loaded")
    else:
        dim = args.dims
        n_stripes = args.stripes
        _g_candles = candles
        _g_window = args.window
        _g_dim = dim
        _g_stripes = n_stripes

        log(f"\nEncoding ({args.workers} workers) ...")
        t_enc = time.time()
        with mp.Pool(args.workers, initializer=_worker_init) as pool:
            results = []
            done = 0
            for result in pool.imap_unordered(
                _worker_encode, all_to_encode, chunksize=50
            ):
                results.append(result)
                done += 1
                if done % 2000 == 0:
                    elapsed = time.time() - t_enc
                    rate = done / elapsed
                    remaining = len(all_to_encode) - done
                    log(f"  {done:,}/{len(all_to_encode):,} ({rate:.0f}/s) "
                        f"ETA {remaining / rate / 60:.1f}min")

        vec_cache = dict(results)
        enc_elapsed = time.time() - t_enc
        log(f"Encoded {len(vec_cache):,} vectors in {enc_elapsed:.1f}s "
            f"({len(vec_cache) / max(enc_elapsed, 0.01):.0f}/s)")

        if args.save_cache:
            indices_arr = np.array(sorted(vec_cache.keys()), dtype=np.int32)
            vectors_arr = np.stack([vec_cache[i] for i in indices_arr])
            np.savez(args.save_cache, indices=indices_arr, vectors=vectors_arr)
            log(f"Saved cache: {args.save_cache}")

    # ------------------------------------------------------------------
    # Build labels
    # ------------------------------------------------------------------
    supervised_indices = []
    adaptive_indices = []
    labels: Dict[int, str] = {}

    for idx in sorted(vec_cache.keys()):
        atr_r = candles[idx].get("atr_r") or 0
        if atr_r <= args.vol_threshold:
            continue
        year = candles[idx].get("year")
        if year in SUPERVISED_YEARS:
            oracle = candles[idx].get(args.label)
            if oracle in ("BUY", "SELL"):
                labels[idx] = oracle
            else:
                labels[idx] = compute_actual(candles, idx)
            supervised_indices.append(idx)
        else:
            labels[idx] = compute_actual(candles, idx)
            adaptive_indices.append(idx)

    sup_buy = sum(1 for i in supervised_indices if labels.get(i) == "BUY")
    sup_sell = sum(1 for i in supervised_indices if labels.get(i) == "SELL")
    sup_quiet = sum(1 for i in supervised_indices if labels.get(i) == "QUIET")
    log(f"\nSupervised: {len(supervised_indices):,} "
        f"(BUY={sup_buy}, SELL={sup_sell}, QUIET={sup_quiet})")

    adp_buy = sum(1 for i in adaptive_indices if labels.get(i) == "BUY")
    adp_sell = sum(1 for i in adaptive_indices if labels.get(i) == "SELL")
    adp_quiet = sum(1 for i in adaptive_indices if labels.get(i) == "QUIET")
    log(f"Adaptive:   {len(adaptive_indices):,} "
        f"(BUY={adp_buy}, SELL={adp_sell}, QUIET={adp_quiet})")

    # ------------------------------------------------------------------
    # Train subspaces
    # ------------------------------------------------------------------
    log(f"\n--- TRAINING SUBSPACES (K={args.k}) ---")
    t_train = time.time()

    buy_sub = StripedSubspace(dim=dim, k=args.k, n_stripes=n_stripes)
    sell_sub = StripedSubspace(dim=dim, k=args.k, n_stripes=n_stripes)

    buy_count = sell_count = 0
    for idx in supervised_indices:
        lbl = labels.get(idx)
        if lbl not in ("BUY", "SELL"):
            continue
        arr = vec_cache[idx]
        svecs = [arr[s] for s in range(n_stripes)]
        if lbl == "BUY":
            buy_sub.update(svecs)
            buy_count += 1
        else:
            sell_sub.update(svecs)
            sell_count += 1

    train_elapsed = time.time() - t_train
    log(f"  BUY:  {buy_count:,} trained")
    log(f"  SELL: {sell_count:,} trained")
    log(f"  {train_elapsed:.1f}s")

    buy_means = [buy_sub._stripes[s].mean.copy() for s in range(n_stripes)]
    sell_means = [sell_sub._stripes[s].mean.copy() for s in range(n_stripes)]

    mean_cos = np.mean([
        cosine_similarity(buy_means[s], sell_means[s])
        for s in range(n_stripes)
    ])
    log(f"  Mean cosine(buy, sell): {mean_cos:.4f}")

    # ------------------------------------------------------------------
    # Algebra strategies
    # ------------------------------------------------------------------
    log("\n--- ALGEBRA STRATEGIES ---")
    strategies = build_strategies(buy_means, sell_means, n_stripes)

    best_name = None
    best_oos_acc = -1.0

    for name, signals in sorted(strategies.items()):
        log(f"\n{'='*60}")
        log(f"Strategy: {signals.name} ({name})")
        log(f"{'='*60}")

        strengths = [float(np.linalg.norm(d)) for d in signals.discriminants]
        log(f"  Disc. strength: min={min(strengths):.2f}  "
            f"max={max(strengths):.2f}  mean={np.mean(strengths):.2f}")

        c, w, bc, sc = evaluate(
            supervised_indices, vec_cache, labels, signals, n_stripes
        )
        total = c + w
        acc = c / total * 100 if total > 0 else 0
        log(f"  IN-SAMPLE: {acc:.1f}% ({c}/{total})")
        log(f"    BUY correct: {bc}, SELL correct: {sc}")

        c2, w2, bc2, sc2 = evaluate(
            adaptive_indices, vec_cache, labels, signals, n_stripes
        )
        total2 = c2 + w2
        acc2 = c2 / total2 * 100 if total2 > 0 else 0
        log(f"  OOS:       {acc2:.1f}% ({c2}/{total2})")
        log(f"    BUY correct: {bc2}, SELL correct: {sc2}")

        all_idx = supervised_indices + adaptive_indices
        yearly = per_year_eval(
            all_idx, vec_cache, labels, candles, signals, n_stripes
        )
        log("  Per-year:")
        for year, (yacc, ytotal) in yearly.items():
            marker = " *" if year in SUPERVISED_YEARS else ""
            log(f"    {year}: {yacc:5.1f}% ({ytotal:,}){marker}")

        if acc2 > best_oos_acc:
            best_oos_acc = acc2
            best_name = name

    # ------------------------------------------------------------------
    # Summary
    # ------------------------------------------------------------------
    log(f"\n{'='*60}")
    log(f"BEST OOS: {best_name} — {strategies[best_name].name} "
        f"({best_oos_acc:.1f}%)")
    log(f"Mean cosine(buy, sell) was: {mean_cos:.4f}")
    if mean_cos < 0.99:
        log(f"  -> Categorical encoding REDUCED similarity from 0.9961!")
    log(f"{'='*60}")


if __name__ == "__main__":
    main()
