"""Algebra Gauntlet v6: The Trader's 4-Panel Monitor

Exact panel layout a real trader uses:
  Panel 1: OHLCV + BB + SMA50 + SMA200
            - Y-axis viewport from OHLC + SMA50 + SMA200 (NOT BB bands)
            - BB bands can go "off-screen" → clamped to 0.0/1.0
            - Volume: own sub-axis (normalized within window)
  Panel 2: RSI (fixed 0-100)
  Panel 3: MACD (line, signal, hist — shared axis, window-normalized)
  Panel 4: DMI+ / DMI- / ADX (fixed 0-100)

BB clamping: when bands exceed the viewport (defined by OHLC + SMAs),
they are clamped to edge values. This prevents volatility explosions
from corrupting the chart scaling.

Usage:
    ./scripts/run_with_venv.sh python holon-lab-trading/scripts/algebra_gauntlet_v6.py
    ./scripts/run_with_venv.sh python holon-lab-trading/scripts/algebra_gauntlet_v6.py --n 2000
"""

from __future__ import annotations

import argparse
import sqlite3
import sys
import time
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent.parent))

from holon import (
    HolonClient,
    bind,
    bundle,
    cosine_similarity,
    difference,
    grover_amplify,
    negate,
    prototype,
)
from holon.kernel.walkable import LinearScale, WalkableSpread

DB_PATH = Path(__file__).parent.parent / "data" / "analysis.db"

DIM = 1024
N_STRIPES = 32
WINDOW = 12

# Panel 1: Price chart (OHLC + overlays)
PRICE_CORE = ["open", "high", "low", "close", "sma20", "sma50", "sma200"]
PRICE_BB = ["bb_upper", "bb_lower"]

# Panel 2: Volume
VOLUME = ["volume"]

# Panel 3: RSI
RSI = ["rsi"]

# Panel 4: MACD
MACD = ["macd_line", "macd_signal", "macd_hist"]

# Panel 5: DMI
DMI = ["dmi_plus", "dmi_minus", "adx"]

ALL_PANEL_FEATURES = PRICE_CORE + PRICE_BB + VOLUME + RSI + MACD + DMI


def log(msg: str):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def sf(v):
    return 0.0 if v is None else float(v)


def normalize_monitor(candles, idx, window_size=WINDOW):
    """Build the 4-panel monitor with viewport-driven price normalization.

    Returns dict of {feature_name: [window_size normalized values]}.
    """
    start = max(0, idx - window_size + 1)
    window = candles[start:idx + 1]
    if len(window) < window_size:
        window = [window[0]] * (window_size - len(window)) + list(window)

    result = {}

    # --- PANEL 1: Price chart ---
    # Viewport from OHLC + SMA20 + SMA50 + SMA200 (NOT BB bands)
    viewport_vals = []
    for c in window:
        for feat in PRICE_CORE:
            v = sf(c.get(feat))
            if v > 0:
                viewport_vals.append(v)

    if viewport_vals:
        vp_lo = min(viewport_vals)
        vp_hi = max(viewport_vals)
    else:
        vp_lo, vp_hi = 0.0, 1.0

    vp_range = vp_hi - vp_lo if vp_hi - vp_lo > 1e-10 else 1.0

    # Add a small margin (5% each side) so OHLC doesn't hug the edges
    margin = vp_range * 0.05
    vp_lo -= margin
    vp_hi += margin
    vp_range = vp_hi - vp_lo

    # OHLC + SMAs: normalize within viewport
    for feat in PRICE_CORE:
        vals = []
        for c in window:
            v = sf(c.get(feat))
            vals.append(max(0.0, min(1.0, (v - vp_lo) / vp_range)))
        result[feat] = vals

    # BB bands: CLAMP to viewport (go "off-screen")
    for feat in PRICE_BB:
        vals = []
        for c in window:
            v = sf(c.get(feat))
            vals.append(max(0.0, min(1.0, (v - vp_lo) / vp_range)))
        result[feat] = vals

    # --- PANEL 2: Volume (separate panel) ---
    vol_vals = [sf(c.get("volume")) for c in window]
    v_lo = min(vol_vals) if vol_vals else 0.0
    v_hi = max(vol_vals) if vol_vals else 1.0
    v_range = v_hi - v_lo if v_hi - v_lo > 1e-10 else 1.0
    result["volume"] = [max(0.0, min(1.0, (v - v_lo) / v_range)) for v in vol_vals]

    # --- PANEL 2: RSI (fixed 0-100) ---
    result["rsi"] = [max(0.0, min(1.0, sf(c.get("rsi")) / 100.0)) for c in window]

    # --- PANEL 3: MACD (shared axis, window-normalized) ---
    macd_all = []
    for c in window:
        for feat in MACD:
            macd_all.append(sf(c.get(feat)))
    m_lo = min(macd_all) if macd_all else 0.0
    m_hi = max(macd_all) if macd_all else 1.0
    m_range = m_hi - m_lo if m_hi - m_lo > 1e-10 else 1.0
    for feat in MACD:
        result[feat] = [max(0.0, min(1.0, (sf(c.get(feat)) - m_lo) / m_range)) for c in window]

    # --- PANEL 4: DMI (fixed 0-100) ---
    for feat in DMI:
        result[feat] = [max(0.0, min(1.0, sf(c.get(feat)) / 100.0)) for c in window]

    return result


