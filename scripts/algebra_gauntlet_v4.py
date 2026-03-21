"""Algebra Gauntlet v4: The Trader's Screen

Core thesis: a trader sees 12 candles (1 hour) of indicators on a fixed display.
The SHAPE of each indicator over time is what distinguishes BUY from SELL setups.
Not the current value — the trajectory.

Strategy:
  1. Normalize each feature to [0,1] across the whole training set
  2. For each window of 12 candles, capture the [0,1] trajectory per feature
  3. Encode each feature's trajectory independently (like a stripe)
  4. Compare trajectory shapes between BUY and SELL windows
  5. Apply algebra techniques to amplify trajectory differences

Encoding approaches:
  A) Per-feature thermometer trajectory (12 thermometer vecs bundled with positions)
  B) Per-feature shape statistics (slope, curvature, min/max pos)
  C) Striped walkable with [0,1] + small scale
  D) Raw trajectory k-NN (the 20×12 "image" flattened)

Usage:
    ./scripts/run_with_venv.sh python holon-lab-trading/scripts/algebra_gauntlet_v4.py
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
    reject,
    resonance,
    similarity_profile,
)
from holon.kernel.walkable import LinearScale, WalkableSpread
from holon.memory import StripedSubspace

DB_PATH = Path(__file__).parent.parent / "data" / "analysis.db"

DIM = 1024
K = 32
N_STRIPES = 32
WINDOW = 12

FEATURES = [
    "sma_cross_50_200", "sma200_r", "ema100_r",
    "dmi_plus", "dmi_minus",
    "rsi", "macd_line_r", "ema_cross_9_21",
    "trend_consistency_24", "tf_4h_body", "tf_4h_close_pos",
    "kelt_pos", "range_pos_48", "bb_pos",
    "dow_sin", "hour_cos",
    "vol_accel", "atr_roc_6",
    "vol_up_ratio_12", "obv_slope_12",
]


def log(msg: str):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def load_data(args):
    conn = sqlite3.connect(str(DB_PATH))

    cols = ["ts", "year"] + FEATURES + [args.label, "atr_r"]
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


def compute_minmax(candles, features, indices):
    stats = {}
    for feat in features:
        vals = []
        for idx in indices:
            for offset in range(WINDOW):
                i = idx - WINDOW + 1 + offset
                if 0 <= i < len(candles):
                    v = candles[i].get(feat, 0.0)
                    if v is not None:
                        vals.append(float(v))
        lo = np.percentile(vals, 1) if vals else 0.0
        hi = np.percentile(vals, 99) if vals else 1.0
        if hi - lo < 1e-10:
            hi = lo + 1.0
        stats[feat] = {"min": lo, "max": hi}
    return stats


def norm_01(value, feat_stats):
    if value is None:
        value = 0.0
    lo = feat_stats["min"]
    hi = feat_stats["max"]
    return max(0.0, min(1.0, (float(value) - lo) / (hi - lo)))


def get_trajectory(candles, idx, feat, minmax):
    """Get [0,1]-normalized 12-candle trajectory for one feature."""
    traj = []
    for offset in range(WINDOW):
        i = idx - WINDOW + 1 + offset
        if i < 0:
            i = 0
        v = candles[i].get(feat, 0.0)
        traj.append(norm_01(v, minmax[feat]))
    return np.array(traj)


def get_full_image(candles, idx, features, minmax):
    """Get the 'trader screen': 20 features × 12 timesteps → shape (20, 12)."""
    image = []
    for feat in features:
        traj = get_trajectory(candles, idx, feat, minmax)
        image.append(traj)
    return np.array(image)


def thermometer_encode(value_01, dim, seed=42):
    rng = np.random.default_rng(seed)
    perm = rng.permutation(dim)
    n_hot = int(round(value_01 * dim))
    vec = np.full(dim, -1, dtype=np.int8)
    vec[perm[:n_hot]] = 1
    return vec


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
    log("ALGEBRA GAUNTLET v4: The Trader's Screen (12-candle trajectories)")
    log("=" * 75)

    candles = load_data(args)
    log(f"Loaded {len(candles):,} candles (2019-2020)")

    # Filter to labeled + high-vol
    eligible = [i for i in range(WINDOW - 1, len(candles))
                if candles[i].get(args.label) in ("BUY", "SELL")
                and (candles[i].get("atr_r") or 0) > args.vol_threshold]

    buy_idx = [i for i in eligible if candles[i][args.label] == "BUY"]
    sell_idx = [i for i in eligible if candles[i][args.label] == "SELL"]
    log(f"Eligible: {len(buy_idx)} BUY, {len(sell_idx)} SELL")

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

    # [0,1] normalization from training windows
    all_train = train_buy_idx + train_sell_idx
    minmax = compute_minmax(candles, FEATURES, all_train)
    log("Min-max stats computed from training windows")

    # ===================================================================
    # PART A: Raw trajectory baseline — the 20×12 "image"
    # ===================================================================
    log("")
    log("=" * 75)
    log("PART A: Raw trajectory 'image' (20 features × 12 timesteps)")
    log("=" * 75)

    def get_flat_image(idx):
        return get_full_image(candles, idx, FEATURES, minmax).flatten()

    train_buy_img = [get_flat_image(i) for i in train_buy_idx]
    train_sell_img = [get_flat_image(i) for i in train_sell_idx]
    test_buy_img = [get_flat_image(i) for i in test_buy_idx]
    test_sell_img = [get_flat_image(i) for i in test_sell_idx]

    # Mean images
    buy_mean_img = np.mean(train_buy_img, axis=0)
    sell_mean_img = np.mean(train_sell_img, axis=0)
    img_diff = np.abs(buy_mean_img - sell_mean_img)
    log(f"Mean image distance: {np.linalg.norm(buy_mean_img - sell_mean_img):.4f}")
    log(f"Max per-pixel diff: {np.max(img_diff):.4f}, mean: {np.mean(img_diff):.4f}")

    # Centroid classifier
    def classify_centroid(v):
        return "BUY" if np.linalg.norm(v - buy_mean_img) < np.linalg.norm(v - sell_mean_img) else "SELL"
    evaluate("Raw image: Centroid (Euclidean)", test_buy_img, test_sell_img, classify_centroid)

    # Cosine centroid
    def classify_cos_cent(v):
        return "BUY" if cosine_similarity(v, buy_mean_img) > cosine_similarity(v, sell_mean_img) else "SELL"
    evaluate("Raw image: Centroid (Cosine)", test_buy_img, test_sell_img, classify_cos_cent)

    # k-NN
    for k in [5, 11, 21, 51]:
        def make_knn(kk):
            def classify(v):
                all_sims = []
                for tv in train_buy_img:
                    all_sims.append((cosine_similarity(v, tv), "BUY"))
                for tv in train_sell_img:
                    all_sims.append((cosine_similarity(v, tv), "SELL"))
                all_sims.sort(key=lambda x: -x[0])
                buy_votes = sum(1 for _, l in all_sims[:kk] if l == "BUY")
                return "BUY" if buy_votes > kk // 2 else "SELL"
            return classify
        evaluate(f"Raw image: k-NN (k={k})", test_buy_img, test_sell_img, make_knn(k))

    # ===================================================================
    # PART B: Per-feature trajectory shape analysis
    # ===================================================================
    log("")
    log("=" * 75)
    log("PART B: Per-feature trajectory shape (BUY vs SELL mean trajectories)")
    log("=" * 75)

    feat_trajectory_diffs = []
    for feat in FEATURES:
        buy_trajs = [get_trajectory(candles, i, feat, minmax) for i in train_buy_idx]
        sell_trajs = [get_trajectory(candles, i, feat, minmax) for i in train_sell_idx]

        buy_mean_traj = np.mean(buy_trajs, axis=0)
        sell_mean_traj = np.mean(sell_trajs, axis=0)

        # Shape metrics
        traj_diff = np.linalg.norm(buy_mean_traj - sell_mean_traj)

        # Slope: linear fit
        t = np.arange(WINDOW)
        buy_slope = np.polyfit(t, buy_mean_traj, 1)[0]
        sell_slope = np.polyfit(t, sell_mean_traj, 1)[0]
        slope_diff = buy_slope - sell_slope

        # End-start (direction of last hour)
        buy_dir = buy_mean_traj[-1] - buy_mean_traj[0]
        sell_dir = sell_mean_traj[-1] - sell_mean_traj[0]

        feat_trajectory_diffs.append({
            "feat": feat,
            "traj_diff": traj_diff,
            "slope_diff": slope_diff,
            "buy_slope": buy_slope,
            "sell_slope": sell_slope,
            "buy_dir": buy_dir,
            "sell_dir": sell_dir,
            "buy_last": buy_mean_traj[-1],
            "sell_last": sell_mean_traj[-1],
        })

    feat_trajectory_diffs.sort(key=lambda x: -abs(x["slope_diff"]))
    log(f"{'Feature':<25s} {'TrajDiff':>8s} {'BuySlope':>8s} {'SellSlope':>9s} {'ΔSlope':>8s} {'BuyDir':>7s} {'SellDir':>8s}")
    log("-" * 95)
    for d in feat_trajectory_diffs:
        marker = " <<<" if abs(d["slope_diff"]) > 0.001 else ""
        log(f"  {d['feat']:<25s} {d['traj_diff']:>8.4f} {d['buy_slope']:>+8.4f} {d['sell_slope']:>+9.4f} "
            f"{d['slope_diff']:>+8.4f} {d['buy_dir']:>+7.3f} {d['sell_dir']:>+8.3f}{marker}")

    # ===================================================================
    # PART C: Trajectory-encoded Holon (striped, [0,1], good scale)
    # ===================================================================
    log("")
    log("=" * 75)
    log("PART C: Striped walkable encoding ([0,1], scale sweep)")
    log("=" * 75)

    client = HolonClient(dimensions=DIM)

    for scale in [0.001, 0.005, 0.01, 0.05, 0.1]:
        def encode_striped_01(idx, sc=scale):
            walkable = {}
            for feat in FEATURES:
                traj = get_trajectory(candles, idx, feat, minmax)
                vals = [LinearScale(float(v), scale=sc) for v in traj]
                walkable[feat] = WalkableSpread(vals)
            return client.encoder.encode_walkable_striped(walkable, n_stripes=N_STRIPES)

        train_buy_s = [encode_striped_01(i) for i in train_buy_idx]
        train_sell_s = [encode_striped_01(i) for i in train_sell_idx]
        test_buy_s = [encode_striped_01(i) for i in test_buy_idx]
        test_sell_s = [encode_striped_01(i) for i in test_sell_idx]

        # Per-stripe prototype similarity
        stripe_sims = []
        s_buy_protos = []
        s_sell_protos = []
        for s in range(N_STRIPES):
            bvs = [v[s] for v in train_buy_s]
            svs = [v[s] for v in train_sell_s]
            bp_s = prototype(bvs)
            sp_s = prototype(svs)
            s_buy_protos.append(bp_s)
            s_sell_protos.append(sp_s)
            stripe_sims.append(cosine_similarity(bp_s, sp_s))

        mean_sim = np.mean(stripe_sims)
        min_sim = np.min(stripe_sims)

        # Prototype classifier (aggregate across stripes)
        def make_proto_cls(bp_list, sp_list):
            def classify(stripes):
                buy_sim = sum(cosine_similarity(stripes[s], bp_list[s]) for s in range(N_STRIPES))
                sell_sim = sum(cosine_similarity(stripes[s], sp_list[s]) for s in range(N_STRIPES))
                return "BUY" if buy_sim > sell_sim else "SELL"
            return classify

        correct = sum(1 for v in test_buy_s if make_proto_cls(s_buy_protos, s_sell_protos)(v) == "BUY")
        correct += sum(1 for v in test_sell_s if make_proto_cls(s_buy_protos, s_sell_protos)(v) == "SELL")
        acc_p = correct / (len(test_buy_s) + len(test_sell_s)) * 100

        # Soft centroid per stripe
        s_buy_cents = [np.mean([v[s].astype(float) for v in train_buy_s], axis=0) for s in range(N_STRIPES)]
        s_sell_cents = [np.mean([v[s].astype(float) for v in train_sell_s], axis=0) for s in range(N_STRIPES)]

        def make_cent_cls(bc_list, sc_list):
            def classify(stripes):
                buy_sim = sum(cosine_similarity(stripes[s].astype(float), bc_list[s]) for s in range(N_STRIPES))
                sell_sim = sum(cosine_similarity(stripes[s].astype(float), sc_list[s]) for s in range(N_STRIPES))
                return "BUY" if buy_sim > sell_sim else "SELL"
            return classify

        correct_c = sum(1 for v in test_buy_s if make_cent_cls(s_buy_cents, s_sell_cents)(v) == "BUY")
        correct_c += sum(1 for v in test_sell_s if make_cent_cls(s_buy_cents, s_sell_cents)(v) == "SELL")
        acc_c = correct_c / (len(test_buy_s) + len(test_sell_s)) * 100

        log(f"  scale={scale:<7.4f} stripe_sim={mean_sim:.4f} (min={min_sim:.4f}) proto={acc_p:>5.1f}% centroid={acc_c:>5.1f}%")

    # ===================================================================
    # PART D: Per-feature stripe analysis (which features' trajectories
    #         are most discriminative in HDC space?)
    # ===================================================================
    log("")
    log("=" * 75)
    log("PART D: Per-stripe discrimination (scale=0.01)")
    log("=" * 75)

    BEST_SCALE = 0.01

    def encode_striped_best(idx):
        walkable = {}
        for feat in FEATURES:
            traj = get_trajectory(candles, idx, feat, minmax)
            vals = [LinearScale(float(v), scale=BEST_SCALE) for v in traj]
            walkable[feat] = WalkableSpread(vals)
        return client.encoder.encode_walkable_striped(walkable, n_stripes=N_STRIPES)

    train_buy_best = [encode_striped_best(i) for i in train_buy_idx]
    train_sell_best = [encode_striped_best(i) for i in train_sell_idx]
    test_buy_best = [encode_striped_best(i) for i in test_buy_idx]
    test_sell_best = [encode_striped_best(i) for i in test_sell_idx]

    # Per-stripe accuracy
    stripe_accs = []
    for s in range(N_STRIPES):
        bvs = [v[s] for v in train_buy_best]
        svs = [v[s] for v in train_sell_best]
        bp = prototype(bvs)
        sp = prototype(svs)
        sim = cosine_similarity(bp, sp)

        # Soft centroids
        bc = np.mean([v.astype(float) for v in bvs], axis=0)
        sc = np.mean([v.astype(float) for v in svs], axis=0)

        test_bvs = [v[s] for v in test_buy_best]
        test_svs = [v[s] for v in test_sell_best]

        correct = sum(1 for v in test_bvs if cosine_similarity(v, bc) > cosine_similarity(v, sc))
        correct += sum(1 for v in test_svs if cosine_similarity(v, sc) > cosine_similarity(v, bc))
        acc = correct / (len(test_bvs) + len(test_svs)) * 100

        # Find which features map to this stripe
        feats_in_stripe = [f for f in FEATURES if client.encoder.field_stripe(f, N_STRIPES) == s]

        stripe_accs.append((s, sim, acc, feats_in_stripe))

    stripe_accs.sort(key=lambda x: -x[2])
    log(f"{'Stripe':>6s} {'ProtoSim':>8s} {'Acc':>6s} Features")
    log("-" * 75)
    for s, sim, acc, feats in stripe_accs:
        marker = " <<<" if acc > 55 else ""
        log(f"  {s:>4d}   {sim:>8.4f} {acc:>5.1f}% {', '.join(feats) if feats else '(empty)'}{marker}")

    # ===================================================================
    # PART E: Algebra on striped trajectories
    # ===================================================================
    log("")
    log("=" * 75)
    log("PART E: Algebra on striped trajectories (scale=0.01)")
    log("=" * 75)

    # Build per-stripe prototypes and tools
    s_bp = []
    s_sp = []
    s_mp = []
    s_cv = []
    for s in range(N_STRIPES):
        bvs = [v[s] for v in train_buy_best]
        svs = [v[s] for v in train_sell_best]
        bp = prototype(bvs)
        sp = prototype(svs)
        mp = prototype(bvs + svs)
        cv = difference(sp, bp)
        s_bp.append(bp)
        s_sp.append(sp)
        s_mp.append(mp)
        s_cv.append(cv)

    # 1. Prototype (already done, but for reference)
    def cls_proto(stripes):
        buy_sim = sum(cosine_similarity(stripes[s], s_bp[s]) for s in range(N_STRIPES))
        sell_sim = sum(cosine_similarity(stripes[s], s_sp[s]) for s in range(N_STRIPES))
        return "BUY" if buy_sim > sell_sim else "SELL"
    evaluate("Striped: Prototype", test_buy_best, test_sell_best, cls_proto)

    # 2. Soft centroid
    s_bc = [np.mean([v[s].astype(float) for v in train_buy_best], axis=0) for s in range(N_STRIPES)]
    s_sc = [np.mean([v[s].astype(float) for v in train_sell_best], axis=0) for s in range(N_STRIPES)]

    def cls_centroid(stripes):
        buy_sim = sum(cosine_similarity(stripes[s].astype(float), s_bc[s]) for s in range(N_STRIPES))
        sell_sim = sum(cosine_similarity(stripes[s].astype(float), s_sc[s]) for s in range(N_STRIPES))
        return "BUY" if buy_sim > sell_sim else "SELL"
    evaluate("Striped: Soft centroid", test_buy_best, test_sell_best, cls_centroid)

    # 3. Negate shared
    s_bp_c = [negate(s_bp[s], s_mp[s]) for s in range(N_STRIPES)]
    s_sp_c = [negate(s_sp[s], s_mp[s]) for s in range(N_STRIPES)]

    def cls_negate(stripes):
        buy_sim = sell_sim = 0
        for s in range(N_STRIPES):
            cleaned = negate(stripes[s], s_mp[s])
            buy_sim += cosine_similarity(cleaned, s_bp_c[s])
            sell_sim += cosine_similarity(cleaned, s_sp_c[s])
        return "BUY" if buy_sim > sell_sim else "SELL"
    evaluate("Striped: Negate shared", test_buy_best, test_sell_best, cls_negate)

    # 4. Grover amplify
    s_bp_g = [grover_amplify(s_bp_c[s], s_sp_c[s], iterations=2) for s in range(N_STRIPES)]
    s_sp_g = [grover_amplify(s_sp_c[s], s_bp_c[s], iterations=2) for s in range(N_STRIPES)]

    def cls_negate_grover(stripes):
        buy_sim = sell_sim = 0
        for s in range(N_STRIPES):
            cleaned = negate(stripes[s], s_mp[s])
            buy_sim += cosine_similarity(cleaned, s_bp_g[s])
            sell_sim += cosine_similarity(cleaned, s_sp_g[s])
        return "BUY" if buy_sim > sell_sim else "SELL"
    evaluate("Striped: Negate + Grover", test_buy_best, test_sell_best, cls_negate_grover)

    # 5. Contrast direct
    def cls_contrast(stripes):
        score = sum(cosine_similarity(stripes[s], s_cv[s]) for s in range(N_STRIPES))
        return "BUY" if score > 0 else "SELL"
    evaluate("Striped: Contrast direct", test_buy_best, test_sell_best, cls_contrast)

    # 6. Subspace residual
    buy_sub = StripedSubspace(dim=DIM, k=K, n_stripes=N_STRIPES)
    for stripes in train_buy_best:
        buy_sub.update(stripes)
    sell_sub = StripedSubspace(dim=DIM, k=K, n_stripes=N_STRIPES)
    for stripes in train_sell_best:
        sell_sub.update(stripes)

    def cls_subspace(stripes):
        return "BUY" if buy_sub.residual(stripes) < sell_sub.residual(stripes) else "SELL"
    evaluate("Striped: Subspace residual", test_buy_best, test_sell_best, cls_subspace)

    # 7. Weighted stripe voting (weight by per-stripe discrimination)
    stripe_weights = np.array([1.0 - sim for _, sim, _, _ in sorted(stripe_accs, key=lambda x: x[0])])
    stripe_weights /= stripe_weights.sum() + 1e-10

    def cls_weighted_proto(stripes):
        buy_sim = sum(stripe_weights[s] * cosine_similarity(stripes[s], s_bp[s]) for s in range(N_STRIPES))
        sell_sim = sum(stripe_weights[s] * cosine_similarity(stripes[s], s_sp[s]) for s in range(N_STRIPES))
        return "BUY" if buy_sim > sell_sim else "SELL"
    evaluate("Striped: Weighted prototype", test_buy_best, test_sell_best, cls_weighted_proto)

    # 8. Per-stripe confidence-weighted
    s_bv_conf = []
    s_sv_conf = []
    for s in range(N_STRIPES):
        bvs = [v[s] for v in train_buy_best]
        svs = [v[s] for v in train_sell_best]
        bv, bc = bundle_with_confidence(bvs)
        sv, sc = bundle_with_confidence(svs)
        s_bv_conf.append((bv, bc))
        s_sv_conf.append((sv, sc))

    def cls_confidence(stripes):
        buy_score = sell_score = 0
        for s in range(N_STRIPES):
            v = stripes[s].astype(float)
            bv, bc = s_bv_conf[s]
            sv, sc = s_sv_conf[s]
            buy_score += float(np.sum(v * bv.astype(float) * bc))
            sell_score += float(np.sum(v * sv.astype(float) * sc))
        return "BUY" if buy_score > sell_score else "SELL"
    evaluate("Striped: Bundle with confidence", test_buy_best, test_sell_best, cls_confidence)

    # ===================================================================
    # PART F: Trajectory shape features (slope, curvature, range)
    # ===================================================================
    log("")
    log("=" * 75)
    log("PART F: Trajectory shape features (slope, curvature, range)")
    log("=" * 75)

    def extract_shape(idx):
        """Extract shape statistics from each feature's trajectory."""
        feats = []
        t = np.arange(WINDOW, dtype=float)
        for feat in FEATURES:
            traj = get_trajectory(candles, idx, feat, minmax)
            # Slope (linear regression)
            slope = np.polyfit(t, traj, 1)[0]
            # Level at end
            end_val = traj[-1]
            # Range
            traj_range = traj.max() - traj.min()
            # Direction (end - start)
            direction = traj[-1] - traj[0]
            # Curvature (2nd half slope - 1st half slope)
            half = WINDOW // 2
            slope1 = np.polyfit(t[:half], traj[:half], 1)[0]
            slope2 = np.polyfit(t[half:], traj[half:], 1)[0]
            curvature = slope2 - slope1
            # Momentum (last 3 vs first 3)
            mom = np.mean(traj[-3:]) - np.mean(traj[:3])

            feats.extend([slope, end_val, traj_range, direction, curvature, mom])
        return np.array(feats)

    train_buy_shape = [extract_shape(i) for i in train_buy_idx]
    train_sell_shape = [extract_shape(i) for i in train_sell_idx]
    test_buy_shape = [extract_shape(i) for i in test_buy_idx]
    test_sell_shape = [extract_shape(i) for i in test_sell_idx]

    shape_dim = len(train_buy_shape[0])
    log(f"Shape features: {shape_dim} dimensions ({len(FEATURES)} feats × 6 shape stats)")

    buy_mean_shape = np.mean(train_buy_shape, axis=0)
    sell_mean_shape = np.mean(train_sell_shape, axis=0)
    log(f"Shape centroid distance: {np.linalg.norm(buy_mean_shape - sell_mean_shape):.4f}")

    # Centroid
    evaluate("Shape: Centroid (Euclidean)",
             test_buy_shape, test_sell_shape,
             lambda v: "BUY" if np.linalg.norm(v - buy_mean_shape) < np.linalg.norm(v - sell_mean_shape) else "SELL")

    evaluate("Shape: Centroid (Cosine)",
             test_buy_shape, test_sell_shape,
             lambda v: "BUY" if cosine_similarity(v, buy_mean_shape) > cosine_similarity(v, sell_mean_shape) else "SELL")

    # k-NN
    for k in [5, 11, 21]:
        def make_shape_knn(kk):
            def classify(v):
                all_sims = [(cosine_similarity(v, tv), "BUY") for tv in train_buy_shape]
                all_sims += [(cosine_similarity(v, tv), "SELL") for tv in train_sell_shape]
                all_sims.sort(key=lambda x: -x[0])
                buy_votes = sum(1 for _, l in all_sims[:kk] if l == "BUY")
                return "BUY" if buy_votes > kk // 2 else "SELL"
            return classify
        evaluate(f"Shape: k-NN (k={k})", test_buy_shape, test_sell_shape, make_shape_knn(k))

    # ===================================================================
    # PART G: Combined image + shape k-NN
    # ===================================================================
    log("")
    log("=" * 75)
    log("PART G: Combined (image + shape) k-NN")
    log("=" * 75)

    train_buy_combined = [np.concatenate([img, shp]) for img, shp in zip(train_buy_img, train_buy_shape)]
    train_sell_combined = [np.concatenate([img, shp]) for img, shp in zip(train_sell_img, train_sell_shape)]
    test_buy_combined = [np.concatenate([img, shp]) for img, shp in zip(test_buy_img, test_buy_shape)]
    test_sell_combined = [np.concatenate([img, shp]) for img, shp in zip(test_sell_img, test_sell_shape)]

    for k in [5, 11, 21]:
        def make_combo_knn(kk):
            def classify(v):
                all_sims = [(cosine_similarity(v, tv), "BUY") for tv in train_buy_combined]
                all_sims += [(cosine_similarity(v, tv), "SELL") for tv in train_sell_combined]
                all_sims.sort(key=lambda x: -x[0])
                buy_votes = sum(1 for _, l in all_sims[:kk] if l == "BUY")
                return "BUY" if buy_votes > kk // 2 else "SELL"
            return classify
        evaluate(f"Combined: k-NN (k={k})", test_buy_combined, test_sell_combined, make_combo_knn(k))

    log("")
    log("=" * 75)
    log("DONE — The trader's screen: 12-candle window results")
    log("=" * 75)


if __name__ == "__main__":
    main()
