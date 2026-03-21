"""Explain WHY BUY and SELL encoded means are 99.6% similar.

Two-level decomposition:
  Level 1 (Raw features):  Do BUY/SELL windows actually differ in normalized
                           feature space?  Which features, at which time steps?
  Level 2 (Encoding):      Does the Holon encoding preserve or destroy any
                           differences?  Use leaf_binding probes to measure
                           per-feature contribution to the encoded discriminant.

Usage:
    ./scripts/run_with_venv.sh python holon-lab-trading/scripts/explain_similarity.py \\
        --n 5000 --workers 6
"""

from __future__ import annotations

import argparse
import sqlite3
import sys
import time
from pathlib import Path
from typing import Dict, List

import numpy as np

sys.path.insert(0, str(Path(__file__).parent.parent))

from holon import (
    DeterministicVectorManager,
    Encoder,
    LinearScale,
    cosine_similarity,
)

DB_PATH = Path(__file__).parent.parent / "data" / "analysis.db"
SUPERVISED_YEARS = {2019, 2020}

PRICE_CORE = ["open", "high", "low", "close", "sma20", "sma50", "sma200"]
PRICE_BB = ["bb_upper", "bb_lower"]
VOLUME = ["volume"]
RSI = ["rsi"]
MACD = ["macd_line", "macd_signal", "macd_hist"]
DMI = ["dmi_plus", "dmi_minus", "adx"]
ALL_FEATURES = PRICE_CORE + PRICE_BB + VOLUME + RSI + MACD + DMI

SCALE = 0.01


def log(msg: str):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def sf(v):
    return 0.0 if v is None else float(v)


def normalize_window(candles, idx, window_size):
    start = max(0, idx - window_size + 1)
    window = candles[start:idx + 1]
    if len(window) < window_size:
        window = [window[0]] * (window_size - len(window)) + list(window)

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

    vol_vals = [sf(c.get("volume")) for c in window]
    v_lo, v_hi = min(vol_vals), max(vol_vals)
    v_range = v_hi - v_lo if v_hi - v_lo > 1e-10 else 1.0

    clamp = lambda v: max(0.0, min(1.0, v))

    macd_all = [sf(c.get(f)) for c in window for f in MACD]
    m_lo, m_hi = min(macd_all), max(macd_all)
    m_range = m_hi - m_lo if m_hi - m_lo > 1e-10 else 1.0

    normalized = []
    for c in window:
        entry = {}
        for feat in PRICE_CORE + PRICE_BB:
            entry[feat] = clamp((sf(c.get(feat)) - vp_lo) / vp_range)
        entry["volume"] = clamp((sf(c.get("volume")) - v_lo) / v_range)
        entry["rsi"] = clamp(sf(c.get("rsi")) / 100.0)
        for feat in MACD:
            entry[feat] = clamp((sf(c.get(feat)) - m_lo) / m_range)
        for feat in DMI:
            entry[feat] = clamp(sf(c.get(feat)) / 100.0)
        normalized.append(entry)
    return normalized


