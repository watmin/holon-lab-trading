"""Algebra Gauntlet v3: [0,1] normalization + better classifiers.

Key insight from user: normalize to [0,1] like a trader's screen. Every
indicator on the same pixel grid. Combined with the finding that prototype-
based classifiers fail when distributions overlap 90%+, we need:

  1. [0,1] min-max normalization (trader's view)
  2. k-NN classifier (votes from neighbors, not global prototype)
  3. Centroid classifier (soft mean without bipolar threshold)
  4. Discriminative dimension masking (use only dimensions that differ)
  5. Multiple encoding strategies:
     a) Direct scalar per feature (no walkable spread)
     b) Thermometer-style encoding (value→fraction of +1 dims)
     c) Circular encoding for bounded [0,1] features

Usage:
    ./scripts/run_with_venv.sh python holon-lab-trading/scripts/algebra_gauntlet_v3.py
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
    amplify,
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
from holon.kernel.scalar import encode_circular, encode_positional

DB_PATH = Path(__file__).parent.parent / "data" / "analysis.db"

DIM = 1024
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


cosine_sim = cosine_similarity


def load_data(args):
    conn = sqlite3.connect(str(DB_PATH))

    # z-score stats
    rows = conn.execute("SELECT * FROM feature_stats").fetchall()
    zscore_stats = {}
    for r in rows:
        zscore_stats[r[0]] = {"mean": r[1], "std": r[2]}

    cols = ["ts", "year"] + FEATURES + [args.label]
    cols_str = ", ".join(cols)
    query = f"""
        SELECT {cols_str} FROM candles
        WHERE {args.label} IN ('BUY', 'SELL')
          AND atr_r > {args.vol_threshold}
          AND year BETWEEN 2019 AND 2020
        ORDER BY ts
    """
    all_rows = conn.execute(query).fetchall()
    conn.close()
    candles = [{cols[i]: r[i] for i in range(len(cols))} for r in all_rows]
    return candles, zscore_stats


def compute_minmax(candles, features, train_indices):
    """Compute per-feature min/max from training data for [0,1] normalization."""
    stats = {}
    for feat in features:
        vals = [float(candles[i].get(feat, 0.0) or 0.0) for i in train_indices]
        lo = np.percentile(vals, 1)   # 1st percentile (robust to outliers)
        hi = np.percentile(vals, 99)  # 99th percentile
        if hi - lo < 1e-10:
            hi = lo + 1.0
        stats[feat] = {"min": lo, "max": hi}
    return stats


def norm_01(value: float, feat_stats: dict) -> float:
    """Normalize to [0,1] range using min-max from training data."""
    lo = feat_stats["min"]
    hi = feat_stats["max"]
    return max(0.0, min(1.0, (value - lo) / (hi - lo)))


def norm_zscore(value: float, feat_stats: dict) -> float:
    std = feat_stats.get("std")
    mean = feat_stats.get("mean")
    if std is None or mean is None or std < 1e-10:
        return 0.0
    return (value - mean) / std


def thermometer_encode(value_01: float, dim: int, seed: int = 42) -> np.ndarray:
    """Encode [0,1] value as thermometer: fraction of dims set to +1.

    value=0 → all -1, value=1 → all +1, value=0.5 → half +1 half -1.
    Uses a random permutation so each feature's dims are in different order.
    """
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


def knn_classifier(test_vec, train_buy_vecs, train_sell_vecs, k=5):
    """k-NN in cosine similarity space."""
    all_sims = []
    for v in train_buy_vecs:
        all_sims.append((cosine_sim(test_vec, v), "BUY"))
    for v in train_sell_vecs:
        all_sims.append((cosine_sim(test_vec, v), "SELL"))
    all_sims.sort(key=lambda x: -x[0])
    top_k = all_sims[:k]
    buy_votes = sum(1 for _, label in top_k if label == "BUY")
    return "BUY" if buy_votes > k // 2 else "SELL"


def mean_sim_classifier(test_vec, train_buy_vecs, train_sell_vecs):
    """Classify by mean cosine similarity to each class."""
    buy_sim = np.mean([cosine_sim(test_vec, v) for v in train_buy_vecs])
    sell_sim = np.mean([cosine_sim(test_vec, v) for v in train_sell_vecs])
    return "BUY" if buy_sim > sell_sim else "SELL"


def centroid_classifier(test_vec, buy_centroid, sell_centroid):
    """Soft centroid: mean of float vectors (no bipolar threshold)."""
    return "BUY" if cosine_sim(test_vec, buy_centroid) > cosine_sim(test_vec, sell_centroid) else "SELL"


def masked_classifier(test_vec, buy_proto, sell_proto, mask):
    """Classify using only discriminative dimensions (where mask != 0)."""
    masked_test = test_vec.astype(float) * mask
    masked_buy = buy_proto.astype(float) * mask
    masked_sell = sell_proto.astype(float) * mask
    buy_sim = cosine_sim(masked_test, masked_buy)
    sell_sim = cosine_sim(masked_test, masked_sell)
    return "BUY" if buy_sim > sell_sim else "SELL"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--n", type=int, default=500)
    parser.add_argument("--label", default="label_oracle_10")
    parser.add_argument("--vol-threshold", type=float, default=0.002)
    args = parser.parse_args()

    log("=" * 75)
    log("ALGEBRA GAUNTLET v3: [0,1] normalization + smart classifiers")
    log("=" * 75)

    candles, zscore_stats = load_data(args)
    log(f"Loaded {len(candles):,} candles")

    # Sample
    rng = np.random.default_rng(42)
    buy_idx = [i for i in range(WINDOW - 1, len(candles)) if candles[i][args.label] == "BUY"]
    sell_idx = [i for i in range(WINDOW - 1, len(candles)) if candles[i][args.label] == "SELL"]
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

    # [0,1] normalization stats from training data
    all_train_idx = train_buy_idx + train_sell_idx
    minmax_stats = compute_minmax(candles, FEATURES, all_train_idx)

    client = HolonClient(dimensions=DIM)

    # ===================================================================
    # PART A: Raw feature baseline (no Holon)
    # ===================================================================
    log("")
    log("=" * 75)
    log("PART A: Raw feature baseline (no Holon — raw [0,1] feature k-NN)")
    log("=" * 75)

    def feats_01(idx):
        c = candles[idx]
        return np.array([norm_01(float(c.get(f, 0.0) or 0.0), minmax_stats[f]) for f in FEATURES])

    train_buy_raw = [feats_01(i) for i in train_buy_idx]
    train_sell_raw = [feats_01(i) for i in train_sell_idx]
    test_buy_raw = [feats_01(i) for i in test_buy_idx]
    test_sell_raw = [feats_01(i) for i in test_sell_idx]

    # Raw cosine k-NN
    for k in [1, 5, 11, 21]:
        def make_knn(kk):
            def classify(v):
                return knn_classifier(v, train_buy_raw, train_sell_raw, k=kk)
            return classify
        evaluate(f"Raw features: k-NN (k={k})", test_buy_raw, test_sell_raw, make_knn(k))

    # Raw euclidean k-NN
    def eucl_knn(test_vec, train_buy, train_sell, k=5):
        all_dists = []
        for v in train_buy:
            all_dists.append((np.linalg.norm(test_vec - v), "BUY"))
        for v in train_sell:
            all_dists.append((np.linalg.norm(test_vec - v), "SELL"))
        all_dists.sort(key=lambda x: x[0])
        top_k = all_dists[:k]
        buy_votes = sum(1 for _, l in top_k if l == "BUY")
        return "BUY" if buy_votes > k // 2 else "SELL"

    for k in [5, 11]:
        def make_eknn(kk):
            def classify(v):
                return eucl_knn(v, train_buy_raw, train_sell_raw, k=kk)
            return classify
        evaluate(f"Raw features: Euclidean k-NN (k={k})", test_buy_raw, test_sell_raw, make_eknn(k))

    # Raw centroid
    buy_centroid_raw = np.mean(train_buy_raw, axis=0)
    sell_centroid_raw = np.mean(train_sell_raw, axis=0)
    log(f"  Raw centroid distance: {np.linalg.norm(buy_centroid_raw - sell_centroid_raw):.4f}")
    evaluate("Raw features: Centroid (Euclidean)",
             test_buy_raw, test_sell_raw,
             lambda v: "BUY" if np.linalg.norm(v - buy_centroid_raw) < np.linalg.norm(v - sell_centroid_raw) else "SELL")

    # ===================================================================
    # PART B: Thermometer encoding — [0,1] → fraction of +1 dims
    # ===================================================================
    log("")
    log("=" * 75)
    log("PART B: Thermometer encoding (value→fraction of +1 dims)")
    log("=" * 75)

    def encode_thermo(idx):
        c = candles[idx]
        vecs = []
        for fi, feat in enumerate(FEATURES):
            raw = float(c.get(feat, 0.0) or 0.0)
            v01 = norm_01(raw, minmax_stats[feat])
            role = client.encoder.vector_manager.get_vector(feat)
            filler = thermometer_encode(v01, DIM, seed=fi * 1000 + 42)
            vecs.append(bind(role, filler))
        return bundle(vecs)

    t0 = time.time()
    train_buy_thermo = [encode_thermo(i) for i in train_buy_idx]
    train_sell_thermo = [encode_thermo(i) for i in train_sell_idx]
    test_buy_thermo = [encode_thermo(i) for i in test_buy_idx]
    test_sell_thermo = [encode_thermo(i) for i in test_sell_idx]
    log(f"Encoded thermometer in {time.time() - t0:.1f}s")

    bp_t = prototype(train_buy_thermo)
    sp_t = prototype(train_sell_thermo)
    sim_t = cosine_sim(bp_t, sp_t)
    log(f"Thermometer proto sim: {sim_t:.4f}")

    # Soft centroids (mean of float vectors)
    buy_cent_t = np.mean([v.astype(float) for v in train_buy_thermo], axis=0)
    sell_cent_t = np.mean([v.astype(float) for v in train_sell_thermo], axis=0)
    cent_sim = cosine_sim(buy_cent_t, sell_cent_t)
    log(f"Thermometer centroid sim: {cent_sim:.4f}")

    evaluate("Thermo: Prototype",
             test_buy_thermo, test_sell_thermo,
             lambda v: "BUY" if cosine_sim(v, bp_t) > cosine_sim(v, sp_t) else "SELL")

    evaluate("Thermo: Soft centroid",
             test_buy_thermo, test_sell_thermo,
             lambda v: centroid_classifier(v, buy_cent_t, sell_cent_t))

    # Contrast vector
    cv_t = difference(sp_t, bp_t)
    evaluate("Thermo: Contrast direct",
             test_buy_thermo, test_sell_thermo,
             lambda v: "BUY" if cosine_sim(v, cv_t) > 0 else "SELL")

    # Negate + Grover
    mp_t = prototype(train_buy_thermo + train_sell_thermo)
    bp_t_c = negate(bp_t, mp_t)
    sp_t_c = negate(sp_t, mp_t)
    bp_t_cg = grover_amplify(bp_t_c, sp_t_c, iterations=2)
    sp_t_cg = grover_amplify(sp_t_c, bp_t_c, iterations=2)

    def classify_thermo_negate_grover(v):
        cleaned = negate(v, mp_t)
        return "BUY" if cosine_sim(cleaned, bp_t_cg) > cosine_sim(cleaned, sp_t_cg) else "SELL"
    evaluate("Thermo: Negate + Grover", test_buy_thermo, test_sell_thermo, classify_thermo_negate_grover)

    # Masked (discriminative dims from similarity profile)
    sp_profile = similarity_profile(bp_t, sp_t)
    disagreement = (sp_profile < 0).astype(float)
    n_disagree = int(np.sum(disagreement))
    log(f"  {n_disagree} disagreeing dims out of {DIM}")

    evaluate("Thermo: Masked (disagreement dims only)",
             test_buy_thermo, test_sell_thermo,
             lambda v: masked_classifier(v, bp_t, sp_t, disagreement))

    # k-NN in HDC space
    for k in [5, 11, 21]:
        def make_thermo_knn(kk):
            def classify(v):
                return knn_classifier(v, train_buy_thermo, train_sell_thermo, k=kk)
            return classify
        evaluate(f"Thermo: k-NN (k={k})", test_buy_thermo, test_sell_thermo, make_thermo_knn(k))

    # Mean similarity
    evaluate("Thermo: Mean similarity",
             test_buy_thermo, test_sell_thermo,
             lambda v: mean_sim_classifier(v, train_buy_thermo, train_sell_thermo))

    # Bundle with confidence (use margins as weights)
    bv_t, bc_t = bundle_with_confidence(train_buy_thermo)
    sv_t, sc_t = bundle_with_confidence(train_sell_thermo)
    def classify_thermo_conf(v):
        bs = float(np.sum(v.astype(float) * bv_t.astype(float) * bc_t))
        ss = float(np.sum(v.astype(float) * sv_t.astype(float) * sc_t))
        return "BUY" if bs > ss else "SELL"
    evaluate("Thermo: Bundle with confidence", test_buy_thermo, test_sell_thermo, classify_thermo_conf)

    # ===================================================================
    # PART C: Walkable-encoded HDC with [0,1] + better scale
    # ===================================================================
    log("")
    log("=" * 75)
    log("PART C: Walkable HDC [0,1] normalization — scale sweep")
    log("=" * 75)

    for scale in [0.01, 0.05, 0.1, 0.5]:
        def encode_walkable_01(idx, sc=scale):
            c = candles[idx]
            data = {}
            for feat in FEATURES:
                raw = float(c.get(feat, 0.0) or 0.0)
                v01 = norm_01(raw, minmax_stats[feat])
                data[feat] = LinearScale(v01, scale=sc)
            return client.encoder.encode_walkable(data)

        train_buy_v = [encode_walkable_01(i) for i in train_buy_idx]
        train_sell_v = [encode_walkable_01(i) for i in train_sell_idx]
        test_buy_v = [encode_walkable_01(i) for i in test_buy_idx]
        test_sell_v = [encode_walkable_01(i) for i in test_sell_idx]

        bp_v = prototype(train_buy_v)
        sp_v = prototype(train_sell_v)
        sim_v = cosine_sim(bp_v, sp_v)

        buy_cent_v = np.mean([v.astype(float) for v in train_buy_v], axis=0)
        sell_cent_v = np.mean([v.astype(float) for v in train_sell_v], axis=0)
        cent_sim_v = cosine_sim(buy_cent_v, sell_cent_v)

        # Prototype
        correct = sum(1 for v in test_buy_v if cosine_sim(v, bp_v) > cosine_sim(v, sp_v))
        correct += sum(1 for v in test_sell_v if cosine_sim(v, sp_v) > cosine_sim(v, bp_v))
        acc_p = correct / (len(test_buy_v) + len(test_sell_v)) * 100

        # Centroid
        correct_c = sum(1 for v in test_buy_v if cosine_sim(v, buy_cent_v) > cosine_sim(v, sell_cent_v))
        correct_c += sum(1 for v in test_sell_v if cosine_sim(v, sell_cent_v) > cosine_sim(v, buy_cent_v))
        acc_c = correct_c / (len(test_buy_v) + len(test_sell_v)) * 100

        log(f"  scale={scale:<6.3f} psim={sim_v:.4f} csim={cent_sim_v:.4f} proto={acc_p:>5.1f}% cent={acc_c:>5.1f}%")

    # ===================================================================
    # PART D: Temporal walkable [0,1] + thermometer (12-candle window)
    # ===================================================================
    log("")
    log("=" * 75)
    log("PART D: Temporal window + thermometer encoding")
    log("=" * 75)

    def encode_temporal_thermo(idx):
        """Encode 12-candle window: for each timestep, thermometer-encode features,
        then bind with position vector and bundle across time."""
        window = candles[max(0, idx - WINDOW + 1): idx + 1]
        if len(window) < WINDOW:
            window = [window[0]] * (WINDOW - len(window)) + list(window)

        time_vecs = []
        for t, c in enumerate(window):
            feat_vecs = []
            for fi, feat in enumerate(FEATURES):
                raw = float(c.get(feat, 0.0) or 0.0)
                v01 = norm_01(raw, minmax_stats[feat])
                role = client.encoder.vector_manager.get_vector(feat)
                filler = thermometer_encode(v01, DIM, seed=fi * 1000 + 42)
                feat_vecs.append(bind(role, filler))
            snapshot = bundle(feat_vecs)
            pos = client.encoder.vector_manager.get_position_vector(t)
            time_vecs.append(bind(snapshot, pos))
        return bundle(time_vecs)

    t0 = time.time()
    train_buy_tt = [encode_temporal_thermo(i) for i in train_buy_idx]
    train_sell_tt = [encode_temporal_thermo(i) for i in train_sell_idx]
    test_buy_tt = [encode_temporal_thermo(i) for i in test_buy_idx]
    test_sell_tt = [encode_temporal_thermo(i) for i in test_sell_idx]
    log(f"Encoded temporal-thermo in {time.time() - t0:.1f}s")

    bp_tt = prototype(train_buy_tt)
    sp_tt = prototype(train_sell_tt)
    log(f"Temporal-thermo proto sim: {cosine_sim(bp_tt, sp_tt):.4f}")

    buy_cent_tt = np.mean([v.astype(float) for v in train_buy_tt], axis=0)
    sell_cent_tt = np.mean([v.astype(float) for v in train_sell_tt], axis=0)
    log(f"Temporal-thermo centroid sim: {cosine_sim(buy_cent_tt, sell_cent_tt):.4f}")

    evaluate("TempThermo: Prototype",
             test_buy_tt, test_sell_tt,
             lambda v: "BUY" if cosine_sim(v, bp_tt) > cosine_sim(v, sp_tt) else "SELL")

    evaluate("TempThermo: Soft centroid",
             test_buy_tt, test_sell_tt,
             lambda v: centroid_classifier(v, buy_cent_tt, sell_cent_tt))

    mp_tt = prototype(train_buy_tt + train_sell_tt)
    bp_tt_c = negate(bp_tt, mp_tt)
    sp_tt_c = negate(sp_tt, mp_tt)
    bp_tt_cg = grover_amplify(bp_tt_c, sp_tt_c, iterations=2)
    sp_tt_cg = grover_amplify(sp_tt_c, bp_tt_c, iterations=2)

    def classify_tt_negate_grover(v):
        cleaned = negate(v, mp_tt)
        return "BUY" if cosine_sim(cleaned, bp_tt_cg) > cosine_sim(cleaned, sp_tt_cg) else "SELL"
    evaluate("TempThermo: Negate + Grover", test_buy_tt, test_sell_tt, classify_tt_negate_grover)

    for k in [5, 11]:
        def make_tt_knn(kk):
            def classify(v):
                return knn_classifier(v, train_buy_tt, train_sell_tt, k=kk)
            return classify
        evaluate(f"TempThermo: k-NN (k={k})", test_buy_tt, test_sell_tt, make_tt_knn(k))

    # ===================================================================
    # PART E: Feature importance — which features encode directional signal?
    # ===================================================================
    log("")
    log("=" * 75)
    log("PART E: Per-feature thermometer separation")
    log("=" * 75)

    feat_results = []
    for fi, feat in enumerate(FEATURES):
        buy_vals = [norm_01(float(candles[i].get(feat, 0.0) or 0.0), minmax_stats[feat]) for i in train_buy_idx]
        sell_vals = [norm_01(float(candles[i].get(feat, 0.0) or 0.0), minmax_stats[feat]) for i in train_sell_idx]

        buy_mean = np.mean(buy_vals)
        sell_mean = np.mean(sell_vals)
        diff = buy_mean - sell_mean

        # Thermometer encode and prototype
        buy_tvecs = [thermometer_encode(v, DIM, seed=fi * 1000 + 42) for v in buy_vals]
        sell_tvecs = [thermometer_encode(v, DIM, seed=fi * 1000 + 42) for v in sell_vals]
        bp_f = prototype(buy_tvecs)
        sp_f = prototype(sell_tvecs)
        sim_f = cosine_sim(bp_f, sp_f)

        feat_results.append((feat, buy_mean, sell_mean, diff, sim_f))

    feat_results.sort(key=lambda x: x[4])  # sort by similarity (lowest first = most discriminative)
    for feat, bm, sm, diff, sim in feat_results:
        bar = "█" * int((1.0 - sim) * 100) if sim < 1.0 else ""
        log(f"  {feat:<25s} B={bm:.3f} S={sm:.3f} Δ={diff:+.3f} sim={sim:.4f} {bar}")

    # ===================================================================
    # PART F: Selected discriminative features only
    # ===================================================================
    log("")
    log("=" * 75)
    log("PART F: Top discriminative features only")
    log("=" * 75)

    # Take features where thermometer prototype sim < 0.999
    disc_feats = [f for f, _, _, _, s in feat_results if s < 0.999]
    log(f"Discriminative features (sim < 0.999): {disc_feats}")

    if len(disc_feats) >= 2:
        def encode_disc_thermo(idx):
            c = candles[idx]
            vecs = []
            for fi, feat in enumerate(disc_feats):
                fi_global = FEATURES.index(feat) if feat in FEATURES else fi
                raw = float(c.get(feat, 0.0) or 0.0)
                v01 = norm_01(raw, minmax_stats[feat])
                role = client.encoder.vector_manager.get_vector(feat)
                filler = thermometer_encode(v01, DIM, seed=fi_global * 1000 + 42)
                vecs.append(bind(role, filler))
            return bundle(vecs)

        train_buy_disc = [encode_disc_thermo(i) for i in train_buy_idx]
        train_sell_disc = [encode_disc_thermo(i) for i in train_sell_idx]
        test_buy_disc = [encode_disc_thermo(i) for i in test_buy_idx]
        test_sell_disc = [encode_disc_thermo(i) for i in test_sell_idx]

        bp_disc = prototype(train_buy_disc)
        sp_disc = prototype(train_sell_disc)
        log(f"Disc proto sim: {cosine_sim(bp_disc, sp_disc):.4f}")

        evaluate("Disc: Prototype",
                 test_buy_disc, test_sell_disc,
                 lambda v: "BUY" if cosine_sim(v, bp_disc) > cosine_sim(v, sp_disc) else "SELL")

        buy_cent_disc = np.mean([v.astype(float) for v in train_buy_disc], axis=0)
        sell_cent_disc = np.mean([v.astype(float) for v in train_sell_disc], axis=0)
        evaluate("Disc: Soft centroid",
                 test_buy_disc, test_sell_disc,
                 lambda v: centroid_classifier(v, buy_cent_disc, sell_cent_disc))

        for k in [5, 11]:
            def make_disc_knn(kk):
                def classify(v):
                    return knn_classifier(v, train_buy_disc, train_sell_disc, k=kk)
                return classify
            evaluate(f"Disc: k-NN (k={k})", test_buy_disc, test_sell_disc, make_disc_knn(k))
    else:
        log("  No discriminative features found — all features identical for BUY/SELL")

    # ===================================================================
    # PART G: Does MORE data help? (increase sample size)
    # ===================================================================
    log("")
    log("=" * 75)
    log("PART G: Sample size sensitivity (thermometer, prototype)")
    log("=" * 75)

    for n_size in [100, 250, 500, 1000, 2000]:
        if n_size > n_per:
            # Re-sample with more data
            buy_idx_all = [i for i in range(WINDOW - 1, len(candles)) if candles[i][args.label] == "BUY"]
            sell_idx_all = [i for i in range(WINDOW - 1, len(candles)) if candles[i][args.label] == "SELL"]
            actual_n = min(n_size, len(buy_idx_all), len(sell_idx_all))
            rng2 = np.random.default_rng(42)
            buy_s = list(rng2.choice(buy_idx_all, actual_n, replace=False))
            sell_s = list(rng2.choice(sell_idx_all, actual_n, replace=False))
            rng2.shuffle(buy_s)
            rng2.shuffle(sell_s)
            sb2 = int(actual_n * 0.8)
            tr_b = buy_s[:sb2]
            te_b = buy_s[sb2:]
            tr_s = sell_s[:sb2]
            te_s = sell_s[sb2:]
        else:
            tr_b = train_buy_idx[:int(n_size * 0.8)]
            te_b = test_buy_idx[:int(n_size * 0.2)]
            tr_s = train_sell_idx[:int(n_size * 0.8)]
            te_s = test_sell_idx[:int(n_size * 0.2)]

        # Quick thermometer encode
        def enc(idx):
            c = candles[idx]
            vecs = []
            for fi, feat in enumerate(FEATURES):
                raw = float(c.get(feat, 0.0) or 0.0)
                v01 = norm_01(raw, minmax_stats[feat])
                role = client.encoder.vector_manager.get_vector(feat)
                filler = thermometer_encode(v01, DIM, seed=fi * 1000 + 42)
                vecs.append(bind(role, filler))
            return bundle(vecs)

        tb_v = [enc(i) for i in tr_b]
        ts_v = [enc(i) for i in tr_s]
        xb_v = [enc(i) for i in te_b]
        xs_v = [enc(i) for i in te_s]

        bp_g = prototype(tb_v)
        sp_g = prototype(ts_v)
        sim_g = cosine_sim(bp_g, sp_g)

        # Centroid
        buy_cent_g = np.mean([v.astype(float) for v in tb_v], axis=0)
        sell_cent_g = np.mean([v.astype(float) for v in ts_v], axis=0)

        correct_p = sum(1 for v in xb_v if cosine_sim(v, bp_g) > cosine_sim(v, sp_g))
        correct_p += sum(1 for v in xs_v if cosine_sim(v, sp_g) > cosine_sim(v, bp_g))
        acc_p = correct_p / max(1, len(xb_v) + len(xs_v)) * 100

        correct_c = sum(1 for v in xb_v if cosine_sim(v, buy_cent_g) > cosine_sim(v, sell_cent_g))
        correct_c += sum(1 for v in xs_v if cosine_sim(v, sell_cent_g) > cosine_sim(v, buy_cent_g))
        acc_c = correct_c / max(1, len(xb_v) + len(xs_v)) * 100

        log(f"  N={n_size:<5d} train={len(tr_b)+len(tr_s):<5d} test={len(te_b)+len(te_s):<4d} "
            f"psim={sim_g:.4f} proto={acc_p:>5.1f}% cent={acc_c:>5.1f}%")

    log("")
    log("=" * 75)
    log("DONE — looking for >55% anywhere = signal exists")
    log("=" * 75)


if __name__ == "__main__":
    main()
