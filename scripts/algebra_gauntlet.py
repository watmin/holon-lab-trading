"""Test every relevant Holon algebra technique for BUY vs SELL discrimination.

Encodes a small balanced sample, then runs each technique as a classifier.
Reports accuracy for each — find what sticks.

Techniques tested:
  1. Subspace residual (baseline — known to overfit)
  2. Prototype similarity (majority-rule consensus)
  3. Difference + Amplify (contrast vector boosting)
  4. Negate shared context (remove common market signal)
  5. Reject onto shared subspace (orthogonal complement)
  6. Resonance filtering (keep agreeing dimensions)
  7. Grover amplify (quantum-inspired signal boost)
  8. Similarity profile (dimension-wise disagreement)
  9. Bundle with confidence (margin-weighted discrimination)
 10. Attend (focus on discriminative dimensions)
 11. Interaction binding (bind feature pairs)

Usage:
    ./scripts/run_with_venv.sh python holon-lab-trading/scripts/algebra_gauntlet.py
    ./scripts/run_with_venv.sh python holon-lab-trading/scripts/algebra_gauntlet.py --n 1000
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
    attend,
    blend,
    bundle,
    bundle_with_confidence,
    centroid,
    coherence,
    difference,
    grover_amplify,
    negate,
    project,
    prototype,
    prototype_add,
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


def encode_and_split(args):
    """Load, encode, and split data. Returns (train_buy, train_sell, test_buy, test_sell)
    where each is a list of stripe vectors (list of N_STRIPES arrays)."""

    conn = sqlite3.connect(str(DB_PATH))

    # Norm stats
    rows = conn.execute("SELECT * FROM feature_stats").fetchall()
    norm_stats = {}
    for r in rows:
        norm_stats[r[0]] = {"mean": r[1], "std": r[2]}

    # Load candles
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
    log(f"Loaded {len(candles):,} candles")

    # Sample
    buy_idx = [i for i in range(WINDOW - 1, len(candles)) if candles[i][args.label] == "BUY"]
    sell_idx = [i for i in range(WINDOW - 1, len(candles)) if candles[i][args.label] == "SELL"]
    n_per = min(args.n, len(buy_idx), len(sell_idx))

    rng = np.random.default_rng(42)
    sampled = sorted(
        list(rng.choice(buy_idx, n_per, replace=False)) +
        list(rng.choice(sell_idx, n_per, replace=False))
    )
    log(f"Sampling {n_per:,} per class = {len(sampled):,} total")

    # Encode
    client = HolonClient(dimensions=DIM)

    encoded = []
    t0 = time.time()
    for count, idx in enumerate(sampled):
        window = candles[idx - WINDOW + 1: idx + 1]
        label = candles[idx][args.label]

        walkable = {}
        for feat in FEATURES:
            vals = []
            for r in window[-WINDOW:]:
                raw = r.get(feat, 0.0) or 0.0
                stats = norm_stats.get(feat)
                if stats and stats.get("std") and stats["std"] > 1e-10:
                    v = (float(raw) - stats["mean"]) / stats["std"]
                else:
                    v = float(raw)
                vals.append(LinearScale(v))
            walkable[feat] = WalkableSpread(vals)

        stripes = client.encoder.encode_walkable_striped(walkable, n_stripes=N_STRIPES)
        encoded.append((stripes, label))

        if (count + 1) % 500 == 0:
            log(f"  {count + 1:,} encoded ({(count + 1) / (time.time() - t0):.0f}/s)")

    log(f"Encoded {len(encoded):,} in {time.time() - t0:.1f}s")

    # Split 80/20
    buy_data = [(s, l) for s, l in encoded if l == "BUY"]
    sell_data = [(s, l) for s, l in encoded if l == "SELL"]

    rng.shuffle(buy_data)
    rng.shuffle(sell_data)

    split_b = int(len(buy_data) * 0.8)
    split_s = int(len(sell_data) * 0.8)

    train_buy = [s for s, _ in buy_data[:split_b]]
    test_buy = [s for s, _ in buy_data[split_b:]]
    train_sell = [s for s, _ in sell_data[:split_s]]
    test_sell = [s for s, _ in sell_data[split_s:]]

    log(f"Train: {len(train_buy)} BUY + {len(train_sell)} SELL")
    log(f"Test:  {len(test_buy)} BUY + {len(test_sell)} SELL")

    return train_buy, train_sell, test_buy, test_sell


def evaluate(name: str, test_buy, test_sell, classify_fn):
    """Run classifier and report accuracy."""
    correct = 0
    total = 0
    buy_correct = 0
    sell_correct = 0

    for stripes in test_buy:
        pred = classify_fn(stripes)
        if pred == "BUY":
            buy_correct += 1
            correct += 1
        total += 1

    for stripes in test_sell:
        pred = classify_fn(stripes)
        if pred == "SELL":
            sell_correct += 1
            correct += 1
        total += 1

    acc = correct / total * 100 if total > 0 else 0
    buy_acc = buy_correct / len(test_buy) * 100 if test_buy else 0
    sell_acc = sell_correct / len(test_sell) * 100 if test_sell else 0
    log(f"  {name:<40s} {acc:>5.1f}%  (BUY {buy_acc:.0f}% / SELL {sell_acc:.0f}%)  N={total}")
    return acc


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--n", type=int, default=500, help="Samples per class")
    parser.add_argument("--label", default="label_oracle_10")
    parser.add_argument("--vol-threshold", type=float, default=0.002)
    args = parser.parse_args()

    log("=" * 70)
    log("ALGEBRA GAUNTLET: Testing Holon techniques for BUY vs SELL")
    log("=" * 70)

    train_buy, train_sell, test_buy, test_sell = encode_and_split(args)

    # ===================================================================
    # Build per-stripe prototypes and tools
    # ===================================================================
    log("Building prototypes and tools...")

    buy_protos = []   # per-stripe BUY prototype
    sell_protos = []   # per-stripe SELL prototype
    market_protos = []  # per-stripe combined prototype
    contrast_vecs = []  # per-stripe difference(BUY, SELL)

    for s in range(N_STRIPES):
        # Collect all stripe-s vectors
        buy_vecs_s = [v[s] for v in train_buy]
        sell_vecs_s = [v[s] for v in train_sell]
        all_vecs_s = buy_vecs_s + sell_vecs_s

        bp = prototype(buy_vecs_s)
        sp = prototype(sell_vecs_s)
        mp = prototype(all_vecs_s)
        cv = difference(sp, bp)  # BUY-favored contrast

        buy_protos.append(bp)
        sell_protos.append(sp)
        market_protos.append(mp)
        contrast_vecs.append(cv)

    # Build per-stripe confidence vectors
    buy_conf = []
    sell_conf = []
    for s in range(N_STRIPES):
        buy_vecs_s = [v[s] for v in train_buy]
        sell_vecs_s = [v[s] for v in train_sell]
        bv, bc = bundle_with_confidence(buy_vecs_s)
        sv, sc = bundle_with_confidence(sell_vecs_s)
        buy_conf.append((bv, bc))
        sell_conf.append((sv, sc))

    log("  Prototypes, contrast vectors, confidence margins ready")

    # Check prototype similarity (diagnostic)
    proto_sims = [cosine_sim(buy_protos[s], sell_protos[s]) for s in range(N_STRIPES)]
    log(f"  BUY/SELL prototype similarity: mean={np.mean(proto_sims):.4f}, "
        f"min={np.min(proto_sims):.4f}, max={np.max(proto_sims):.4f}")

    contrast_norms = [np.linalg.norm(contrast_vecs[s].astype(float)) for s in range(N_STRIPES)]
    log(f"  Contrast vector norm: mean={np.mean(contrast_norms):.1f}")

    log("")
    log("=" * 70)
    log("RESULTS")
    log("=" * 70)

    # ===================================================================
    # 1. BASELINE: Subspace residual
    # ===================================================================
    log("Training subspaces...")
    buy_sub = StripedSubspace(dim=DIM, k=K, n_stripes=N_STRIPES)
    for stripes in train_buy:
        buy_sub.update(stripes)
    sell_sub = StripedSubspace(dim=DIM, k=K, n_stripes=N_STRIPES)
    for stripes in train_sell:
        sell_sub.update(stripes)

    def classify_subspace(stripes):
        return "BUY" if buy_sub.residual(stripes) < sell_sub.residual(stripes) else "SELL"

    evaluate("1. Subspace residual (baseline)", test_buy, test_sell, classify_subspace)

    # ===================================================================
    # 2. PROTOTYPE SIMILARITY
    # ===================================================================
    def classify_prototype(stripes):
        buy_sim = sum(cosine_sim(stripes[s], buy_protos[s]) for s in range(N_STRIPES))
        sell_sim = sum(cosine_sim(stripes[s], sell_protos[s]) for s in range(N_STRIPES))
        return "BUY" if buy_sim > sell_sim else "SELL"

    evaluate("2. Prototype similarity", test_buy, test_sell, classify_prototype)

    # ===================================================================
    # 3. DIFFERENCE + AMPLIFY
    # ===================================================================
    for strength in [1.0, 2.0, 5.0, 10.0]:
        def make_classifier(st):
            def classify(stripes):
                buy_sim = 0
                sell_sim = 0
                for s in range(N_STRIPES):
                    amplified = amplify(stripes[s], contrast_vecs[s], strength=st)
                    buy_sim += cosine_sim(amplified, buy_protos[s])
                    sell_sim += cosine_sim(amplified, sell_protos[s])
                return "BUY" if buy_sim > sell_sim else "SELL"
            return classify

        evaluate(f"3. Difference+Amplify (str={strength})", test_buy, test_sell, make_classifier(strength))

    # ===================================================================
    # 4. NEGATE SHARED CONTEXT
    # ===================================================================
    def classify_negate(stripes):
        buy_sim = 0
        sell_sim = 0
        for s in range(N_STRIPES):
            cleaned = negate(stripes[s], market_protos[s])
            buy_sim += cosine_sim(cleaned, negate(buy_protos[s], market_protos[s]))
            sell_sim += cosine_sim(cleaned, negate(sell_protos[s], market_protos[s]))
        return "BUY" if buy_sim > sell_sim else "SELL"

    evaluate("4. Negate shared context", test_buy, test_sell, classify_negate)

    # ===================================================================
    # 5. REJECT onto shared subspace
    # ===================================================================
    def classify_reject(stripes):
        buy_sim = 0
        sell_sim = 0
        for s in range(N_STRIPES):
            subspace = [market_protos[s]]
            cleaned = reject(stripes[s], subspace)
            buy_cleaned = reject(buy_protos[s], subspace)
            sell_cleaned = reject(sell_protos[s], subspace)
            buy_sim += cosine_sim(cleaned, buy_cleaned)
            sell_sim += cosine_sim(cleaned, sell_cleaned)
        return "BUY" if buy_sim > sell_sim else "SELL"

    evaluate("5. Reject shared subspace", test_buy, test_sell, classify_reject)

    # ===================================================================
    # 6. RESONANCE FILTERING
    # ===================================================================
    def classify_resonance(stripes):
        buy_sim = 0
        sell_sim = 0
        for s in range(N_STRIPES):
            res_buy = resonance(stripes[s], buy_protos[s])
            res_sell = resonance(stripes[s], sell_protos[s])
            buy_sim += np.sum(res_buy.astype(float))
            sell_sim += np.sum(res_sell.astype(float))
        return "BUY" if buy_sim > sell_sim else "SELL"

    evaluate("6. Resonance filtering", test_buy, test_sell, classify_resonance)

    # ===================================================================
    # 7. GROVER AMPLIFY
    # ===================================================================
    def classify_grover(stripes):
        buy_sim = 0
        sell_sim = 0
        for s in range(N_STRIPES):
            grover_buy = grover_amplify(buy_protos[s], sell_protos[s], iterations=2)
            grover_sell = grover_amplify(sell_protos[s], buy_protos[s], iterations=2)
            buy_sim += cosine_sim(stripes[s], grover_buy)
            sell_sim += cosine_sim(stripes[s], grover_sell)
        return "BUY" if buy_sim > sell_sim else "SELL"

    evaluate("7. Grover amplify", test_buy, test_sell, classify_grover)

    # ===================================================================
    # 8. SIMILARITY PROFILE (disagreement ratio)
    # ===================================================================
    def classify_sim_profile(stripes):
        buy_agree = 0
        sell_agree = 0
        for s in range(N_STRIPES):
            bp = similarity_profile(stripes[s], buy_protos[s])
            sp = similarity_profile(stripes[s], sell_protos[s])
            buy_agree += float(np.sum(bp > 0))
            sell_agree += float(np.sum(sp > 0))
        return "BUY" if buy_agree > sell_agree else "SELL"

    evaluate("8. Similarity profile (agreement)", test_buy, test_sell, classify_sim_profile)

    # ===================================================================
    # 9. BUNDLE WITH CONFIDENCE (margin-weighted)
    # ===================================================================
    def classify_confidence(stripes):
        buy_score = 0
        sell_score = 0
        for s in range(N_STRIPES):
            v = stripes[s].astype(float)
            bv, bc = buy_conf[s]
            sv, sc = sell_conf[s]
            buy_score += float(np.sum(v * bv.astype(float) * bc))
            sell_score += float(np.sum(v * sv.astype(float) * sc))
        return "BUY" if buy_score > sell_score else "SELL"

    evaluate("9. Bundle with confidence", test_buy, test_sell, classify_confidence)

    # ===================================================================
    # 10. ATTEND (focus on contrast dimensions)
    # ===================================================================
    for mode in ["soft", "hard", "amplify"]:
        def make_attend_classifier(m):
            def classify(stripes):
                buy_sim = 0
                sell_sim = 0
                for s in range(N_STRIPES):
                    attended = attend(stripes[s], contrast_vecs[s], strength=2.0, mode=m)
                    buy_sim += cosine_sim(attended, buy_protos[s])
                    sell_sim += cosine_sim(attended, sell_protos[s])
                return "BUY" if buy_sim > sell_sim else "SELL"
            return classify

        evaluate(f"10. Attend (mode={mode})", test_buy, test_sell, make_attend_classifier(mode))

    # ===================================================================
    # 11. CONTRAST VECTOR DIRECT SIMILARITY
    # ===================================================================
    def classify_contrast_direct(stripes):
        score = sum(cosine_sim(stripes[s], contrast_vecs[s]) for s in range(N_STRIPES))
        return "BUY" if score > 0 else "SELL"

    evaluate("11. Contrast vector (direct sim)", test_buy, test_sell, classify_contrast_direct)

    # ===================================================================
    # 12. NEGATE + AMPLIFY COMBO
    # ===================================================================
    for strength in [2.0, 5.0]:
        def make_negate_amplify(st):
            def classify(stripes):
                buy_sim = 0
                sell_sim = 0
                for s in range(N_STRIPES):
                    cleaned = negate(stripes[s], market_protos[s])
                    boosted = amplify(cleaned, contrast_vecs[s], strength=st)
                    buy_sim += cosine_sim(boosted, buy_protos[s])
                    sell_sim += cosine_sim(boosted, sell_protos[s])
                return "BUY" if buy_sim > sell_sim else "SELL"
            return classify

        evaluate(f"12. Negate+Amplify (str={strength})", test_buy, test_sell, make_negate_amplify(strength))

    # ===================================================================
    # 13. REJECT + CONTRAST
    # ===================================================================
    def classify_reject_contrast(stripes):
        score = 0
        for s in range(N_STRIPES):
            subspace = [market_protos[s]]
            cleaned = reject(stripes[s], subspace)
            score += cosine_sim(cleaned, contrast_vecs[s])
        return "BUY" if score > 0 else "SELL"

    evaluate("13. Reject + contrast direct", test_buy, test_sell, classify_reject_contrast)

    # ===================================================================
    # 14. DUAL SIGNAL (magnitude + alignment)
    # ===================================================================
    def classify_dual(stripes):
        # Magnitude: subspace residual difference
        buy_r = buy_sub.residual(stripes)
        sell_r = sell_sub.residual(stripes)
        mag_signal = sell_r - buy_r  # positive = BUY

        # Alignment: prototype similarity difference
        buy_sim = sum(cosine_sim(stripes[s], buy_protos[s]) for s in range(N_STRIPES))
        sell_sim = sum(cosine_sim(stripes[s], sell_protos[s]) for s in range(N_STRIPES))
        align_signal = buy_sim - sell_sim  # positive = BUY

        combined = mag_signal + align_signal
        return "BUY" if combined > 0 else "SELL"

    evaluate("14. Dual signal (mag+align)", test_buy, test_sell, classify_dual)

    # ===================================================================
    # 15. PER-STRIPE VOTING (majority across stripes)
    # ===================================================================
    def classify_stripe_vote(stripes):
        buy_votes = 0
        for s in range(N_STRIPES):
            if cosine_sim(stripes[s], buy_protos[s]) > cosine_sim(stripes[s], sell_protos[s]):
                buy_votes += 1
        return "BUY" if buy_votes > N_STRIPES / 2 else "SELL"

    evaluate("15. Per-stripe majority vote", test_buy, test_sell, classify_stripe_vote)

    # ===================================================================
    # 16. CONTRAST + CONFIDENCE WEIGHTED
    # ===================================================================
    def classify_contrast_conf(stripes):
        score = 0
        for s in range(N_STRIPES):
            sp = similarity_profile(stripes[s], contrast_vecs[s])
            _, bc = buy_conf[s]
            score += float(np.sum(sp.astype(float) * bc))
        return "BUY" if score > 0 else "SELL"

    evaluate("16. Contrast + confidence weighted", test_buy, test_sell, classify_contrast_conf)

    log("")
    log("=" * 70)
    log("DONE — compare techniques above. >55% on held-out = promising.")
    log("=" * 70)


if __name__ == "__main__":
    main()
