"""Quick smoke test: can Holon separate BUY from SELL with normalized features?

Takes a small sample, does 80/20 cross-validation, reports accuracy.
Runs in ~2-3 minutes. Use this to validate before committing to the full run.

Usage:
    ./scripts/run_with_venv.sh python holon-lab-trading/scripts/holon_quick_test.py
    ./scripts/run_with_venv.sh python holon-lab-trading/scripts/holon_quick_test.py --n 10000
    ./scripts/run_with_venv.sh python holon-lab-trading/scripts/holon_quick_test.py --label label_oracle_05
"""

from __future__ import annotations

import argparse
import sqlite3
import sys
import time
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent.parent))

from holon import HolonClient
from holon.kernel.walkable import LinearScale, WalkableSpread
from holon.memory import StripedSubspace

DB_PATH = Path(__file__).parent.parent / "data" / "analysis.db"

DIM = 1024
K = 32
N_STRIPES = 32
WINDOW = 12

DIRECTIONAL_FEATURES = [
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


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--n", type=int, default=5000, help="Sample size per label")
    parser.add_argument("--label", default="label_oracle_10")
    parser.add_argument("--vol-threshold", type=float, default=0.002)
    parser.add_argument("--split", type=float, default=0.8, help="Train fraction")
    parser.add_argument("--years", default="2019-2020", help="Year range for sample")
    args = parser.parse_args()

    y1, y2 = map(int, args.years.split("-"))

    conn = sqlite3.connect(str(DB_PATH))

    # Load norm stats
    rows = conn.execute("SELECT * FROM feature_stats").fetchall()
    norm_stats = {}
    for r in rows:
        norm_stats[r[0]] = {"mean": r[1], "std": r[2]}

    # Load candles — get contiguous blocks so windows work
    cols = ["ts", "year"] + DIRECTIONAL_FEATURES + [args.label]
    cols_str = ", ".join(cols)
    query = f"""
        SELECT {cols_str} FROM candles
        WHERE {args.label} IN ('BUY', 'SELL')
          AND atr_r > {args.vol_threshold}
          AND year BETWEEN {y1} AND {y2}
        ORDER BY ts
    """
    all_rows = conn.execute(query).fetchall()
    conn.close()

    candles = []
    for r in all_rows:
        d = {cols[i]: r[i] for i in range(len(cols))}
        candles.append(d)

    log(f"Loaded {len(candles):,} candles from {y1}-{y2}")

    # Index candles by label for sampling BEFORE encoding
    buy_indices = [i for i in range(WINDOW - 1, len(candles)) if candles[i][args.label] == "BUY"]
    sell_indices = [i for i in range(WINDOW - 1, len(candles)) if candles[i][args.label] == "SELL"]
    n_per = min(args.n, len(buy_indices), len(sell_indices))
    log(f"Available: {len(buy_indices):,} BUY, {len(sell_indices):,} SELL — sampling {n_per:,} each")

    rng = np.random.default_rng(42)
    sampled_buy = rng.choice(buy_indices, n_per, replace=False)
    sampled_sell = rng.choice(sell_indices, n_per, replace=False)
    sampled_indices = sorted(np.concatenate([sampled_buy, sampled_sell]))

    # Encode ONLY sampled windows
    client = HolonClient(dimensions=DIM)
    encoded = []
    t0 = time.time()
    for idx in sampled_indices:
        window = candles[idx - WINDOW + 1: idx + 1]
        label = candles[idx][args.label]

        walkable = {}
        for feat in DIRECTIONAL_FEATURES:
            vals = []
            for r in window[-WINDOW:]:
                raw = r.get(feat, 0.0)
                if raw is None:
                    raw = 0.0
                stats = norm_stats.get(feat)
                if stats and stats["std"] and stats["std"] > 1e-10:
                    v = (float(raw) - stats["mean"]) / stats["std"]
                else:
                    v = float(raw)
                vals.append(LinearScale(v))
            walkable[feat] = WalkableSpread(vals)

        stripes = client.encoder.encode_walkable_striped(walkable, n_stripes=N_STRIPES)
        encoded.append((stripes, label))

        if len(encoded) % 2000 == 0:
            elapsed = time.time() - t0
            log(f"  {len(encoded):,} encoded ({len(encoded)/elapsed:.0f}/s)")

    elapsed = time.time() - t0
    log(f"Encoded {len(encoded):,} windows in {elapsed:.1f}s")

    buy_data = [(s, l) for s, l in encoded if l == "BUY"]
    sell_data = [(s, l) for s, l in encoded if l == "SELL"]
    log(f"Available: {len(buy_data):,} BUY, {len(sell_data):,} SELL — using {n_per:,} each")

    rng = np.random.default_rng(42)
    buy_idx = rng.choice(len(buy_data), n_per, replace=False)
    sell_idx = rng.choice(len(sell_data), n_per, replace=False)

    balanced = [(buy_data[i][0], "BUY") for i in buy_idx] + \
               [(sell_data[i][0], "SELL") for i in sell_idx]
    rng.shuffle(balanced)

    # Split
    split_pt = int(len(balanced) * args.split)
    train_set = balanced[:split_pt]
    test_set = balanced[split_pt:]

    train_buy = [(s, l) for s, l in train_set if l == "BUY"]
    train_sell = [(s, l) for s, l in train_set if l == "SELL"]
    test_buy = [(s, l) for s, l in test_set if l == "BUY"]
    test_sell = [(s, l) for s, l in test_set if l == "SELL"]

    log(f"Train: {len(train_buy):,} BUY + {len(train_sell):,} SELL = {len(train_set):,}")
    log(f"Test:  {len(test_buy):,} BUY + {len(test_sell):,} SELL = {len(test_set):,}")

    # Train subspaces
    log("Training subspaces...")
    buy_sub = StripedSubspace(dim=DIM, k=K, n_stripes=N_STRIPES)
    for stripes, _ in train_buy:
        buy_sub.update(stripes)

    sell_sub = StripedSubspace(dim=DIM, k=K, n_stripes=N_STRIPES)
    for stripes, _ in train_sell:
        sell_sub.update(stripes)

    log(f"  BUY: {buy_sub.n} obs, SELL: {sell_sub.n} obs")

    # Score
    def score_set(dataset, name):
        correct = 0
        buy_correct = 0
        buy_total = 0
        sell_correct = 0
        sell_total = 0
        diffs = []

        for stripes, label in dataset:
            buy_r = buy_sub.residual(stripes)
            sell_r = sell_sub.residual(stripes)
            pred = "BUY" if buy_r < sell_r else "SELL"

            if pred == label:
                correct += 1
            if label == "BUY":
                buy_total += 1
                if pred == label:
                    buy_correct += 1
            else:
                sell_total += 1
                if pred == label:
                    sell_correct += 1

            diffs.append((sell_r - buy_r, label, pred == label))

        acc = correct / len(dataset) * 100
        buy_acc = buy_correct / buy_total * 100 if buy_total else 0
        sell_acc = sell_correct / sell_total * 100 if sell_total else 0

        log(f"  {name}: {acc:.1f}% ({correct:,}/{len(dataset):,})")
        log(f"    BUY accuracy:  {buy_acc:.1f}% ({buy_correct}/{buy_total})")
        log(f"    SELL accuracy: {sell_acc:.1f}% ({sell_correct}/{sell_total})")

        # Confidence quartiles
        diffs_arr = np.array([(d, 1 if c else 0) for d, _, c in diffs])
        abs_d = np.abs(diffs_arr[:, 0])
        for label_str, lo, hi in [
            ("Low conf (Q1)", 0, 25),
            ("Med-low (Q2)", 25, 50),
            ("Med-high (Q3)", 50, 75),
            ("High conf (Q4)", 75, 100),
            ("Top 10%", 90, 100),
        ]:
            lo_v = np.percentile(abs_d, lo)
            hi_v = np.percentile(abs_d, hi) if hi < 100 else abs_d.max() + 1
            mask = (abs_d >= lo_v) & (abs_d < hi_v) if hi < 100 else (abs_d >= lo_v)
            sub = diffs_arr[mask]
            if len(sub) < 5:
                continue
            a = sub[:, 1].mean() * 100
            log(f"    {label_str}: {a:.1f}% (N={len(sub):,})")

        return acc

    log("=" * 60)
    log(f"RESULTS (sample={n_per:,}/class, {args.years})")
    log("=" * 60)

    log("Scoring train set (in-sample)...")
    score_set(train_set, "TRAIN (in-sample)")
    log("Scoring test set (held-out)...")
    score_set(test_set, "TEST (held-out)")

    log("")
    log("=" * 60)
    log("K SENSITIVITY: Same data, different principal components")
    log("=" * 60)

    for k_val in [4, 8, 16, 32, 48, 64]:
        log(f"  Training K={k_val}...")
        bs = StripedSubspace(dim=DIM, k=k_val, n_stripes=N_STRIPES)
        for stripes, _ in train_buy:
            bs.update(stripes)
        ss = StripedSubspace(dim=DIM, k=k_val, n_stripes=N_STRIPES)
        for stripes, _ in train_sell:
            ss.update(stripes)

        log(f"  Scoring K={k_val}...")
        correct = 0
        for stripes, label in test_set:
            buy_r = bs.residual(stripes)
            sell_r = ss.residual(stripes)
            pred = "BUY" if buy_r < sell_r else "SELL"
            if pred == label:
                correct += 1

        acc = correct / len(test_set) * 100
        log(f"  K={k_val:>3}: {acc:.1f}% ({correct:,}/{len(test_set):,})")


if __name__ == "__main__":
    main()