def get_flat_monitor(candles, idx):
    monitor = normalize_monitor(candles, idx)
    flat = []
    for feat in ALL_PANEL_FEATURES:
        flat.extend(monitor[feat])
    return np.array(flat)


def evaluate(name, test_buy, test_sell, classify_fn):
    correct = buy_correct = sell_correct = 0
    for v in test_buy:
        if classify_fn(v) == "BUY":
            buy_correct += 1
            correct += 1
    for v in test_sell:
        if classify_fn(v) == "SELL":
            sell_correct += 1
            correct += 1
    total = len(test_buy) + len(test_sell)
    acc = correct / total * 100 if total else 0
    ba = buy_correct / len(test_buy) * 100 if test_buy else 0
    sa = sell_correct / len(test_sell) * 100 if test_sell else 0
    log(f"  {name:<55s} {acc:>5.1f}%  (B:{ba:.0f}% S:{sa:.0f}%)  N={total}")
    return acc


def knn_classify(v, train_buy, train_sell, k):
    sims = [(cosine_similarity(v, tv), "BUY") for tv in train_buy]
    sims += [(cosine_similarity(v, tv), "SELL") for tv in train_sell]
    sims.sort(key=lambda x: -x[0])
    buy_votes = sum(1 for _, l in sims[:k] if l == "BUY")
    return "BUY" if buy_votes > k // 2 else "SELL"


