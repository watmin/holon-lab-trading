"""Window size sweep: how much chart history should the monitor show?

Tests window sizes from 12 (1 hour) to 288 (24 hours) at 5-min candles.
Uses the v6 4-panel monitor normalization with BB clamping.

Reports in-sample + out-of-sample accuracy for each window size.

Usage:
    ./scripts/run_with_venv.sh python holon-lab-trading/scripts/window_sweep.py
"""

from __future__ import annotations

import argparse
import sqlite3
import sys
import time
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent.parent))

from holon import cosine_similarity

DB_PATH = Path(__file__).parent.parent / "data" / "analysis.db"

PRICE_CORE = ["open", "high", "low", "close", "sma20", "sma50", "sma200"]
PRICE_BB = ["bb_upper", "bb_lower"]
VOLUME = ["volume"]
RSI = ["rsi"]
MACD = ["macd_line", "macd_signal", "macd_hist"]
DMI = ["dmi_plus", "dmi_minus", "adx"]

ALL_FEATURES = PRICE_CORE + PRICE_BB + VOLUME + RSI + MACD + DMI


def log(msg: str):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def sf(v):
    return 0.0 if v is None else float(v)


def normalize_monitor(candles, idx, window_size):
    start = max(0, idx - window_size + 1)
    window = candles[start:idx + 1]
    if len(window) < window_size:
        window = [window[0]] * (window_size - len(window)) + list(window)

    result = {}

    # Panel 1: Price — viewport from OHLC + SMAs (not BB)
    viewport_vals = []
    for c in window:
        for feat in PRICE_CORE:
            v = sf(c.get(feat))
            if v > 0:
                viewport_vals.append(v)

    vp_lo = min(viewport_vals) if viewport_vals else 0.0
    vp_hi = max(viewport_vals) if viewport_vals else 1.0
    vp_range = vp_hi - vp_lo if vp_hi - vp_lo > 1e-10 else 1.0
    margin = vp_range * 0.05
    vp_lo -= margin
    vp_hi += margin
    vp_range = vp_hi - vp_lo

    for feat in PRICE_CORE + PRICE_BB:
        result[feat] = [max(0.0, min(1.0, (sf(c.get(feat)) - vp_lo) / vp_range)) for c in window]

    # Panel 2: Volume
    vol_vals = [sf(c.get("volume")) for c in window]
    v_lo, v_hi = min(vol_vals), max(vol_vals)
    v_range = v_hi - v_lo if v_hi - v_lo > 1e-10 else 1.0
    result["volume"] = [max(0.0, min(1.0, (v - v_lo) / v_range)) for v in vol_vals]

    # Panel 3: RSI (fixed 0-100)
    result["rsi"] = [max(0.0, min(1.0, sf(c.get("rsi")) / 100.0)) for c in window]

    # Panel 4: MACD (shared axis, window-normalized)
    macd_all = [sf(c.get(f)) for c in window for f in MACD]
    m_lo, m_hi = min(macd_all), max(macd_all)
    m_range = m_hi - m_lo if m_hi - m_lo > 1e-10 else 1.0
    for feat in MACD:
        result[feat] = [max(0.0, min(1.0, (sf(c.get(feat)) - m_lo) / m_range)) for c in window]

    # Panel 5: DMI (fixed 0-100)
    for feat in DMI:
        result[feat] = [max(0.0, min(1.0, sf(c.get(feat)) / 100.0)) for c in window]

    return result


def get_flat(candles, idx, window_size):
    monitor = normalize_monitor(candles, idx, window_size)
    flat = []
    for feat in ALL_FEATURES:
        flat.extend(monitor[feat])
    return np.array(flat)


