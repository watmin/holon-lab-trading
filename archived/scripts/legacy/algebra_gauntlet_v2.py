"""Algebra Gauntlet v2: Fix the scale parameter + test encoding strategies.

Key insight: LinearScale(scale=1000) on z-scored [-3,3] features produces
nearly identical vectors for different values. The positional encoding can't
distinguish values 0.2 apart when scale=1000. We need scale=1-10.

Tests:
 A) Scale sweep (1, 5, 10, 50, 100, 1000) — measure prototype separation
 B) Flat encoding (single candle, no window) vs walkable spread
 C) Best algebra techniques from v1 at optimal scale
 D) Feature-pair interaction binding

Usage:
    ./scripts/run_with_venv.sh python holon-lab-trading/scripts/algebra_gauntlet_v2.py
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


def cosine_sim(a: np.ndarray, b: np.ndarray) -> float:
    a = a.astype(float)
    b = b.astype(float)
    na = np.linalg.norm(a)
    nb = np.linalg.norm(b)
    if na < 1e-10 or nb < 1e-10:
        return 0.0
    return float(np.dot(a, b) / (na * nb))


def load_data(args):
    """Load candle data with norm stats."""
    conn = sqlite3.connect(str(DB_PATH))

    rows = conn.execute("SELECT * FROM feature_stats").fetchall()
    norm_stats = {}
    for r in rows:
        norm_stats[r[0]] = {"mean": r[1], "std": r[2]}

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
    return candles, norm_stats


def sample_indices(candles, label_col, n_per, min_idx=0):
    """Sample balanced indices."""
    rng = np.random.default_rng(42)
    buy_idx = [i for i in range(min_idx, len(candles)) if candles[i][label_col] == "BUY"]
    sell_idx = [i for i in range(min_idx, len(candles)) if candles[i][label_col] == "SELL"]
    n = min(n_per, len(buy_idx), len(sell_idx))
    return (
        sorted(list(rng.choice(buy_idx, n, replace=False))),
        sorted(list(rng.choice(sell_idx, n, replace=False))),
        n,
    )


def normalize(value: float, feat_stats: dict) -> float:
    std = feat_stats.get("std")
    mean = feat_stats.get("mean")
    if std is None or mean is None or std < 1e-10:
        return 0.0
    return (value - mean) / std


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
    log(f"  {name:<50s} {acc:>5.1f}%  (B:{ba:.0f}% S:{sa:.0f}%)  N={total}")
    return acc


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--n", type=int, default=500)
    parser.add_argument("--label", default="label_oracle_10")
    parser.add_argument("--vol-threshold", type=float, default=0.002)
    args = parser.parse_args()

    log("=" * 75)
    log("ALGEBRA GAUNTLET v2: Fix scale + test strategies")
    log("=" * 75)

    candles, norm_stats = load_data(args)
    log(f"Loaded {len(candles):,} candles")

    buy_indices, sell_indices, n_per = sample_indices(
        candles, args.label, args.n, min_idx=WINDOW - 1
    )
    log(f"Sampled {n_per} per class")

    # 80/20 split
    rng = np.random.default_rng(42)
    rng.shuffle(buy_indices)
    rng.shuffle(sell_indices)
    sb = int(n_per * 0.8)
    ss = int(n_per * 0.8)
    train_buy_idx, test_buy_idx = buy_indices[:sb], buy_indices[sb:]
    train_sell_idx, test_sell_idx = sell_indices[:ss], sell_indices[ss:]
    log(f"Train: {len(train_buy_idx)} BUY + {len(train_sell_idx)} SELL")
    log(f"Test:  {len(test_buy_idx)} BUY + {len(test_sell_idx)} SELL")

    client = HolonClient(dimensions=DIM)

    # ===================================================================
    # PART A: Scale sweep — how does scale affect prototype separation?
    # ===================================================================
    log("")
    log("=" * 75)
    log("PART A: Scale sweep (single-candle flat encoding)")
    log("=" * 75)
    log("Encoding single-candle features at different LinearScale settings...")

    for scale in [0.1, 0.5, 1.0, 2.0, 5.0, 10.0, 50.0, 100.0, 1000.0]:
        def encode_flat(idx, sc=scale):
            c = candles[idx]
            data = {}
            for feat in FEATURES:
                raw = c.get(feat, 0.0) or 0.0
                data[feat] = LinearScale(
                    normalize(float(raw), norm_stats.get(feat, {})),
                    scale=sc,
                )
            return client.encoder.encode_walkable(data)

        train_buy_vecs = [encode_flat(i) for i in train_buy_idx]
        train_sell_vecs = [encode_flat(i) for i in train_sell_idx]
        test_buy_vecs = [encode_flat(i) for i in test_buy_idx]
        test_sell_vecs = [encode_flat(i) for i in test_sell_idx]

        bp = prototype(train_buy_vecs)
        sp = prototype(train_sell_vecs)
        mp = prototype(train_buy_vecs + train_sell_vecs)
        sim = cosine_sim(bp, sp)

        cv = difference(sp, bp)
        cv_norm = np.linalg.norm(cv.astype(float))

        # Prototype accuracy
        def classify_proto(v, _bp=bp, _sp=sp):
            return "BUY" if cosine_sim(v, _bp) > cosine_sim(v, _sp) else "SELL"

        correct = sum(1 for v in test_buy_vecs if classify_proto(v) == "BUY")
        correct += sum(1 for v in test_sell_vecs if classify_proto(v) == "SELL")
        total = len(test_buy_vecs) + len(test_sell_vecs)
        acc = correct / total * 100

        # Negate shared context
        bp_clean = negate(bp, mp)
        sp_clean = negate(sp, mp)
        def classify_negate(v, _mp=mp, _bpc=bp_clean, _spc=sp_clean):
            cleaned = negate(v, _mp)
            return "BUY" if cosine_sim(cleaned, _bpc) > cosine_sim(cleaned, _spc) else "SELL"

        correct_n = sum(1 for v in test_buy_vecs if classify_negate(v) == "BUY")
        correct_n += sum(1 for v in test_sell_vecs if classify_negate(v) == "SELL")
        acc_n = correct_n / total * 100

        # Contrast direct
        def classify_contrast(v, _cv=cv):
            return "BUY" if cosine_sim(v, _cv) > 0 else "SELL"

        correct_c = sum(1 for v in test_buy_vecs if classify_contrast(v) == "BUY")
        correct_c += sum(1 for v in test_sell_vecs if classify_contrast(v) == "SELL")
        acc_c = correct_c / total * 100

        log(f"  scale={scale:<8.1f} proto_sim={sim:.4f} cv_norm={cv_norm:>6.1f} | "
            f"proto_acc={acc:>5.1f}% negate_acc={acc_n:>5.1f}% contrast_acc={acc_c:>5.1f}%")

    # ===================================================================
    # PART B: Best scale — full technique battery
    # ===================================================================
    log("")
    log("=" * 75)
    log("PART B: Full technique battery at scale=1.0 (flat encoding)")
    log("=" * 75)

    BEST_SCALE = 1.0

    def encode_best(idx):
        c = candles[idx]
        data = {}
        for feat in FEATURES:
            raw = c.get(feat, 0.0) or 0.0
            data[feat] = LinearScale(
                normalize(float(raw), norm_stats.get(feat, {})),
                scale=BEST_SCALE,
            )
        return client.encoder.encode_walkable(data)

    train_buy_vecs = [encode_best(i) for i in train_buy_idx]
    train_sell_vecs = [encode_best(i) for i in train_sell_idx]
    test_buy_vecs = [encode_best(i) for i in test_buy_idx]
    test_sell_vecs = [encode_best(i) for i in test_sell_idx]

    bp = prototype(train_buy_vecs)
    sp = prototype(train_sell_vecs)
    mp = prototype(train_buy_vecs + train_sell_vecs)
    cv = difference(sp, bp)

    log(f"Proto sim: {cosine_sim(bp, sp):.4f}")

    # 1. Prototype
    evaluate("1. Prototype similarity",
             test_buy_vecs, test_sell_vecs,
             lambda v: "BUY" if cosine_sim(v, bp) > cosine_sim(v, sp) else "SELL")

    # 2. Contrast direct
    evaluate("2. Contrast vector (direct)",
             test_buy_vecs, test_sell_vecs,
             lambda v: "BUY" if cosine_sim(v, cv) > 0 else "SELL")

    # 3. Negate shared
    bp_clean = negate(bp, mp)
    sp_clean = negate(sp, mp)
    def classify_negate(v):
        cleaned = negate(v, mp)
        return "BUY" if cosine_sim(cleaned, bp_clean) > cosine_sim(cleaned, sp_clean) else "SELL"
    evaluate("3. Negate shared context", test_buy_vecs, test_sell_vecs, classify_negate)

    # 4. Reject shared
    def classify_reject(v):
        sub = [mp]
        cleaned = reject(v, sub)
        return "BUY" if cosine_sim(cleaned, reject(bp, sub)) > cosine_sim(cleaned, reject(sp, sub)) else "SELL"
    evaluate("4. Reject shared subspace", test_buy_vecs, test_sell_vecs, classify_reject)

    # 5. Amplify contrast
    for strength in [1.0, 2.0, 5.0]:
        def make_amp(st):
            def classify(v):
                a = amplify(v, cv, strength=st)
                return "BUY" if cosine_sim(a, bp) > cosine_sim(a, sp) else "SELL"
            return classify
        evaluate(f"5. Amplify contrast (str={strength})", test_buy_vecs, test_sell_vecs, make_amp(strength))

    # 6. Resonance
    def classify_resonance(v):
        rb = resonance(v, bp)
        rs = resonance(v, sp)
        return "BUY" if float(np.sum(rb.astype(float))) > float(np.sum(rs.astype(float))) else "SELL"
    evaluate("6. Resonance filtering", test_buy_vecs, test_sell_vecs, classify_resonance)

    # 7. Grover amplify
    grover_bp = grover_amplify(bp, sp, iterations=2)
    grover_sp = grover_amplify(sp, bp, iterations=2)
    evaluate("7. Grover amplify",
             test_buy_vecs, test_sell_vecs,
             lambda v: "BUY" if cosine_sim(v, grover_bp) > cosine_sim(v, grover_sp) else "SELL")

    # 8. Similarity profile
    def classify_simprof(v):
        bp_agree = float(np.sum(similarity_profile(v, bp) > 0))
        sp_agree = float(np.sum(similarity_profile(v, sp) > 0))
        return "BUY" if bp_agree > sp_agree else "SELL"
    evaluate("8. Similarity profile", test_buy_vecs, test_sell_vecs, classify_simprof)

    # 9. Bundle with confidence
    bv, bc = bundle_with_confidence(train_buy_vecs)
    sv, sc = bundle_with_confidence(train_sell_vecs)
    def classify_conf(v):
        bs = float(np.sum(v.astype(float) * bv.astype(float) * bc))
        ss_score = float(np.sum(v.astype(float) * sv.astype(float) * sc))
        return "BUY" if bs > ss_score else "SELL"
    evaluate("9. Bundle with confidence", test_buy_vecs, test_sell_vecs, classify_conf)

    # 10. Negate + Grover
    bp_clean_g = grover_amplify(bp_clean, sp_clean, iterations=2)
    sp_clean_g = grover_amplify(sp_clean, bp_clean, iterations=2)
    def classify_negate_grover(v):
        cleaned = negate(v, mp)
        return "BUY" if cosine_sim(cleaned, bp_clean_g) > cosine_sim(cleaned, sp_clean_g) else "SELL"
    evaluate("10. Negate + Grover", test_buy_vecs, test_sell_vecs, classify_negate_grover)

    # ===================================================================
    # PART C: Striped encoding at optimal scale
    # ===================================================================
    log("")
    log("=" * 75)
    log("PART C: Striped encoding at scale=1.0 + walkable window")
    log("=" * 75)

    def encode_striped(idx, scale=BEST_SCALE):
        window = candles[idx - WINDOW + 1: idx + 1]
        walkable = {}
        for feat in FEATURES:
            vals = []
            for r in window:
                raw = r.get(feat, 0.0) or 0.0
                vals.append(LinearScale(normalize(float(raw), norm_stats.get(feat, {})), scale=scale))
            walkable[feat] = WalkableSpread(vals)
        return client.encoder.encode_walkable_striped(walkable, n_stripes=N_STRIPES)

    t0 = time.time()
    train_buy_striped = [encode_striped(i) for i in train_buy_idx]
    train_sell_striped = [encode_striped(i) for i in train_sell_idx]
    test_buy_striped = [encode_striped(i) for i in test_buy_idx]
    test_sell_striped = [encode_striped(i) for i in test_sell_idx]
    log(f"Encoded {len(train_buy_idx) + len(train_sell_idx) + len(test_buy_idx) + len(test_sell_idx)} striped in {time.time()-t0:.1f}s")

    # Per-stripe prototype similarity
    stripe_sims = []
    stripe_buy_protos = []
    stripe_sell_protos = []
    stripe_market_protos = []
    stripe_contrast = []

    for s in range(N_STRIPES):
        bvs = [v[s] for v in train_buy_striped]
        svs = [v[s] for v in train_sell_striped]
        bp_s = prototype(bvs)
        sp_s = prototype(svs)
        mp_s = prototype(bvs + svs)
        cv_s = difference(sp_s, bp_s)
        stripe_buy_protos.append(bp_s)
        stripe_sell_protos.append(sp_s)
        stripe_market_protos.append(mp_s)
        stripe_contrast.append(cv_s)
        stripe_sims.append(cosine_sim(bp_s, sp_s))

    log(f"Stripe proto sim: mean={np.mean(stripe_sims):.4f}, min={np.min(stripe_sims):.4f}, max={np.max(stripe_sims):.4f}")

    # Striped prototype
    def classify_striped_proto(stripes):
        buy_sim = sum(cosine_sim(stripes[s], stripe_buy_protos[s]) for s in range(N_STRIPES))
        sell_sim = sum(cosine_sim(stripes[s], stripe_sell_protos[s]) for s in range(N_STRIPES))
        return "BUY" if buy_sim > sell_sim else "SELL"
    evaluate("Striped: Prototype", test_buy_striped, test_sell_striped, classify_striped_proto)

    # Striped contrast
    def classify_striped_contrast(stripes):
        score = sum(cosine_sim(stripes[s], stripe_contrast[s]) for s in range(N_STRIPES))
        return "BUY" if score > 0 else "SELL"
    evaluate("Striped: Contrast", test_buy_striped, test_sell_striped, classify_striped_contrast)

    # Striped negate
    def classify_striped_negate(stripes):
        buy_sim = sell_sim = 0
        for s in range(N_STRIPES):
            cleaned = negate(stripes[s], stripe_market_protos[s])
            bp_c = negate(stripe_buy_protos[s], stripe_market_protos[s])
            sp_c = negate(stripe_sell_protos[s], stripe_market_protos[s])
            buy_sim += cosine_sim(cleaned, bp_c)
            sell_sim += cosine_sim(cleaned, sp_c)
        return "BUY" if buy_sim > sell_sim else "SELL"
    evaluate("Striped: Negate shared", test_buy_striped, test_sell_striped, classify_striped_negate)

    # Striped subspace residual
    buy_sub = StripedSubspace(dim=DIM, k=K, n_stripes=N_STRIPES)
    for stripes in train_buy_striped:
        buy_sub.update(stripes)
    sell_sub = StripedSubspace(dim=DIM, k=K, n_stripes=N_STRIPES)
    for stripes in train_sell_striped:
        sell_sub.update(stripes)

    def classify_striped_subspace(stripes):
        return "BUY" if buy_sub.residual(stripes) < sell_sub.residual(stripes) else "SELL"
    evaluate("Striped: Subspace residual", test_buy_striped, test_sell_striped, classify_striped_subspace)

    # ===================================================================
    # PART D: Interaction binding
    # ===================================================================
    log("")
    log("=" * 75)
    log("PART D: Interaction binding (feature pairs)")
    log("=" * 75)

    INTERACTION_PAIRS = [
        ("rsi", "trend_consistency_24"),
        ("dmi_plus", "dmi_minus"),
        ("sma_cross_50_200", "sma200_r"),
        ("macd_line_r", "ema_cross_9_21"),
        ("vol_accel", "atr_roc_6"),
        ("bb_pos", "kelt_pos"),
        ("dow_sin", "hour_cos"),
        ("tf_4h_body", "tf_4h_close_pos"),
        ("vol_up_ratio_12", "obv_slope_12"),
        ("range_pos_48", "ema100_r"),
    ]

    def encode_with_interactions(idx, scale=BEST_SCALE):
        c = candles[idx]

        # Base features
        feat_vecs = {}
        for feat in FEATURES:
            raw = c.get(feat, 0.0) or 0.0
            nv = normalize(float(raw), norm_stats.get(feat, {}))
            data = {feat: LinearScale(nv, scale=scale)}
            feat_vecs[feat] = client.encoder.encode_walkable(data)

        # Individual features bundled
        base = bundle(list(feat_vecs.values()))

        # Interaction bindings
        interactions = []
        for fa, fb in INTERACTION_PAIRS:
            if fa in feat_vecs and fb in feat_vecs:
                interactions.append(bind(feat_vecs[fa], feat_vecs[fb]))

        if interactions:
            return bundle([base] + interactions)
        return base

    train_buy_int = [encode_with_interactions(i) for i in train_buy_idx]
    train_sell_int = [encode_with_interactions(i) for i in train_sell_idx]
    test_buy_int = [encode_with_interactions(i) for i in test_buy_idx]
    test_sell_int = [encode_with_interactions(i) for i in test_sell_idx]

    bp_int = prototype(train_buy_int)
    sp_int = prototype(train_sell_int)
    mp_int = prototype(train_buy_int + train_sell_int)
    cv_int = difference(sp_int, bp_int)
    log(f"Interaction proto sim: {cosine_sim(bp_int, sp_int):.4f}")

    evaluate("Interaction: Prototype",
             test_buy_int, test_sell_int,
             lambda v: "BUY" if cosine_sim(v, bp_int) > cosine_sim(v, sp_int) else "SELL")

    evaluate("Interaction: Contrast",
             test_buy_int, test_sell_int,
             lambda v: "BUY" if cosine_sim(v, cv_int) > 0 else "SELL")

    bp_int_c = negate(bp_int, mp_int)
    sp_int_c = negate(sp_int, mp_int)
    def classify_int_negate(v):
        cleaned = negate(v, mp_int)
        return "BUY" if cosine_sim(cleaned, bp_int_c) > cosine_sim(cleaned, sp_int_c) else "SELL"
    evaluate("Interaction: Negate shared", test_buy_int, test_sell_int, classify_int_negate)

    grover_bp_int = grover_amplify(bp_int, sp_int, iterations=2)
    grover_sp_int = grover_amplify(sp_int, bp_int, iterations=2)
    evaluate("Interaction: Grover",
             test_buy_int, test_sell_int,
             lambda v: "BUY" if cosine_sim(v, grover_bp_int) > cosine_sim(v, grover_sp_int) else "SELL")

    # ===================================================================
    # PART E: Circular encoding for periodic features
    # ===================================================================
    log("")
    log("=" * 75)
    log("PART E: Mixed encoding (circular for periodic, linear for rest)")
    log("=" * 75)

    from holon.kernel.scalar import encode_circular

    PERIODIC = {"hour_cos", "hour_sin", "dow_sin", "dow_cos"}

    def encode_mixed(idx, scale=BEST_SCALE):
        c = candles[idx]
        data = {}
        for feat in FEATURES:
            raw = c.get(feat, 0.0) or 0.0
            nv = normalize(float(raw), norm_stats.get(feat, {}))
            data[feat] = LinearScale(nv, scale=scale)
        return client.encoder.encode_walkable(data)

    # Already done in part B — skip duplicate
    log("  (Same as Part B — periodic features already pre-encoded as sin/cos)")

    # ===================================================================
    # PART F: Feature-wise diagnostic — which features separate best?
    # ===================================================================
    log("")
    log("=" * 75)
    log("PART F: Per-feature prototype separation (scale=1.0)")
    log("=" * 75)

    feat_separations = []
    for feat in FEATURES:
        buy_vecs_f = []
        sell_vecs_f = []
        for idx in train_buy_idx:
            raw = candles[idx].get(feat, 0.0) or 0.0
            nv = normalize(float(raw), norm_stats.get(feat, {}))
            v = client.encoder.encode_scalar(nv, mode="linear", scale=BEST_SCALE)
            buy_vecs_f.append(v)
        for idx in train_sell_idx:
            raw = candles[idx].get(feat, 0.0) or 0.0
            nv = normalize(float(raw), norm_stats.get(feat, {}))
            v = client.encoder.encode_scalar(nv, mode="linear", scale=BEST_SCALE)
            sell_vecs_f.append(v)

        bp_f = prototype(buy_vecs_f)
        sp_f = prototype(sell_vecs_f)
        sim = cosine_sim(bp_f, sp_f)
        feat_separations.append((feat, sim))

    feat_separations.sort(key=lambda x: x[1])
    for feat, sim in feat_separations:
        bar = "█" * int((1.0 - sim) * 200)
        log(f"  {feat:<25s} sim={sim:.4f} {bar}")

    log("")
    log("=" * 75)
    log("DONE")
    log("=" * 75)


if __name__ == "__main__":
    main()
