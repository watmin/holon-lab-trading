"""Train Holon subspaces on BUY vs SELL oracle moments and measure directional accuracy.

This is the first experiment with:
  - Proper z-score normalization (fixing the feature scale mismatch bug)
  - K=32 principal components
  - Rich directional feature set from the directional scan findings
  - Vector caching: encoding is a one-time cost per scheme

Pipeline:
  1. Load high-vol BUY/SELL candles with normalized features
  2. Encode windows using WalkableSpread (cached to disk)
  3. Train BUY and SELL StripedSubspaces on training period
  4. Score out-of-sample period
  5. Confidence-gated accuracy analysis

Usage:
    ./scripts/run_with_venv.sh python holon-lab-trading/scripts/holon_directional.py
    ./scripts/run_with_venv.sh python holon-lab-trading/scripts/holon_directional.py --adaptive
    ./scripts/run_with_venv.sh python holon-lab-trading/scripts/holon_directional.py --label label_oracle_05
    ./scripts/run_with_venv.sh python holon-lab-trading/scripts/holon_directional.py --rebuild-cache
"""

from __future__ import annotations

import argparse
import hashlib
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
CACHE_DIR = Path(__file__).parent.parent / "data" / "vec_cache"

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

SCHEME_ID = "directional_v1"


def log(msg: str):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def cache_key(label_col: str, vol_threshold: float) -> str:
    """Deterministic cache key from scheme + params."""
    parts = f"{SCHEME_ID}|{','.join(DIRECTIONAL_FEATURES)}|{label_col}|{vol_threshold}|{DIM}|{N_STRIPES}|{WINDOW}"
    h = hashlib.sha256(parts.encode()).hexdigest()[:12]
    return f"{SCHEME_ID}_{h}"


def load_norm_stats(conn: sqlite3.Connection) -> dict[str, dict]:
    rows = conn.execute("SELECT * FROM feature_stats").fetchall()
    stats = {}
    for r in rows:
        stats[r[0]] = {"mean": r[1], "std": r[2]}
    return stats


def normalize(value: float, feat_stats: dict) -> float:
    std = feat_stats.get("std")
    mean = feat_stats.get("mean")
    if std is None or mean is None or std < 1e-10:
        return 0.0
    return (value - mean) / std


def encode_row_window(client: HolonClient, window_rows: list[dict],
                      norm_stats: dict) -> list[np.ndarray] | None:
    if len(window_rows) < WINDOW:
        return None

    walkable = {}
    rows = window_rows[-WINDOW:]

    for feat in DIRECTIONAL_FEATURES:
        vals = []
        for r in rows:
            raw = r.get(feat, 0.0)
            if raw is None:
                raw = 0.0
            if feat in norm_stats:
                vals.append(LinearScale(normalize(float(raw), norm_stats[feat])))
            else:
                vals.append(LinearScale(float(raw)))
        walkable[feat] = WalkableSpread(vals)

    return client.encoder.encode_walkable_striped(walkable, n_stripes=N_STRIPES)


def load_all_highvol_candles(conn: sqlite3.Connection, label_col: str,
                             vol_threshold: float) -> list[dict]:
    """Load ALL high-vol BUY/SELL candles across all years, sorted by ts."""
    cols = ["ts", "year"] + DIRECTIONAL_FEATURES + [label_col]
    cols_str = ", ".join(cols)
    where = f"{label_col} IN ('BUY', 'SELL') AND atr_r > {vol_threshold}"
    query = f"SELECT {cols_str} FROM candles WHERE {where} ORDER BY ts"
    rows = conn.execute(query).fetchall()

    result = []
    for r in rows:
        d = {}
        for i, col in enumerate(cols):
            d[col] = r[i]
        result.append(d)
    return result