def knn_classify(v, train_buy, train_sell, k):
    sims = [(cosine_similarity(v, tv), "BUY") for tv in train_buy]
    sims += [(cosine_similarity(v, tv), "SELL") for tv in train_sell]
    sims.sort(key=lambda x: -x[0])
    buy_votes = sum(1 for _, l in sims[:k] if l == "BUY")
    return "BUY" if buy_votes > k // 2 else "SELL"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--n", type=int, default=1000)
    parser.add_argument("--label", default="label_oracle_10")
    parser.add_argument("--vol-threshold", type=float, default=0.002)
    args = parser.parse_args()

    log("=" * 80)
    log("WINDOW SIZE SWEEP")
    log("=" * 80)

    conn = sqlite3.connect(str(DB_PATH))
    cols = ["ts", "year"] + ALL_FEATURES + [args.label, "atr_r"]
    query = f"SELECT {', '.join(cols)} FROM candles ORDER BY ts"
    all_rows = conn.execute(query).fetchall()
    conn.close()
    candles = [{cols[i]: r[i] for i in range(len(cols))} for r in all_rows]
    log(f"Loaded {len(candles):,} candles")

    WINDOWS = [12, 24, 48, 72, 96, 144, 288]
    max_window = max(WINDOWS)

    # Find eligible indices (use max window to ensure all window sizes work)
    is_elig = [i for i in range(max_window - 1, len(candles))
               if candles[i].get("year") in (2019, 2020)
               and candles[i].get(args.label) in ("BUY", "SELL")
               and (candles[i].get("atr_r") or 0) > args.vol_threshold]

    buy_is = [i for i in is_elig if candles[i][args.label] == "BUY"]
    sell_is = [i for i in is_elig if candles[i][args.label] == "SELL"]
    log(f"In-sample eligible: {len(buy_is):,} BUY, {len(sell_is):,} SELL")

    rng = np.random.default_rng(42)
    n_per = min(args.n, len(buy_is), len(sell_is))
    buy_s = list(rng.choice(buy_is, n_per, replace=False))
    sell_s = list(rng.choice(sell_is, n_per, replace=False))
    rng.shuffle(buy_s)
    rng.shuffle(sell_s)

    sp = int(n_per * 0.8)
    tr_b, te_b = buy_s[:sp], buy_s[sp:]
    tr_s, te_s = sell_s[:sp], sell_s[sp:]
    log(f"Train: {len(tr_b)} + {len(tr_s)} = {len(tr_b)+len(tr_s)}")
    log(f"Test:  {len(te_b)} + {len(te_s)} = {len(te_b)+len(te_s)}")

    # OOS indices
    oos_2021 = [i for i in range(max_window - 1, len(candles))
                if candles[i].get("year") == 2021
                and candles[i].get(args.label) in ("BUY", "SELL")
                and (candles[i].get("atr_r") or 0) > args.vol_threshold]
    oos_buy_21 = [i for i in oos_2021 if candles[i][args.label] == "BUY"]
    oos_sell_21 = [i for i in oos_2021 if candles[i][args.label] == "SELL"]

    oos_2023 = [i for i in range(max_window - 1, len(candles))
                if candles[i].get("year") == 2023
                and candles[i].get(args.label) in ("BUY", "SELL")
                and (candles[i].get("atr_r") or 0) > args.vol_threshold]
    oos_buy_23 = [i for i in oos_2023 if candles[i][args.label] == "BUY"]
    oos_sell_23 = [i for i in oos_2023 if candles[i][args.label] == "SELL"]

    n_oos = 500
    rng21 = np.random.default_rng(2021)
    rng23 = np.random.default_rng(2023)
    oos_b21 = list(rng21.choice(oos_buy_21, min(n_oos, len(oos_buy_21)), replace=False))
    oos_s21 = list(rng21.choice(oos_sell_21, min(n_oos, len(oos_sell_21)), replace=False))
    oos_b23 = list(rng23.choice(oos_buy_23, min(n_oos, len(oos_buy_23)), replace=False))
    oos_s23 = list(rng23.choice(oos_sell_23, min(n_oos, len(oos_sell_23)), replace=False))

    log("")
    log(f"{'Window':>6s} {'Time':>6s} {'Dims':>5s} | "
        f"{'Cent-IS':>8s} {'kNN21-IS':>9s} {'kNN51-IS':>9s} | "
        f"{'Cent-21':>8s} {'kNN51-21':>9s} | "
        f"{'Cent-23':>8s} {'kNN51-23':>9s}")
    log("-" * 105)

    for W in WINDOWS:
        t0 = time.time()
        hours = W * 5 / 60

        # Encode in-sample
        tr_b_img = [get_flat(candles, i, W) for i in tr_b]
        tr_s_img = [get_flat(candles, i, W) for i in tr_s]
        te_b_img = [get_flat(candles, i, W) for i in te_b]
        te_s_img = [get_flat(candles, i, W) for i in te_s]

        dims = len(tr_b_img[0])
        buy_mean = np.mean(tr_b_img, axis=0)
        sell_mean = np.mean(tr_s_img, axis=0)

        # IS Centroid
        c_is = sum(1 for v in te_b_img if cosine_similarity(v, buy_mean) > cosine_similarity(v, sell_mean))
        c_is += sum(1 for v in te_s_img if cosine_similarity(v, sell_mean) > cosine_similarity(v, buy_mean))
        acc_cent_is = c_is / (len(te_b_img) + len(te_s_img)) * 100

        # IS k-NN (k=21)
        c_k21 = sum(1 for v in te_b_img if knn_classify(v, tr_b_img, tr_s_img, 21) == "BUY")
        c_k21 += sum(1 for v in te_s_img if knn_classify(v, tr_b_img, tr_s_img, 21) == "SELL")
        acc_k21_is = c_k21 / (len(te_b_img) + len(te_s_img)) * 100

        # IS k-NN (k=51)
        c_k51 = sum(1 for v in te_b_img if knn_classify(v, tr_b_img, tr_s_img, 51) == "BUY")
        c_k51 += sum(1 for v in te_s_img if knn_classify(v, tr_b_img, tr_s_img, 51) == "SELL")
        acc_k51_is = c_k51 / (len(te_b_img) + len(te_s_img)) * 100

        # OOS 2021
        oos_b21_img = [get_flat(candles, i, W) for i in oos_b21]
        oos_s21_img = [get_flat(candles, i, W) for i in oos_s21]

        c_cent_21 = sum(1 for v in oos_b21_img if cosine_similarity(v, buy_mean) > cosine_similarity(v, sell_mean))
        c_cent_21 += sum(1 for v in oos_s21_img if cosine_similarity(v, sell_mean) > cosine_similarity(v, buy_mean))
        acc_cent_21 = c_cent_21 / (len(oos_b21_img) + len(oos_s21_img)) * 100

        c_k51_21 = sum(1 for v in oos_b21_img if knn_classify(v, tr_b_img, tr_s_img, 51) == "BUY")
        c_k51_21 += sum(1 for v in oos_s21_img if knn_classify(v, tr_b_img, tr_s_img, 51) == "SELL")
        acc_k51_21 = c_k51_21 / (len(oos_b21_img) + len(oos_s21_img)) * 100

        # OOS 2023
        oos_b23_img = [get_flat(candles, i, W) for i in oos_b23]
        oos_s23_img = [get_flat(candles, i, W) for i in oos_s23]

        c_cent_23 = sum(1 for v in oos_b23_img if cosine_similarity(v, buy_mean) > cosine_similarity(v, sell_mean))
        c_cent_23 += sum(1 for v in oos_s23_img if cosine_similarity(v, sell_mean) > cosine_similarity(v, buy_mean))
        acc_cent_23 = c_cent_23 / (len(oos_b23_img) + len(oos_s23_img)) * 100

        c_k51_23 = sum(1 for v in oos_b23_img if knn_classify(v, tr_b_img, tr_s_img, 51) == "BUY")
        c_k51_23 += sum(1 for v in oos_s23_img if knn_classify(v, tr_b_img, tr_s_img, 51) == "SELL")
        acc_k51_23 = c_k51_23 / (len(oos_b23_img) + len(oos_s23_img)) * 100

        elapsed = time.time() - t0

        log(f"  {W:>4d}  {hours:>4.1f}h {dims:>5d} | "
            f"{acc_cent_is:>7.1f}% {acc_k21_is:>8.1f}% {acc_k51_is:>8.1f}% | "
            f"{acc_cent_21:>7.1f}% {acc_k51_21:>8.1f}% | "
            f"{acc_cent_23:>7.1f}% {acc_k51_23:>8.1f}%  ({elapsed:.0f}s)")

    log("")
    log("=" * 80)
    log("DONE — look for window where OOS improves")
    log("=" * 80)


if __name__ == "__main__":
    main()
