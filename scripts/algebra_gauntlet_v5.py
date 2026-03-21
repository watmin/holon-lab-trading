"""Algebra Gauntlet v5: The Monitor

Encode what a trader actually sees: a multi-panel monitor where all
price-level features share the SAME Y-axis (window-relative), and
each indicator panel has its own axis.

Panels:
  1. PRICE: open, high, low, close, sma20, sma50, sma200, bb_upper, bb_lower
     → All normalized to window's [min_low, max_high] range
     → Preserves: "price above SMA200", "touching BB upper", "SMA20 crossing SMA50"

  2. VOLUME: volume
     → Normalized to window's [min_vol, max_vol]

  3. RSI: rsi
     → Fixed 0-100, divided by 100

  4. MACD: macd_line, macd_signal, macd_hist
     → All share the same axis, normalized to window range

  5. DMI: dmi_plus, dmi_minus, adx
     → Fixed 0-100, divided by 100

  6. STOCHASTIC: stoch_k, stoch_d
     → Fixed 0-100, divided by 100

As the window slides, normalization adjusts — like auto-scaling charts.

Usage:
    ./scripts/run_with_venv.sh python holon-lab-trading/scripts/algebra_gauntlet_v5.py
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
    bundle_with_confidence,
    cosine_similarity,
    difference,
    grover_amplify,
    negate,
    prototype,
    similarity_profile,
)
from holon.kernel.walkable import LinearScale, WalkableSpread
from holon.memory import StripedSubspace

DB_PATH = Path(__file__).parent.parent / "data" / "analysis.db"

DIM = 1024
K = 32
N_STRIPES = 32
WINDOW = 12

# Features that live on each panel
PRICE_PANEL = ["open", "high", "low", "close", "sma20", "sma50", "sma200", "bb_upper", "bb_lower"]
VOLUME_PANEL = ["volume"]
RSI_PANEL = ["rsi"]
MACD_PANEL = ["macd_line", "macd_signal", "macd_hist"]
DMI_PANEL = ["dmi_plus", "dmi_minus", "adx"]
STOCH_PANEL = ["stoch_k", "stoch_d"]

ALL_PANELS = {
    "price": PRICE_PANEL,
    "volume": VOLUME_PANEL,
    "rsi": RSI_PANEL,
    "macd": MACD_PANEL,
    "dmi": DMI_PANEL,
    "stoch": STOCH_PANEL,
}

ALL_FEATURES = []
for panel_feats in ALL_PANELS.values():
    ALL_FEATURES.extend(panel_feats)


def log(msg: str):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def load_data(args):
    conn = sqlite3.connect(str(DB_PATH))
    cols = ["ts", "year"] + ALL_FEATURES + [args.label, "atr_r"]
    cols_str = ", ".join(cols)
    query = f"""
        SELECT {cols_str} FROM candles
        WHERE year BETWEEN 2019 AND 2020
        ORDER BY ts
    """
    all_rows = conn.execute(query).fetchall()
    conn.close()
    candles = [{cols[i]: r[i] for i in range(len(cols))} for r in all_rows]
    return candles


def safe_float(v):
    if v is None:
        return 0.0
    return float(v)


def normalize_window(candles, idx, window_size=WINDOW):
    """Build the 'monitor' for a window: normalize each panel to [0,1].

    Returns dict of {feature_name: [12 normalized values]}
    """
    start = max(0, idx - window_size + 1)
    window = candles[start:idx + 1]
    if len(window) < window_size:
        window = [window[0]] * (window_size - len(window)) + list(window)

    result = {}

    # PRICE PANEL: all share the same Y-axis
    # Find the viewport: min/max across ALL price-level features in the window
    all_price_vals = []
    for c in window:
        for feat in PRICE_PANEL:
            v = safe_float(c.get(feat))
            if v > 0:
                all_price_vals.append(v)

    if all_price_vals:
        p_lo = min(all_price_vals)
        p_hi = max(all_price_vals)
    else:
        p_lo, p_hi = 0.0, 1.0

    p_range = p_hi - p_lo if p_hi - p_lo > 1e-10 else 1.0

    for feat in PRICE_PANEL:
        vals = []
        for c in window:
            v = safe_float(c.get(feat))
            vals.append(max(0.0, min(1.0, (v - p_lo) / p_range)))
        result[feat] = vals

    # VOLUME PANEL: window's own min/max
    vol_vals = [safe_float(c.get("volume")) for c in window]
    v_lo = min(vol_vals) if vol_vals else 0.0
    v_hi = max(vol_vals) if vol_vals else 1.0
    v_range = v_hi - v_lo if v_hi - v_lo > 1e-10 else 1.0
    result["volume"] = [max(0.0, min(1.0, (v - v_lo) / v_range)) for v in vol_vals]

    # RSI PANEL: fixed 0-100
    result["rsi"] = [max(0.0, min(1.0, safe_float(c.get("rsi")) / 100.0)) for c in window]

    # MACD PANEL: all three share the same axis, normalized to window range
    macd_all = []
    for c in window:
        for feat in MACD_PANEL:
            macd_all.append(safe_float(c.get(feat)))
    m_lo = min(macd_all) if macd_all else 0.0
    m_hi = max(macd_all) if macd_all else 1.0
    m_range = m_hi - m_lo if m_hi - m_lo > 1e-10 else 1.0
    for feat in MACD_PANEL:
        result[feat] = [max(0.0, min(1.0, (safe_float(c.get(feat)) - m_lo) / m_range)) for c in window]

    # DMI PANEL: fixed 0-100
    for feat in DMI_PANEL:
        result[feat] = [max(0.0, min(1.0, safe_float(c.get(feat)) / 100.0)) for c in window]

    # STOCHASTIC PANEL: fixed 0-100
    for feat in STOCH_PANEL:
        result[feat] = [max(0.0, min(1.0, safe_float(c.get(feat)) / 100.0)) for c in window]

    return result


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


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--n", type=int, default=500)
    parser.add_argument("--label", default="label_oracle_10")
    parser.add_argument("--vol-threshold", type=float, default=0.002)
    args = parser.parse_args()

    log("=" * 75)
    log("ALGEBRA GAUNTLET v5: The Monitor (panel-normalized charts)")
    log("=" * 75)

    candles = load_data(args)
    log(f"Loaded {len(candles):,} candles")

    eligible = [i for i in range(WINDOW - 1, len(candles))
                if candles[i].get(args.label) in ("BUY", "SELL")
                and (candles[i].get("atr_r") or 0) > args.vol_threshold]

    buy_idx = [i for i in eligible if candles[i][args.label] == "BUY"]
    sell_idx = [i for i in eligible if candles[i][args.label] == "SELL"]
    log(f"Eligible: {len(buy_idx):,} BUY, {len(sell_idx):,} SELL")

    rng = np.random.default_rng(42)
    n_per = min(args.n, len(buy_idx), len(sell_idx))

    buy_sampled = list(rng.choice(buy_idx, n_per, replace=False))
    sell_sampled = list(rng.choice(sell_idx, n_per, replace=False))
    rng.shuffle(buy_sampled)
    rng.shuffle(sell_sampled)

    sb = int(n_per * 0.8)
    train_buy_idx = buy_sampled[:sb]
    test_buy_idx = buy_sampled[sb:]
    train_sell_idx = sell_sampled[:sb]
    test_sell_idx = sell_sampled[sb:]

    log(f"Train: {len(train_buy_idx)} BUY + {len(train_sell_idx)} SELL")
    log(f"Test:  {len(test_buy_idx)} BUY + {len(test_sell_idx)} SELL")

    # ===================================================================
    # PART A: Raw monitor image analysis
    # ===================================================================
    log("")
    log("=" * 75)
    log("PART A: Raw monitor 'image' analysis")
    log("=" * 75)

    def get_flat_monitor(idx):
        monitor = normalize_window(candles, idx)
        flat = []
        for feat in ALL_FEATURES:
            flat.extend(monitor[feat])
        return np.array(flat)

    t0 = time.time()
    train_buy_img = [get_flat_monitor(i) for i in train_buy_idx]
    train_sell_img = [get_flat_monitor(i) for i in train_sell_idx]
    test_buy_img = [get_flat_monitor(i) for i in test_buy_idx]
    test_sell_img = [get_flat_monitor(i) for i in test_sell_idx]
    log(f"Monitor images: {len(train_buy_img[0])} dims ({len(ALL_FEATURES)} feats × {WINDOW} steps), built in {time.time()-t0:.1f}s")

    buy_mean = np.mean(train_buy_img, axis=0)
    sell_mean = np.mean(train_sell_img, axis=0)
    img_diff = np.abs(buy_mean - sell_mean)
    log(f"Mean monitor distance: {np.linalg.norm(buy_mean - sell_mean):.4f}")
    log(f"Max per-pixel diff: {np.max(img_diff):.4f}, mean: {np.mean(img_diff):.4f}")

    # Show per-panel mean differences
    log("")
    log("Per-panel BUY vs SELL trajectory comparison:")
    for panel_name, panel_feats in ALL_PANELS.items():
        for feat in panel_feats:
            buy_traj = np.mean([normalize_window(candles, i)[feat] for i in train_buy_idx], axis=0)
            sell_traj = np.mean([normalize_window(candles, i)[feat] for i in train_sell_idx], axis=0)
            slope_buy = np.polyfit(np.arange(WINDOW), buy_traj, 1)[0]
            slope_sell = np.polyfit(np.arange(WINDOW), sell_traj, 1)[0]
            end_diff = buy_traj[-1] - sell_traj[-1]
            level_diff = np.mean(buy_traj) - np.mean(sell_traj)
            log(f"  [{panel_name:>6s}] {feat:<15s} "
                f"B_slope={slope_buy:+.4f} S_slope={slope_sell:+.4f} "
                f"Δslope={slope_buy-slope_sell:+.4f} Δlevel={level_diff:+.4f} Δend={end_diff:+.4f}")

    # Centroid classifiers
    evaluate("Monitor: Centroid (Euclidean)",
             test_buy_img, test_sell_img,
             lambda v: "BUY" if np.linalg.norm(v - buy_mean) < np.linalg.norm(v - sell_mean) else "SELL")

    evaluate("Monitor: Centroid (Cosine)",
             test_buy_img, test_sell_img,
             lambda v: "BUY" if cosine_similarity(v, buy_mean) > cosine_similarity(v, sell_mean) else "SELL")

    # k-NN
    for k in [5, 11, 21, 51]:
        def make_knn(kk):
            def classify(v):
                sims = [(cosine_similarity(v, tv), "BUY") for tv in train_buy_img]
                sims += [(cosine_similarity(v, tv), "SELL") for tv in train_sell_img]
                sims.sort(key=lambda x: -x[0])
                buy_votes = sum(1 for _, l in sims[:kk] if l == "BUY")
                return "BUY" if buy_votes > kk // 2 else "SELL"
            return classify
        evaluate(f"Monitor: k-NN (k={k})", test_buy_img, test_sell_img, make_knn(k))

    # ===================================================================
    # PART B: Holon striped encoding of the monitor
    # ===================================================================
    log("")
    log("=" * 75)
    log("PART B: Holon striped encoding of the monitor")
    log("=" * 75)

    client = HolonClient(dimensions=DIM)

    # Show which features map to which stripes
    stripe_map = {}
    for feat in ALL_FEATURES:
        s = client.encoder.field_stripe(feat, N_STRIPES)
        stripe_map.setdefault(s, []).append(feat)

    log("Feature → stripe mapping:")
    for s in sorted(stripe_map.keys()):
        log(f"  Stripe {s:>2d}: {', '.join(stripe_map[s])}")

    for scale in [0.01, 0.1, 1.0]:
        def encode_monitor_striped(idx, sc=scale):
            monitor = normalize_window(candles, idx)
            walkable = {}
            for feat in ALL_FEATURES:
                vals = [LinearScale(float(v), scale=sc) for v in monitor[feat]]
                walkable[feat] = WalkableSpread(vals)
            return client.encoder.encode_walkable_striped(walkable, n_stripes=N_STRIPES)

        t0 = time.time()
        train_buy_s = [encode_monitor_striped(i) for i in train_buy_idx]
        train_sell_s = [encode_monitor_striped(i) for i in train_sell_idx]
        test_buy_s = [encode_monitor_striped(i) for i in test_buy_idx]
        test_sell_s = [encode_monitor_striped(i) for i in test_sell_idx]
        enc_time = time.time() - t0

        # Per-stripe analysis
        stripe_sims = []
        s_bp = []
        s_sp = []
        s_mp = []
        for s in range(N_STRIPES):
            bvs = [v[s] for v in train_buy_s]
            svs = [v[s] for v in train_sell_s]
            bp = prototype(bvs)
            sp = prototype(svs)
            mp = prototype(bvs + svs)
            s_bp.append(bp)
            s_sp.append(sp)
            s_mp.append(mp)
            stripe_sims.append(cosine_similarity(bp, sp))

        log(f"  scale={scale} encoded in {enc_time:.1f}s")
        log(f"    stripe sim: mean={np.mean(stripe_sims):.4f} min={np.min(stripe_sims):.4f}")

        # Prototype
        def make_proto(bp_l, sp_l):
            def classify(stripes):
                b = sum(cosine_similarity(stripes[s], bp_l[s]) for s in range(N_STRIPES))
                s_val = sum(cosine_similarity(stripes[s], sp_l[s]) for s in range(N_STRIPES))
                return "BUY" if b > s_val else "SELL"
            return classify
        evaluate(f"  Monitor-HDC (scale={scale}): Prototype", test_buy_s, test_sell_s, make_proto(s_bp, s_sp))

        # Soft centroid
        s_bc = [np.mean([v[s].astype(float) for v in train_buy_s], axis=0) for s in range(N_STRIPES)]
        s_sc = [np.mean([v[s].astype(float) for v in train_sell_s], axis=0) for s in range(N_STRIPES)]

        def make_cent(bc_l, sc_l):
            def classify(stripes):
                b = sum(cosine_similarity(stripes[s].astype(float), bc_l[s]) for s in range(N_STRIPES))
                s_val = sum(cosine_similarity(stripes[s].astype(float), sc_l[s]) for s in range(N_STRIPES))
                return "BUY" if b > s_val else "SELL"
            return classify
        evaluate(f"  Monitor-HDC (scale={scale}): Soft centroid", test_buy_s, test_sell_s, make_cent(s_bc, s_sc))

        # Negate + Grover (best from v3)
        s_bp_c = [negate(s_bp[s], s_mp[s]) for s in range(N_STRIPES)]
        s_sp_c = [negate(s_sp[s], s_mp[s]) for s in range(N_STRIPES)]
        s_bp_g = [grover_amplify(s_bp_c[s], s_sp_c[s], iterations=2) for s in range(N_STRIPES)]
        s_sp_g = [grover_amplify(s_sp_c[s], s_bp_c[s], iterations=2) for s in range(N_STRIPES)]

        def make_ng(bp_g, sp_g, mp_l):
            def classify(stripes):
                b = s_val = 0
                for s in range(N_STRIPES):
                    cleaned = negate(stripes[s], mp_l[s])
                    b += cosine_similarity(cleaned, bp_g[s])
                    s_val += cosine_similarity(cleaned, sp_g[s])
                return "BUY" if b > s_val else "SELL"
            return classify
        evaluate(f"  Monitor-HDC (scale={scale}): Negate+Grover", test_buy_s, test_sell_s, make_ng(s_bp_g, s_sp_g, s_mp))

        # Subspace residual
        buy_sub = StripedSubspace(dim=DIM, k=K, n_stripes=N_STRIPES)
        for stripes in train_buy_s:
            buy_sub.update(stripes)
        sell_sub = StripedSubspace(dim=DIM, k=K, n_stripes=N_STRIPES)
        for stripes in train_sell_s:
            sell_sub.update(stripes)

        def make_sub(b_sub, s_sub):
            def classify(stripes):
                return "BUY" if b_sub.residual(stripes) < s_sub.residual(stripes) else "SELL"
            return classify
        evaluate(f"  Monitor-HDC (scale={scale}): Subspace", test_buy_s, test_sell_s, make_sub(buy_sub, sell_sub))

    # ===================================================================
    # PART C: Per-stripe discrimination — which PANEL is most useful?
    # ===================================================================
    log("")
    log("=" * 75)
    log("PART C: Per-stripe discrimination (which panel separates best?)")
    log("=" * 75)

    SCALE = 0.01

    def encode_final(idx):
        monitor = normalize_window(candles, idx)
        walkable = {}
        for feat in ALL_FEATURES:
            vals = [LinearScale(float(v), scale=SCALE) for v in monitor[feat]]
            walkable[feat] = WalkableSpread(vals)
        return client.encoder.encode_walkable_striped(walkable, n_stripes=N_STRIPES)

    train_buy_f = [encode_final(i) for i in train_buy_idx]
    train_sell_f = [encode_final(i) for i in train_sell_idx]
    test_buy_f = [encode_final(i) for i in test_buy_idx]
    test_sell_f = [encode_final(i) for i in test_sell_idx]

    # Per-stripe accuracy
    stripe_results = []
    for s in range(N_STRIPES):
        bvs = [v[s] for v in train_buy_f]
        svs = [v[s] for v in train_sell_f]

        bc = np.mean([v.astype(float) for v in bvs], axis=0)
        sc = np.mean([v.astype(float) for v in svs], axis=0)

        test_bvs = [v[s] for v in test_buy_f]
        test_svs = [v[s] for v in test_sell_f]

        correct = sum(1 for v in test_bvs if cosine_similarity(v.astype(float), bc) > cosine_similarity(v.astype(float), sc))
        correct += sum(1 for v in test_svs if cosine_similarity(v.astype(float), sc) > cosine_similarity(v.astype(float), bc))
        acc = correct / (len(test_bvs) + len(test_svs)) * 100

        sim = cosine_similarity(prototype(bvs), prototype(svs))
        feats = stripe_map.get(s, [])
        stripe_results.append((s, sim, acc, feats))

    stripe_results.sort(key=lambda x: -x[2])
    log(f"{'Stripe':>6s} {'ProtoSim':>8s} {'Acc':>6s} Features")
    log("-" * 75)
    for s, sim, acc, feats in stripe_results:
        marker = " <<<" if acc >= 55 else ""
        log(f"  {s:>4d}   {sim:>8.4f} {acc:>5.1f}% {', '.join(feats) if feats else '(empty)'}{marker}")

    # ===================================================================
    # PART D: Price panel only — the purest chart signal
    # ===================================================================
    log("")
    log("=" * 75)
    log("PART D: Price panel only (OHLC + MAs + BBands)")
    log("=" * 75)

    def get_price_monitor(idx):
        monitor = normalize_window(candles, idx)
        flat = []
        for feat in PRICE_PANEL:
            flat.extend(monitor[feat])
        return np.array(flat)

    train_buy_price = [get_price_monitor(i) for i in train_buy_idx]
    train_sell_price = [get_price_monitor(i) for i in train_sell_idx]
    test_buy_price = [get_price_monitor(i) for i in test_buy_idx]
    test_sell_price = [get_price_monitor(i) for i in test_sell_idx]

    buy_mean_p = np.mean(train_buy_price, axis=0)
    sell_mean_p = np.mean(train_sell_price, axis=0)
    log(f"Price-only dims: {len(buy_mean_p)} ({len(PRICE_PANEL)} × {WINDOW})")
    log(f"Price centroid distance: {np.linalg.norm(buy_mean_p - sell_mean_p):.4f}")

    # Show the mean BUY vs SELL price chart at key timesteps
    log("")
    log("Mean normalized charts (t=0 is 12 bars ago, t=11 is current):")
    log(f"  {'':>15s}  {'t=0':>6s} {'t=3':>6s} {'t=6':>6s} {'t=9':>6s} {'t=11':>6s}  |  {'t=0':>6s} {'t=3':>6s} {'t=6':>6s} {'t=9':>6s} {'t=11':>6s}")
    log(f"  {'':>15s}  {'--- BUY ---':^31s}  |  {'--- SELL ---':^31s}")
    for feat in PRICE_PANEL:
        buy_t = np.mean([normalize_window(candles, i)[feat] for i in train_buy_idx], axis=0)
        sell_t = np.mean([normalize_window(candles, i)[feat] for i in train_sell_idx], axis=0)
        log(f"  {feat:<15s}  {buy_t[0]:.3f} {buy_t[3]:.3f} {buy_t[6]:.3f} {buy_t[9]:.3f} {buy_t[11]:.3f}"
            f"  |  {sell_t[0]:.3f} {sell_t[3]:.3f} {sell_t[6]:.3f} {sell_t[9]:.3f} {sell_t[11]:.3f}")

    evaluate("Price-only: Centroid (Cosine)",
             test_buy_price, test_sell_price,
             lambda v: "BUY" if cosine_similarity(v, buy_mean_p) > cosine_similarity(v, sell_mean_p) else "SELL")

    for k in [5, 11, 21, 51]:
        def make_price_knn(kk):
            def classify(v):
                sims = [(cosine_similarity(v, tv), "BUY") for tv in train_buy_price]
                sims += [(cosine_similarity(v, tv), "SELL") for tv in train_sell_price]
                sims.sort(key=lambda x: -x[0])
                buy_votes = sum(1 for _, l in sims[:kk] if l == "BUY")
                return "BUY" if buy_votes > kk // 2 else "SELL"
            return classify
        evaluate(f"Price-only: k-NN (k={k})", test_buy_price, test_sell_price, make_price_knn(k))

    # ===================================================================
    # PART E: Different label thresholds
    # ===================================================================
    log("")
    log("=" * 75)
    log("PART E: Label threshold comparison (same monitor encoding)")
    log("=" * 75)

    for label_col in ["label_oracle_02", "label_oracle_05", "label_oracle_10", "label_oracle_20"]:
        conn = sqlite3.connect(str(DB_PATH))
        cols = ["ts", "year"] + ALL_FEATURES + [label_col, "atr_r"]
        cols_str = ", ".join(cols)
        query = f"""
            SELECT {cols_str} FROM candles
            WHERE year BETWEEN 2019 AND 2020
            ORDER BY ts
        """
        rows = conn.execute(query).fetchall()
        conn.close()
        label_candles = [{cols[i]: r[i] for i in range(len(cols))} for r in rows]

        elig = [i for i in range(WINDOW - 1, len(label_candles))
                if label_candles[i].get(label_col) in ("BUY", "SELL")
                and (label_candles[i].get("atr_r") or 0) > args.vol_threshold]

        b_idx = [i for i in elig if label_candles[i][label_col] == "BUY"]
        s_idx = [i for i in elig if label_candles[i][label_col] == "SELL"]

        if len(b_idx) < 100 or len(s_idx) < 100:
            log(f"  {label_col}: insufficient data (BUY={len(b_idx)}, SELL={len(s_idx)})")
            continue

        rng2 = np.random.default_rng(42)
        n = min(500, len(b_idx), len(s_idx))
        bs = list(rng2.choice(b_idx, n, replace=False))
        ss = list(rng2.choice(s_idx, n, replace=False))
        rng2.shuffle(bs)
        rng2.shuffle(ss)
        sp = int(n * 0.8)

        # Use the SAME normalization function but with this label set
        tr_b_imgs = [get_flat_monitor_from(label_candles, i) for i in bs[:sp]]
        tr_s_imgs = [get_flat_monitor_from(label_candles, i) for i in ss[:sp]]
        te_b_imgs = [get_flat_monitor_from(label_candles, i) for i in bs[sp:]]
        te_s_imgs = [get_flat_monitor_from(label_candles, i) for i in ss[sp:]]

        bm = np.mean(tr_b_imgs, axis=0)
        sm = np.mean(tr_s_imgs, axis=0)
        dist = np.linalg.norm(bm - sm)

        # Cosine centroid
        correct = sum(1 for v in te_b_imgs if cosine_similarity(v, bm) > cosine_similarity(v, sm))
        correct += sum(1 for v in te_s_imgs if cosine_similarity(v, sm) > cosine_similarity(v, bm))
        acc = correct / (len(te_b_imgs) + len(te_s_imgs)) * 100

        log(f"  {label_col:<20s} BUY={len(b_idx):>6d} SELL={len(s_idx):>6d} "
            f"dist={dist:.4f} cent_acc={acc:>5.1f}%")

    log("")
    log("=" * 75)
    log("DONE — The Monitor: panel-normalized chart patterns")
    log("=" * 75)


def get_flat_monitor_from(candles, idx):
    """Build flat monitor image from arbitrary candle list."""
    monitor = normalize_window(candles, idx)
    flat = []
    for feat in ALL_FEATURES:
        flat.extend(monitor[feat])
    return np.array(flat)


if __name__ == "__main__":
    main()