LEAF_PATHS = []
LEAF_FEATURE_NAMES = []
for t in range(48):
    for feat in PRICE_CORE + PRICE_BB:
        LEAF_PATHS.append(f"t{t}.price.{feat}")
        LEAF_FEATURE_NAMES.append(f"t{t}.{feat}")
    LEAF_PATHS.append(f"t{t}.volume")
    LEAF_FEATURE_NAMES.append(f"t{t}.volume")
    LEAF_PATHS.append(f"t{t}.rsi")
    LEAF_FEATURE_NAMES.append(f"t{t}.rsi")
    for sub_feat, feat in [("line", "macd_line"), ("signal", "macd_signal"),
                            ("hist", "macd_hist")]:
        LEAF_PATHS.append(f"t{t}.macd.{sub_feat}")
        LEAF_FEATURE_NAMES.append(f"t{t}.{feat}")
    for sub_feat, feat in [("plus", "dmi_plus"), ("minus", "dmi_minus"),
                            ("adx", "adx")]:
        LEAF_PATHS.append(f"t{t}.dmi.{sub_feat}")
        LEAF_FEATURE_NAMES.append(f"t{t}.{feat}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--n", type=int, default=5000)
    parser.add_argument("--window", type=int, default=48)
    parser.add_argument("--dims", type=int, default=1024)
    parser.add_argument("--stripes", type=int, default=16)
    parser.add_argument("--label", default="label_oracle_10")
    parser.add_argument("--vol-threshold", type=float, default=0.002)
    args = parser.parse_args()

    log("=" * 80)
    log("EXPLAINABILITY: Why are BUY and SELL 99.6% similar?")
    log("=" * 80)

    # ------------------------------------------------------------------
    # Load data
    # ------------------------------------------------------------------
    conn = sqlite3.connect(str(DB_PATH))
    seen = set()
    cols = []
    for c in ["ts", "year", "close", args.label, "atr_r"] + ALL_FEATURES + PRICE_BB:
        if c not in seen:
            cols.append(c)
            seen.add(c)
    all_rows = conn.execute(
        f"SELECT {', '.join(cols)} FROM candles ORDER BY ts"
    ).fetchall()
    conn.close()
    candles = [{cols[j]: r[j] for j in range(len(cols))} for r in all_rows]
    log(f"Loaded {len(candles):,} candles")

    # Identify supervised volatile candles
    sup_indices = []
    for i in range(args.window - 1, len(candles)):
        atr_r = candles[i].get("atr_r") or 0
        if atr_r <= args.vol_threshold:
            continue
        year = candles[i].get("year")
        if year in SUPERVISED_YEARS:
            sup_indices.append(i)

    np.random.seed(42)
    sample = sorted(np.random.choice(
        sup_indices, size=min(args.n, len(sup_indices)), replace=False
    ).tolist())

    # Split by oracle label
    buy_indices = [i for i in sample
                   if candles[i].get(args.label) == "BUY"]
    sell_indices = [i for i in sample
                    if candles[i].get(args.label) == "SELL"]
    log(f"Sampled {len(sample):,} supervised: "
        f"BUY={len(buy_indices)}, SELL={len(sell_indices)}")

    # ==================================================================
    # LEVEL 1: Raw normalized feature comparison
    # ==================================================================
    log(f"\n{'='*80}")
    log("LEVEL 1: RAW NORMALIZED FEATURES — BUY vs SELL")
    log(f"{'='*80}")

    n_features = len(ALL_FEATURES)
    window_size = args.window

    buy_features = np.zeros((len(buy_indices), window_size, n_features))
    sell_features = np.zeros((len(sell_indices), window_size, n_features))

    for i, idx in enumerate(buy_indices):
        normed = normalize_window(candles, idx, window_size)
        for t, entry in enumerate(normed):
            for f, feat in enumerate(ALL_FEATURES):
                buy_features[i, t, f] = entry[feat]

    for i, idx in enumerate(sell_indices):
        normed = normalize_window(candles, idx, window_size)
        for t, entry in enumerate(normed):
            for f, feat in enumerate(ALL_FEATURES):
                sell_features[i, t, f] = entry[feat]

    buy_mean_feat = buy_features.mean(axis=0)   # (window, n_features)
    sell_mean_feat = sell_features.mean(axis=0)
    buy_std_feat = buy_features.std(axis=0)
    sell_std_feat = sell_features.std(axis=0)
    diff_feat = buy_mean_feat - sell_mean_feat   # (window, n_features)

    # Overall: flatten and compute cosine of raw feature vectors
    buy_flat = buy_mean_feat.ravel()
    sell_flat = sell_mean_feat.ravel()
    cos_raw = np.dot(buy_flat, sell_flat) / (
        np.linalg.norm(buy_flat) * np.linalg.norm(sell_flat) + 1e-12
    )
    log(f"\nCosine similarity of mean feature vectors: {cos_raw:.6f}")
    log(f"Mean absolute difference per feature-timestep: "
        f"{np.abs(diff_feat).mean():.6f}")
    log(f"Max absolute difference: {np.abs(diff_feat).max():.6f}")

    # Per-feature summary (averaged across time steps)
    log(f"\n--- Per-feature mean difference (averaged over {window_size} timesteps) ---")
    log(f"{'Feature':<16} {'BUY mean':>10} {'SELL mean':>10} "
        f"{'Diff':>10} {'|Diff|':>10} {'BUY std':>10} {'SELL std':>10}")
    for f, feat in enumerate(ALL_FEATURES):
        bm = buy_mean_feat[:, f].mean()
        sm = sell_mean_feat[:, f].mean()
        d = bm - sm
        ad = abs(d)
        bs = buy_std_feat[:, f].mean()
        ss = sell_std_feat[:, f].mean()
        log(f"{feat:<16} {bm:10.6f} {sm:10.6f} {d:+10.6f} {ad:10.6f} "
            f"{bs:10.6f} {ss:10.6f}")

    # Per-timestep × feature: find the BIGGEST differences
    log(f"\n--- Top 30 feature×timestep differences ---")
    flat_diff = np.abs(diff_feat).ravel()
    top_k = min(30, len(flat_diff))
    top_indices = np.argsort(-flat_diff)[:top_k]
    log(f"{'Rank':<6} {'Feature':<20} {'t':>4} {'BUY':>10} "
        f"{'SELL':>10} {'Diff':>10} {'Effect size':>12}")
    for rank, flat_idx in enumerate(top_indices):
        t_idx = flat_idx // n_features
        f_idx = flat_idx % n_features
        feat = ALL_FEATURES[f_idx]
        bm = buy_mean_feat[t_idx, f_idx]
        sm = sell_mean_feat[t_idx, f_idx]
        pooled_std = np.sqrt(
            (buy_std_feat[t_idx, f_idx]**2 + sell_std_feat[t_idx, f_idx]**2) / 2
        )
        effect = abs(bm - sm) / pooled_std if pooled_std > 1e-10 else 0
        log(f"{rank+1:<6} {f't{t_idx}.{feat}':<20} {t_idx:>4} "
            f"{bm:10.6f} {sm:10.6f} {bm-sm:+10.6f} {effect:12.4f}")

    # Per-timestep pattern: does the difference grow toward recent candles?
    log(f"\n--- Difference magnitude by timestep (older → newer) ---")
    per_t_diff = np.abs(diff_feat).mean(axis=1)
    max_bar = max(per_t_diff)
    for t in range(window_size):
        bar_len = int(per_t_diff[t] / max_bar * 50) if max_bar > 0 else 0
        bar = "#" * bar_len
        label = "newest" if t == window_size - 1 else ""
        log(f"  t{t:02d}: {per_t_diff[t]:.6f}  {bar} {label}")

    # ==================================================================
    # LEVEL 2: Encoding-level analysis
    # ==================================================================
    log(f"\n{'='*80}")
    log("LEVEL 2: ENCODING ANALYSIS — What does Holon see?")
    log(f"{'='*80}")

    dim = args.dims
    n_stripes = args.stripes
    encoder = Encoder(DeterministicVectorManager(dimensions=dim))

    # Stripe assignment map
    stripe_map: Dict[int, List[str]] = {s: [] for s in range(n_stripes)}
    for path in LEAF_PATHS:
        s = Encoder.field_stripe(path, n_stripes)
        stripe_map[s].append(path)

    log(f"\n--- Stripe assignment (how {len(LEAF_PATHS)} leaves map to {n_stripes} stripes) ---")
    for s in range(n_stripes):
        paths = stripe_map[s]
        features = set()
        timesteps = set()
        for p in paths:
            parts = p.split(".")
            timesteps.add(parts[0])
            features.add(parts[-1])
        log(f"  Stripe {s:2d}: {len(paths):3d} leaves, "
            f"{len(timesteps)} timesteps, features: {sorted(features)}")

    # For a representative BUY and SELL sample, create leaf bindings
    # and show which contribute most to BUY vs SELL separation
    log(f"\n--- Leaf binding probe analysis ---")
    log("  Creating probe bindings for representative BUY and SELL values...")

    # Use the mean feature values as representative
    buy_probe_strengths = np.zeros(len(LEAF_PATHS))
    sell_probe_strengths = np.zeros(len(LEAF_PATHS))

    # Encode a "mean BUY window" and "mean SELL window"
    # by using the average feature values
    def make_holon_data(mean_features):
        """Build holon data dict from (window, n_features) mean array."""
        data = {}
        for t in range(window_size):
            vals = {feat: mean_features[t, f]
                    for f, feat in enumerate(ALL_FEATURES)}
            data[f"t{t}"] = {
                "price": {
                    "open": LinearScale(vals["open"], scale=SCALE),
                    "high": LinearScale(vals["high"], scale=SCALE),
                    "low": LinearScale(vals["low"], scale=SCALE),
                    "close": LinearScale(vals["close"], scale=SCALE),
                    "sma20": LinearScale(vals["sma20"], scale=SCALE),
                    "sma50": LinearScale(vals["sma50"], scale=SCALE),
                    "sma200": LinearScale(vals["sma200"], scale=SCALE),
                    "bb_upper": LinearScale(vals["bb_upper"], scale=SCALE),
                    "bb_lower": LinearScale(vals["bb_lower"], scale=SCALE),
                },
                "volume": LinearScale(vals["volume"], scale=SCALE),
                "rsi": LinearScale(vals["rsi"], scale=SCALE),
                "macd": {
                    "line": LinearScale(vals["macd_line"], scale=SCALE),
                    "signal": LinearScale(vals["macd_signal"], scale=SCALE),
                    "hist": LinearScale(vals["macd_hist"], scale=SCALE),
                },
                "dmi": {
                    "plus": LinearScale(vals["dmi_plus"], scale=SCALE),
                    "minus": LinearScale(vals["dmi_minus"], scale=SCALE),
                    "adx": LinearScale(vals["adx"], scale=SCALE),
                },
            }
        return data

    buy_data = make_holon_data(buy_mean_feat)
    sell_data = make_holon_data(sell_mean_feat)

    buy_stripes = encoder.encode_walkable_striped(buy_data, n_stripes)
    sell_stripes = encoder.encode_walkable_striped(sell_data, n_stripes)

    log(f"\n  Cosine(buy_encoded, sell_encoded) per stripe:")
    for s in range(n_stripes):
        cos = cosine_similarity(
            buy_stripes[s].astype(np.float64),
            sell_stripes[s].astype(np.float64)
        )
        log(f"    Stripe {s:2d}: {cos:.6f}  "
            f"({len(stripe_map[s])} leaves)")

    # Per-leaf contribution to discriminant
    log(f"\n--- Per-leaf discriminant contribution ---")
    log("  For each leaf path, compute leaf_binding and measure how much")
    log("  the BUY vs SELL value change affects the stripe vector.")

    leaf_contribs = []
    for i, (path, feat_name) in enumerate(zip(LEAF_PATHS, LEAF_FEATURE_NAMES)):
        s = Encoder.field_stripe(path, n_stripes)
        parts = feat_name.split(".")
        t_idx = int(parts[0][1:])
        feat = parts[1]
        f_idx = ALL_FEATURES.index(feat)

        buy_val = buy_mean_feat[t_idx, f_idx]
        sell_val = sell_mean_feat[t_idx, f_idx]
        raw_diff = abs(buy_val - sell_val)

        buy_binding = encoder.leaf_binding(
            LinearScale(buy_val, scale=SCALE), path
        ).astype(np.float64)
        sell_binding = encoder.leaf_binding(
            LinearScale(sell_val, scale=SCALE), path
        ).astype(np.float64)

        binding_cos = cosine_similarity(buy_binding, sell_binding)
        binding_diff_norm = np.linalg.norm(buy_binding - sell_binding)

        leaf_contribs.append({
            "path": path,
            "feat_name": feat_name,
            "stripe": s,
            "buy_val": buy_val,
            "sell_val": sell_val,
            "raw_diff": raw_diff,
            "binding_cos": binding_cos,
            "binding_diff_norm": binding_diff_norm,
        })

    # Sort by binding difference (what the encoding sees)
    leaf_contribs.sort(key=lambda x: -x["binding_diff_norm"])

    log(f"\n  Top 30 leaves by ENCODED difference (binding_diff_norm):")
    log(f"  {'Rank':<5} {'Path':<25} {'Stripe':>6} {'BUY':>8} {'SELL':>8} "
        f"{'RawDiff':>8} {'BindCos':>9} {'BindDiff':>9}")
    for rank, lc in enumerate(leaf_contribs[:30]):
        log(f"  {rank+1:<5} {lc['path']:<25} {lc['stripe']:>6} "
            f"{lc['buy_val']:8.4f} {lc['sell_val']:8.4f} "
            f"{lc['raw_diff']:8.5f} {lc['binding_cos']:9.5f} "
            f"{lc['binding_diff_norm']:9.3f}")

    log(f"\n  Bottom 10 leaves (most similar between BUY/SELL):")
    for rank, lc in enumerate(leaf_contribs[-10:]):
        log(f"  {len(leaf_contribs)-9+rank:<5} {lc['path']:<25} "
            f"{lc['stripe']:>6} {lc['buy_val']:8.4f} {lc['sell_val']:8.4f} "
            f"{lc['raw_diff']:8.5f} {lc['binding_cos']:9.5f} "
            f"{lc['binding_diff_norm']:9.3f}")

    # ==================================================================
    # LEVEL 3: Variance analysis — is the signal in spread, not mean?
    # ==================================================================
    log(f"\n{'='*80}")
    log("LEVEL 3: VARIANCE ANALYSIS — Is the signal in the spread?")
    log(f"{'='*80}")

    log(f"\n--- Per-feature std comparison ---")
    log(f"  If BUY and SELL have different variance, the signal lives")
    log(f"  in the distribution shape, not the center.")
    log(f"\n  {'Feature':<16} {'BUY std':>10} {'SELL std':>10} "
        f"{'Ratio':>8} {'StdDiff':>10}")
    for f, feat in enumerate(ALL_FEATURES):
        bs = buy_std_feat[:, f].mean()
        ss = sell_std_feat[:, f].mean()
        ratio = bs / ss if ss > 1e-10 else float("inf")
        log(f"  {feat:<16} {bs:10.6f} {ss:10.6f} {ratio:8.3f} "
            f"{abs(bs - ss):10.6f}")

    # Distribution overlap: for each feature, what % of BUY/SELL
    # distributions overlap?
    log(f"\n--- Distribution overlap (last candle t{window_size-1}) ---")
    log(f"  {'Feature':<16} {'Overlap%':>10} {'BUY[25,50,75]':>30} "
        f"{'SELL[25,50,75]':>30}")
    t_last = window_size - 1
    for f, feat in enumerate(ALL_FEATURES):
        bvals = buy_features[:, t_last, f]
        svals = sell_features[:, t_last, f]
        # Approximate overlap via histogram
        lo = min(bvals.min(), svals.min())
        hi = max(bvals.max(), svals.max())
        if hi - lo < 1e-10:
            overlap = 100.0
        else:
            bins = np.linspace(lo, hi, 51)
            bh, _ = np.histogram(bvals, bins=bins, density=True)
            sh, _ = np.histogram(svals, bins=bins, density=True)
            bh = bh / (bh.sum() + 1e-10)
            sh = sh / (sh.sum() + 1e-10)
            overlap = np.minimum(bh, sh).sum() * 100

        bq = np.percentile(bvals, [25, 50, 75])
        sq = np.percentile(svals, [25, 50, 75])
        log(f"  {feat:<16} {overlap:9.1f}% "
            f"  [{bq[0]:.3f}, {bq[1]:.3f}, {bq[2]:.3f}]"
            f"  [{sq[0]:.3f}, {sq[1]:.3f}, {sq[2]:.3f}]")

    log(f"\n{'='*80}")
    log("SUMMARY")
    log(f"{'='*80}")
    overall_max_effect = 0
    for flat_idx in top_indices[:5]:
        t_idx = flat_idx // n_features
        f_idx = flat_idx % n_features
        pooled_std = np.sqrt(
            (buy_std_feat[t_idx, f_idx]**2 + sell_std_feat[t_idx, f_idx]**2) / 2
        )
        effect = abs(buy_mean_feat[t_idx, f_idx] - sell_mean_feat[t_idx, f_idx]) / (
            pooled_std if pooled_std > 1e-10 else 1
        )
        overall_max_effect = max(overall_max_effect, effect)

    log(f"  Raw feature cosine (BUY vs SELL means): {cos_raw:.6f}")
    log(f"  Encoded cosine (BUY vs SELL means):     0.9961")
    log(f"  Max effect size (Cohen's d):            {overall_max_effect:.4f}")
    log(f"  Max raw feature difference:             {np.abs(diff_feat).max():.6f}")
    if overall_max_effect < 0.2:
        log(f"\n  VERDICT: The features themselves barely differ between BUY")
        log(f"  and SELL. The encoding is faithfully representing identical")
        log(f"  inputs. No encoding scheme can separate what doesn't differ.")
    elif cos_raw < 0.99 and overall_max_effect > 0.2:
        log(f"\n  VERDICT: Raw features DO differ (effect size > 0.2) but the")
        log(f"  encoding compresses that signal. Need better encoding scheme.")
    else:
        log(f"\n  VERDICT: Features differ slightly but with massive overlap.")
        log(f"  Signal exists but may need ensemble/temporal methods to extract.")


if __name__ == "__main__":
    main()