def encode_and_cache(candles: list[dict], norm_stats: dict,
                     label_col: str, vol_threshold: float,
                     force: bool = False) -> tuple[list[str], np.ndarray, list[str]]:
    """Encode all candles and cache to disk. Returns (timestamps, vectors_3d, labels).

    The vectors_3d array has shape (N, N_STRIPES, DIM) stored as int8.
    """
    key = cache_key(label_col, vol_threshold)
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    cache_file = CACHE_DIR / f"{key}.npz"

    if cache_file.exists() and not force:
        log(f"Loading cached vectors from {cache_file.name}")
        data = np.load(cache_file, allow_pickle=True)
        timestamps = data["timestamps"].tolist()
        vectors = data["vectors"]
        labels = data["labels"].tolist()
        log(f"  Loaded {len(timestamps):,} cached vectors")
        return timestamps, vectors, labels

    log(f"Encoding {len(candles):,} candles (one-time cost)...")
    client = HolonClient(dimensions=DIM)

    timestamps = []
    all_vecs = []
    labels = []

    t0 = time.time()
    for i in range(WINDOW - 1, len(candles)):
        window = candles[i - WINDOW + 1: i + 1]
        ts = candles[i]["ts"]
        label = candles[i][label_col]

        stripes = encode_row_window(client, window, norm_stats)
        if stripes is None:
            continue

        stacked = np.stack(stripes)  # (N_STRIPES, DIM) int8
        timestamps.append(ts)
        all_vecs.append(stacked)
        labels.append(label)

        if len(timestamps) % 10000 == 0:
            elapsed = time.time() - t0
            rate = len(timestamps) / elapsed
            eta = (len(candles) - WINDOW + 1 - len(timestamps)) / rate
            log(f"  {len(timestamps):,} encoded ({rate:.0f}/s, ETA {eta:.0f}s)")

    elapsed = time.time() - t0
    vectors = np.stack(all_vecs)  # (N, N_STRIPES, DIM) int8
    log(f"  Encoded {len(timestamps):,} vectors in {elapsed:.1f}s")

    tmp_file = cache_file.with_suffix(".tmp.npz")
    log(f"  Caching to {cache_file.name} ({vectors.nbytes / 1e6:.0f} MB)...")
    np.savez_compressed(
        tmp_file,
        timestamps=np.array(timestamps),
        vectors=vectors,
        labels=np.array(labels),
    )
    tmp_file.rename(cache_file)
    cache_size = cache_file.stat().st_size / 1e6
    log(f"  Cached: {cache_size:.1f} MB compressed")

    return timestamps, vectors, labels


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--label", default="label_oracle_10", help="Oracle label column")
    parser.add_argument("--vol-threshold", type=float, default=0.002)
    parser.add_argument("--adaptive", action="store_true", help="Update subspaces after each score")
    parser.add_argument("--train-years", default="2019-2020")
    parser.add_argument("--test-years", default="2021-2024")
    parser.add_argument("--rebuild-cache", action="store_true", help="Force re-encode vectors")
    args = parser.parse_args()

    train_y1, train_y2 = map(int, args.train_years.split("-"))
    test_y1, test_y2 = map(int, args.test_years.split("-"))

    conn = sqlite3.connect(str(DB_PATH))
    norm_stats = load_norm_stats(conn)

    log("=" * 80)
    log(f"Holon Directional Subspace Experiment")
    log(f"  Label: {args.label}, Vol threshold: {args.vol_threshold}")
    log(f"  Features: {len(DIRECTIONAL_FEATURES)}")
    log(f"  Encoding: DIM={DIM}, K={K}, stripes={N_STRIPES}, window={WINDOW}")
    log(f"  Train: {train_y1}-{train_y2}, Test: {test_y1}-{test_y2}")
    log(f"  Adaptive: {args.adaptive}")
    log("=" * 80)

    # Load all high-vol BUY/SELL candles
    log("Loading candles...")
    all_candles = load_all_highvol_candles(conn, args.label, args.vol_threshold)
    log(f"  {len(all_candles):,} high-vol BUY/SELL candles")
    conn.close()

    # Encode (or load from cache)
    timestamps, vectors, labels = encode_and_cache(
        all_candles, norm_stats, args.label, args.vol_threshold,
        force=args.rebuild_cache,
    )

    # Build year array for splitting
    ts_years = {}
    for c in all_candles:
        ts_years[c["ts"]] = int(c["year"])

    year_arr = np.array([ts_years.get(ts, 0) for ts in timestamps])
    label_arr = np.array(labels)

    train_mask = (year_arr >= train_y1) & (year_arr <= train_y2)
    test_mask = (year_arr >= test_y1) & (year_arr <= test_y2)

    n_train = train_mask.sum()
    n_test = test_mask.sum()
    log(f"  Train: {n_train:,}, Test: {n_test:,}")

    train_buy_mask = train_mask & (label_arr == "BUY")
    train_sell_mask = train_mask & (label_arr == "SELL")
    log(f"  Train BUY: {train_buy_mask.sum():,}, Train SELL: {train_sell_mask.sum():,}")

    # Train subspaces from cached vectors
    log("Training BUY subspace...")
    buy_subspace = StripedSubspace(dim=DIM, k=K, n_stripes=N_STRIPES)
    train_buy_indices = np.where(train_buy_mask)[0]
    for idx in train_buy_indices:
        stripe_list = [vectors[idx, s, :] for s in range(N_STRIPES)]
        buy_subspace.update(stripe_list)

    log("Training SELL subspace...")
    sell_subspace = StripedSubspace(dim=DIM, k=K, n_stripes=N_STRIPES)
    train_sell_indices = np.where(train_sell_mask)[0]
    for idx in train_sell_indices:
        stripe_list = [vectors[idx, s, :] for s in range(N_STRIPES)]
        sell_subspace.update(stripe_list)

    log(f"  BUY subspace: {buy_subspace.n} observations")
    log(f"  SELL subspace: {sell_subspace.n} observations")

    # Score in-sample
    log("Scoring training data (in-sample)...")
    train_correct = 0
    train_total = 0
    for idx in np.where(train_mask)[0]:
        stripe_list = [vectors[idx, s, :] for s in range(N_STRIPES)]
        buy_r = buy_subspace.residual(stripe_list)
        sell_r = sell_subspace.residual(stripe_list)
        pred = "BUY" if buy_r < sell_r else "SELL"
        if pred == labels[idx]:
            train_correct += 1
        train_total += 1

    train_acc = train_correct / train_total * 100 if train_total > 0 else 0
    log(f"  In-sample accuracy: {train_acc:.1f}% ({train_correct:,}/{train_total:,})")

    # Score out-of-sample
    log("Scoring test data (out-of-sample)...")
    test_indices = np.where(test_mask)[0]

    test_correct = 0
    test_total = 0
    yearly_stats = {}
    residual_diffs = []
    predictions = []

    t0 = time.time()
    for idx in test_indices:
        stripe_list = [vectors[idx, s, :] for s in range(N_STRIPES)]
        label = labels[idx]
        year = year_arr[idx]

        buy_r = buy_subspace.residual(stripe_list)
        sell_r = sell_subspace.residual(stripe_list)

        pred = "BUY" if buy_r < sell_r else "SELL"
        correct = pred == label

        if correct:
            test_correct += 1
        test_total += 1

        if year not in yearly_stats:
            yearly_stats[year] = {"correct": 0, "total": 0,
                                   "buy_correct": 0, "buy_total": 0,
                                   "sell_correct": 0, "sell_total": 0}
        yearly_stats[year]["total"] += 1
        if correct:
            yearly_stats[year]["correct"] += 1
        if label == "BUY":
            yearly_stats[year]["buy_total"] += 1
            if correct:
                yearly_stats[year]["buy_correct"] += 1
        else:
            yearly_stats[year]["sell_total"] += 1
            if correct:
                yearly_stats[year]["sell_correct"] += 1

        diff = sell_r - buy_r
        residual_diffs.append((diff, label, correct))
        predictions.append((pred, label))

        if args.adaptive:
            if label == "BUY":
                buy_subspace.update(stripe_list)
            else:
                sell_subspace.update(stripe_list)

    elapsed = time.time() - t0
    test_acc = test_correct / test_total * 100 if test_total > 0 else 0
    log(f"  Out-of-sample accuracy: {test_acc:.1f}% ({test_correct:,}/{test_total:,}) [{elapsed:.1f}s]")

    # ===== RESULTS =====
    print()
    print("=" * 80)
    print("RESULTS: Holon Directional Subspace")
    print("=" * 80)
    print(f"In-sample (train):    {train_acc:.1f}%")
    print(f"Out-of-sample (test): {test_acc:.1f}%")
    print()

    print("Year-by-year breakdown:")
    print(f"{'Year':>6} {'Acc%':>7} {'BUY acc':>8} {'SELL acc':>9} {'N':>8}")
    print("-" * 45)
    for y in sorted(yearly_stats):
        s = yearly_stats[y]
        acc = s["correct"] / s["total"] * 100
        buy_acc = s["buy_correct"] / s["buy_total"] * 100 if s["buy_total"] > 0 else 0
        sell_acc = s["sell_correct"] / s["sell_total"] * 100 if s["sell_total"] > 0 else 0
        print(f"{y:>6} {acc:>7.1f} {buy_acc:>8.1f} {sell_acc:>9.1f} {s['total']:>8,}")

    # Confusion matrix
    pbb = sum(1 for p, l in predictions if p == "BUY" and l == "BUY")
    pbs = sum(1 for p, l in predictions if p == "BUY" and l == "SELL")
    psb = sum(1 for p, l in predictions if p == "SELL" and l == "BUY")
    pss = sum(1 for p, l in predictions if p == "SELL" and l == "SELL")

    print()
    print("Confusion matrix:")
    print(f"              Actual BUY   Actual SELL")
    print(f"  Pred BUY     {pbb:>8,}      {pbs:>8,}")
    print(f"  Pred SELL    {psb:>8,}      {pss:>8,}")

    buy_prec = pbb / (pbb + pbs) * 100 if (pbb + pbs) > 0 else 0
    sell_prec = pss / (psb + pss) * 100 if (psb + pss) > 0 else 0
    print(f"\n  BUY precision:  {buy_prec:.1f}%")
    print(f"  SELL precision: {sell_prec:.1f}%")

    # Confidence analysis
    print()
    print("=" * 80)
    print("CONFIDENCE ANALYSIS: Does residual magnitude predict accuracy?")
    print("=" * 80)

    diffs_arr = np.array([(d, 1 if c else 0) for d, l, c in residual_diffs])
    abs_diffs = np.abs(diffs_arr[:, 0])

    for pct_label, lo, hi in [
        ("Bottom 25% (low confidence)", 0, 25),
        ("25-50%", 25, 50),
        ("50-75%", 50, 75),
        ("Top 25% (high confidence)", 75, 100),
        ("Top 10% (highest confidence)", 90, 100),
        ("Top 5%", 95, 100),
    ]:
        lo_val = np.percentile(abs_diffs, lo)
        hi_val = np.percentile(abs_diffs, hi)
        mask = (abs_diffs >= lo_val) & (abs_diffs <= hi_val)
        if hi == 100:
            mask = abs_diffs >= lo_val
        subset = diffs_arr[mask]
        if len(subset) < 10:
            continue
        acc = subset[:, 1].mean() * 100
        print(f"  {pct_label}: {acc:.1f}% accuracy (N={len(subset):,})")

    # Selective trading
    print()
    print("=" * 80)
    print("SELECTIVE TRADING: Only act when Holon confidence is high")
    print("=" * 80)

    test_year_list = year_arr[test_mask]

    for min_pct in [50, 60, 70, 80, 90, 95]:
        threshold = np.percentile(abs_diffs, min_pct)
        high_conf_mask = abs_diffs >= threshold
        subset = diffs_arr[high_conf_mask]
        if len(subset) < 10:
            continue
        acc = subset[:, 1].mean() * 100

        high_conf_years = {}
        for j, is_high in enumerate(high_conf_mask):
            if is_high and j < len(test_year_list):
                y = int(test_year_list[j])
                if y not in high_conf_years:
                    high_conf_years[y] = {"correct": 0, "total": 0}
                high_conf_years[y]["total"] += 1
                if diffs_arr[j, 1] == 1:
                    high_conf_years[y]["correct"] += 1

        yr_str = "  ".join(
            f"{y}:{s['correct']/s['total']*100:.0f}%"
            for y, s in sorted(high_conf_years.items()) if s["total"] > 0
        )
        print(f"  Top {100-min_pct:>2}%: {acc:.1f}% acc, N={len(subset):>6,}  [{yr_str}]")


if __name__ == "__main__":
    main()