def thermometer_encode(value_01, dim, seed=42):
    rng = np.random.default_rng(seed)
    perm = rng.permutation(dim)
    n_hot = int(round(value_01 * dim))
    vec = np.full(dim, -1, dtype=np.int8)
    vec[perm[:n_hot]] = 1
    return vec


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--n", type=int, default=2000)
    parser.add_argument("--label", default="label_oracle_10")
    parser.add_argument("--vol-threshold", type=float, default=0.002)
    args = parser.parse_args()

    log("=" * 75)
    log("ALGEBRA GAUNTLET v6: 4-Panel Monitor (BB clamped, N=%d)" % args.n)
    log("=" * 75)

    # Load ALL data (2019-2024 for OOS testing)
    conn = sqlite3.connect(str(DB_PATH))
    cols = ["ts", "year"] + ALL_PANEL_FEATURES + [args.label, "atr_r"]
    cols_str = ", ".join(cols)
    query = f"SELECT {cols_str} FROM candles ORDER BY ts"
    all_rows = conn.execute(query).fetchall()
    conn.close()
    candles = [{cols[i]: r[i] for i in range(len(cols))} for r in all_rows]
    log(f"Loaded {len(candles):,} total candles")

    # In-sample: 2019-2020
    is_eligible = [i for i in range(WINDOW - 1, len(candles))
                   if candles[i].get("year") in (2019, 2020)
                   and candles[i].get(args.label) in ("BUY", "SELL")
                   and (candles[i].get("atr_r") or 0) > args.vol_threshold]

    buy_is = [i for i in is_eligible if candles[i][args.label] == "BUY"]
    sell_is = [i for i in is_eligible if candles[i][args.label] == "SELL"]
    log(f"In-sample (2019-2020): {len(buy_is):,} BUY, {len(sell_is):,} SELL")

    rng = np.random.default_rng(42)
    n_per = min(args.n, len(buy_is), len(sell_is))

    buy_sampled = list(rng.choice(buy_is, n_per, replace=False))
    sell_sampled = list(rng.choice(sell_is, n_per, replace=False))
    rng.shuffle(buy_sampled)
    rng.shuffle(sell_sampled)

    sp = int(n_per * 0.8)
    train_buy_idx = buy_sampled[:sp]
    test_buy_idx = buy_sampled[sp:]
    train_sell_idx = sell_sampled[:sp]
    test_sell_idx = sell_sampled[sp:]

    log(f"Train: {len(train_buy_idx)} BUY + {len(train_sell_idx)} SELL")
    log(f"IS Test: {len(test_buy_idx)} BUY + {len(test_sell_idx)} SELL")

    # Build monitor images
    t0 = time.time()
    train_buy_img = [get_flat_monitor(candles, i) for i in train_buy_idx]
    train_sell_img = [get_flat_monitor(candles, i) for i in train_sell_idx]
    test_buy_img = [get_flat_monitor(candles, i) for i in test_buy_idx]
    test_sell_img = [get_flat_monitor(candles, i) for i in test_sell_idx]
    log(f"Monitor images built in {time.time()-t0:.1f}s "
        f"({len(train_buy_img[0])} dims = {len(ALL_PANEL_FEATURES)} feats × {WINDOW} steps)")

    buy_mean = np.mean(train_buy_img, axis=0)
    sell_mean = np.mean(train_sell_img, axis=0)
    log(f"Centroid distance: {np.linalg.norm(buy_mean - sell_mean):.4f}")

    # ===================================================================
    # IN-SAMPLE TESTING
    # ===================================================================
    log("")
    log("=" * 75)
    log("IN-SAMPLE RESULTS (2019-2020, held-out 20%)")
    log("=" * 75)

    evaluate("Centroid (Cosine)",
             test_buy_img, test_sell_img,
             lambda v: "BUY" if cosine_similarity(v, buy_mean) > cosine_similarity(v, sell_mean) else "SELL")

    evaluate("Centroid (Euclidean)",
             test_buy_img, test_sell_img,
             lambda v: "BUY" if np.linalg.norm(v - buy_mean) < np.linalg.norm(v - sell_mean) else "SELL")

    for k in [5, 11, 21, 51, 101]:
        def make_knn(kk):
            def classify(v):
                return knn_classify(v, train_buy_img, train_sell_img, kk)
            return classify
        evaluate(f"k-NN (k={k})", test_buy_img, test_sell_img, make_knn(k))

    # ===================================================================
    # PER-PANEL TRAJECTORIES (diagnostic)
    # ===================================================================
    log("")
    log("=" * 75)
    log("PER-FEATURE TRAJECTORY ANALYSIS")
    log("=" * 75)

    panels = [
        ("PRICE", PRICE_CORE + PRICE_BB),
        ("  VOL", VOLUME),
        ("  RSI", RSI),
        (" MACD", MACD),
        ("  DMI", DMI),
    ]

    log(f"{'Panel':>6s} {'Feature':<15s} {'Bslope':>7s} {'Sslope':>7s} {'Δslope':>7s} "
        f"{'Blevel':>7s} {'Slevel':>7s} {'Δlevel':>7s}")
    log("-" * 85)

    for panel_name, panel_feats in panels:
        for feat in panel_feats:
            buy_trajs = [normalize_monitor(candles, i)[feat] for i in train_buy_idx[:200]]
            sell_trajs = [normalize_monitor(candles, i)[feat] for i in train_sell_idx[:200]]
            buy_mean_t = np.mean(buy_trajs, axis=0)
            sell_mean_t = np.mean(sell_trajs, axis=0)
            t = np.arange(WINDOW)
            bs = np.polyfit(t, buy_mean_t, 1)[0]
            ss_slope = np.polyfit(t, sell_mean_t, 1)[0]
            bl = np.mean(buy_mean_t)
            sl = np.mean(sell_mean_t)
            marker = " <<<" if abs(bs - ss_slope) > 0.002 or abs(bl - sl) > 0.02 else ""
            log(f"  {panel_name:>5s} {feat:<15s} {bs:>+7.4f} {ss_slope:>+7.4f} {bs-ss_slope:>+7.4f} "
                f"{bl:>7.3f} {sl:>7.3f} {bl-sl:>+7.3f}{marker}")

    # ===================================================================
    # BB CLAMPING DIAGNOSTIC
    # ===================================================================
    log("")
    log("=" * 75)
    log("BB CLAMPING DIAGNOSTIC")
    log("=" * 75)

    bb_clamped_count = 0
    total_bb_values = 0
    for idx in train_buy_idx[:200] + train_sell_idx[:200]:
        monitor = normalize_monitor(candles, idx)
        for feat in PRICE_BB:
            for v in monitor[feat]:
                total_bb_values += 1
                if v <= 0.0 or v >= 1.0:
                    bb_clamped_count += 1

    log(f"BB values clamped to 0.0/1.0: {bb_clamped_count}/{total_bb_values} "
        f"({bb_clamped_count/max(1,total_bb_values)*100:.1f}%)")

    # ===================================================================
    # OUT-OF-SAMPLE TESTING (2021-2024)
    # ===================================================================
    log("")
    log("=" * 75)
    log("OUT-OF-SAMPLE RESULTS (2021-2024)")
    log("=" * 75)

    for year in [2021, 2022, 2023, 2024]:
        oos_eligible = [i for i in range(WINDOW - 1, len(candles))
                        if candles[i].get("year") == year
                        and candles[i].get(args.label) in ("BUY", "SELL")
                        and (candles[i].get("atr_r") or 0) > args.vol_threshold]

        oos_buy = [i for i in oos_eligible if candles[i][args.label] == "BUY"]
        oos_sell = [i for i in oos_eligible if candles[i][args.label] == "SELL"]

        if len(oos_buy) < 50 or len(oos_sell) < 50:
            log(f"  {year}: insufficient data (BUY={len(oos_buy)}, SELL={len(oos_sell)})")
            continue

        n_oos = min(1000, len(oos_buy), len(oos_sell))
        rng_oos = np.random.default_rng(year)
        oos_buy_s = list(rng_oos.choice(oos_buy, n_oos, replace=False))
        oos_sell_s = list(rng_oos.choice(oos_sell, n_oos, replace=False))

        oos_buy_imgs = [get_flat_monitor(candles, i) for i in oos_buy_s]
        oos_sell_imgs = [get_flat_monitor(candles, i) for i in oos_sell_s]

        log(f"  {year}: {n_oos} BUY + {n_oos} SELL")

        # Centroid
        correct = sum(1 for v in oos_buy_imgs if cosine_similarity(v, buy_mean) > cosine_similarity(v, sell_mean))
        correct += sum(1 for v in oos_sell_imgs if cosine_similarity(v, sell_mean) > cosine_similarity(v, buy_mean))
        acc = correct / (len(oos_buy_imgs) + len(oos_sell_imgs)) * 100
        log(f"    Centroid (Cosine):  {acc:>5.1f}%")

        # k-NN (k=21 was best in-sample)
        for k in [21, 51]:
            correct_k = 0
            for v in oos_buy_imgs:
                if knn_classify(v, train_buy_img, train_sell_img, k) == "BUY":
                    correct_k += 1
            buy_acc = correct_k / len(oos_buy_imgs) * 100
            correct_k_total = correct_k
            for v in oos_sell_imgs:
                if knn_classify(v, train_buy_img, train_sell_img, k) == "SELL":
                    correct_k += 1
                    correct_k_total += 1
            sell_acc = (correct_k_total - sum(1 for v in oos_buy_imgs if knn_classify(v, train_buy_img, train_sell_img, k) == "BUY")) / len(oos_sell_imgs) * 100
            acc_k = correct_k_total / (len(oos_buy_imgs) + len(oos_sell_imgs)) * 100
            log(f"    k-NN (k={k}):       {acc_k:>5.1f}%  (B:{buy_acc:.0f}% S:{sell_acc:.0f}%)")

    # ===================================================================
    # THERMOMETER + MONITOR COMBO
    # ===================================================================
    log("")
    log("=" * 75)
    log("THERMOMETER ENCODING OF MONITOR (Holon)")
    log("=" * 75)

    client = HolonClient(dimensions=DIM)

    def encode_monitor_thermo(idx):
        monitor = normalize_monitor(candles, idx)
        vecs = []
        for fi, feat in enumerate(ALL_PANEL_FEATURES):
            role = client.encoder.vector_manager.get_vector(feat)
            for t_step in range(WINDOW):
                v01 = monitor[feat][t_step]
                pos = client.encoder.vector_manager.get_position_vector(t_step)
                filler = thermometer_encode(v01, DIM, seed=fi * 1000 + 42)
                vecs.append(bind(bind(role, pos), filler))
        return bundle(vecs)

    t0 = time.time()
    train_buy_thermo = [encode_monitor_thermo(i) for i in train_buy_idx]
    train_sell_thermo = [encode_monitor_thermo(i) for i in train_sell_idx]
    test_buy_thermo = [encode_monitor_thermo(i) for i in test_buy_idx]
    test_sell_thermo = [encode_monitor_thermo(i) for i in test_sell_idx]
    log(f"Encoded {len(train_buy_thermo)+len(train_sell_thermo)+len(test_buy_thermo)+len(test_sell_thermo)} "
        f"in {time.time()-t0:.1f}s")

    bp_t = prototype(train_buy_thermo)
    sp_t = prototype(train_sell_thermo)
    log(f"Proto sim: {cosine_similarity(bp_t, sp_t):.4f}")

    buy_cent_t = np.mean([v.astype(float) for v in train_buy_thermo], axis=0)
    sell_cent_t = np.mean([v.astype(float) for v in train_sell_thermo], axis=0)
    log(f"Centroid sim: {cosine_similarity(buy_cent_t, sell_cent_t):.4f}")

    evaluate("Thermo-Monitor: Prototype",
             test_buy_thermo, test_sell_thermo,
             lambda v: "BUY" if cosine_similarity(v, bp_t) > cosine_similarity(v, sp_t) else "SELL")

    evaluate("Thermo-Monitor: Soft centroid",
             test_buy_thermo, test_sell_thermo,
             lambda v: "BUY" if cosine_similarity(v, buy_cent_t) > cosine_similarity(v, sell_cent_t) else "SELL")

    # Negate + Grover
    mp_t = prototype(train_buy_thermo + train_sell_thermo)
    bp_c = negate(bp_t, mp_t)
    sp_c = negate(sp_t, mp_t)
    bp_g = grover_amplify(bp_c, sp_c, iterations=2)
    sp_g = grover_amplify(sp_c, bp_c, iterations=2)

    def cls_ng(v):
        cleaned = negate(v, mp_t)
        return "BUY" if cosine_similarity(cleaned, bp_g) > cosine_similarity(cleaned, sp_g) else "SELL"
    evaluate("Thermo-Monitor: Negate+Grover", test_buy_thermo, test_sell_thermo, cls_ng)

    # k-NN in HDC space
    for k in [21, 51]:
        def make_thermo_knn(kk):
            def classify(v):
                return knn_classify(v, train_buy_thermo, train_sell_thermo, kk)
            return classify
        evaluate(f"Thermo-Monitor: k-NN (k={k})", test_buy_thermo, test_sell_thermo, make_thermo_knn(k))

    log("")
    log("=" * 75)
    log("DONE")
    log("=" * 75)


if __name__ == "__main__":
    main()
