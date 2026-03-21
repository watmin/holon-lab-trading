"""Fast gate grading — sample-based precision/recall without sequential walk.

Instead of encoding every candle sequentially, samples N windows from each
oracle class (BUY/SELL/QUIET) and checks if the gate classifies them correctly.

Phase A: Agreement — sample from known BUY/SELL, check if gate agrees
Phase B: Disagreement — sample from known QUIET, check if gate stays quiet
Phase C: Doubt — for false positives, does doubt catch them?

~1500 encodes total per period (~30s) vs ~10k for sequential walk.

Sweeps n_train and measures classification accuracy without needing equity sim.

Usage:
    ./scripts/run_with_venv.sh python holon-lab-trading/scripts/fast_grade.py
"""

from __future__ import annotations

import sys
import time
from pathlib import Path

import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).parent.parent))

from trading.features import TechnicalFeatureFactory
from trading.gate import HolonGate

from holon import HolonClient
from holon.kernel.walkable import LinearScale, WalkableSpread
from holon.memory import StripedSubspace

MIN_MOVE = 0.5
HORIZON = 36
SAMPLES_PER_CLASS = 500
PHASE2_SCAN = 5_000


def log(msg: str):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def find_opportunities(close, min_move_pct, horizon):
    n = len(close)
    labels = np.full(n, "QUIET", dtype=object)
    exit_indices = np.zeros(n, dtype=int)
    for i in range(n - 1):
        end = min(i + 1 + horizon, n)
        if end <= i + 1:
            continue
        entry = close[i]
        target_up = entry * (1 + min_move_pct / 100)
        target_down = entry * (1 - min_move_pct / 100)
        buy_hit = sell_hit = -1
        for j in range(i + 1, end):
            if buy_hit < 0 and close[j] >= target_up:
                buy_hit = j
            if sell_hit < 0 and close[j] <= target_down:
                sell_hit = j
            if buy_hit >= 0 and sell_hit >= 0:
                break
        if buy_hit >= 0 and (sell_hit < 0 or buy_hit <= sell_hit):
            labels[i] = "BUY"
            exit_indices[i] = buy_hit
        elif sell_hit >= 0:
            labels[i] = "SELL"
            exit_indices[i] = sell_hit
    return labels, exit_indices


def precompute(df_ind):
    n = len(df_ind)
    o, h, l, c = df_ind["open"].values, df_ind["high"].values, df_ind["low"].values, df_ind["close"].values
    rng = np.maximum(h - l, 1e-10)
    return {
        "open_r": df_ind["open_r"].values if "open_r" in df_ind.columns else np.zeros(n),
        "high_r": df_ind["high_r"].values if "high_r" in df_ind.columns else np.zeros(n),
        "low_r": df_ind["low_r"].values if "low_r" in df_ind.columns else np.zeros(n),
        "vol_r": df_ind["vol_r"].values if "vol_r" in df_ind.columns else np.zeros(n),
        "rsi": df_ind["rsi"].values if "rsi" in df_ind.columns else np.full(n, 50.0),
        "ret": df_ind["ret"].values if "ret" in df_ind.columns else np.zeros(n),
        "sma20_r": df_ind["sma20_r"].values if "sma20_r" in df_ind.columns else np.zeros(n),
        "sma50_r": df_ind["sma50_r"].values if "sma50_r" in df_ind.columns else np.zeros(n),
        "macd_hist": df_ind["macd_hist_r"].values if "macd_hist_r" in df_ind.columns else np.zeros(n),
        "bb_width": df_ind["bb_width"].values if "bb_width" in df_ind.columns else np.zeros(n),
        "adx": df_ind["adx"].values if "adx" in df_ind.columns else np.zeros(n),
        "body": (c - o) / rng, "upper_wick": (h - np.maximum(o, c)) / rng,
        "lower_wick": (np.minimum(o, c) - l) / rng, "close_pos": (c - l) / rng,
    }


WINDOW = HolonGate.WINDOW
DIM = HolonGate.DIM
K = HolonGate.K
N_STRIPES = HolonGate.N_STRIPES


def encode_fast(client, features, idx):
    start = int(idx) - WINDOW + 1
    if start < 0:
        return None
    walkable = {}
    for name in ["open_r", "high_r", "low_r", "vol_r", "rsi", "ret",
                  "sma20_r", "sma50_r", "macd_hist", "bb_width", "adx",
                  "body", "upper_wick", "lower_wick", "close_pos"]:
        arr = features[name]
        walkable[name] = WalkableSpread(
            [LinearScale(float(arr[start + i])) for i in range(WINDOW)]
        )
    return client.encoder.encode_walkable_striped(walkable, n_stripes=N_STRIPES)


def train_subspaces(client, features, labels, target_label, n_train, rng, n_data):
    indices = [i for i in range(WINDOW, n_data) if labels[i] == target_label]
    if len(indices) < 20:
        return None, 0
    sample = rng.choice(indices, size=min(n_train + 50, len(indices)), replace=False)
    ss = StripedSubspace(dim=DIM, k=K, n_stripes=N_STRIPES)
    count = 0
    for idx in sample:
        v = encode_fast(client, features, idx)
        if v is not None:
            ss.update(v)
            count += 1
        if count >= n_train:
            break
    return (ss if count >= 20 else None), count


def classify(subspaces, v, doubt=None):
    """Classify a vector. Returns (label, doubt_rejected)."""
    residuals = {label: ss.residual(v) for label, ss in subspaces.items()}
    predicted = min(residuals, key=residuals.get)

    doubt_rejected = False
    if predicted in ("BUY", "SELL") and doubt:
        trap_key = f"TRAP_{predicted}"
        if trap_key in doubt:
            if doubt[trap_key].residual(v) < residuals[predicted]:
                doubt_rejected = True

    final = "QUIET" if doubt_rejected else predicted
    return final, doubt_rejected


def grade_on_period(client, subspaces, doubt, features, labels, rng, period_name):
    """Sample-based grading: N samples per class."""
    n = len(labels)

    results = {}
    for true_class in ["BUY", "SELL", "QUIET"]:
        indices = [i for i in range(WINDOW, n) if labels[i] == true_class]
        if len(indices) < 10:
            results[true_class] = {"n": 0}
            continue

        sample = rng.choice(indices, size=min(SAMPLES_PER_CLASS, len(indices)), replace=False)
        predictions = []
        doubt_catches = 0

        for idx in sample:
            v = encode_fast(client, features, idx)
            if v is None:
                continue
            pred, was_doubted = classify(subspaces, v, doubt)
            predictions.append(pred)
            if was_doubted:
                doubt_catches += 1

        preds = np.array(predictions)
        n_tested = len(preds)

        if true_class in ("BUY", "SELL"):
            correct = (preds == true_class).sum()
            accuracy = correct / n_tested * 100 if n_tested else 0
            results[true_class] = {"n": n_tested, "correct": correct, "accuracy": accuracy}
        else:
            quiet_correct = (preds == "QUIET").sum()
            false_buy = (preds == "BUY").sum()
            false_sell = (preds == "SELL").sum()
            specificity = quiet_correct / n_tested * 100 if n_tested else 0
            results[true_class] = {
                "n": n_tested, "quiet": quiet_correct, "false_buy": false_buy,
                "false_sell": false_sell, "specificity": specificity,
                "doubt_catches": doubt_catches,
            }

    return results


def main():
    log("Loading data...")
    df = pd.read_parquet("holon-lab-trading/data/btc_5m_raw.parquet")
    ts = pd.to_datetime(df["ts"])
    factory = TechnicalFeatureFactory()

    log("Preparing 2019-2020...")
    df_seed = df[ts <= "2020-12-31"].reset_index(drop=True)
    df_seed_ind = factory.compute_indicators(df_seed)
    close_seed = df_seed_ind["close"].values
    seed_labels, _ = find_opportunities(close_seed, MIN_MOVE, HORIZON)
    log(f"  {(seed_labels=='BUY').sum()}B / {(seed_labels=='SELL').sum()}S / {(seed_labels=='QUIET').sum()}Q")

    n_trains = [100, 300, 500, 1000, 2000, 5000]

    periods = [
        ("2021", "2021-01-01", "2021-12-31"),
        ("2022", "2022-01-01", "2022-12-31"),
        ("2023", "2023-01-01", "2023-12-31"),
        ("2024", "2024-01-01", "2024-12-31"),
    ]

    # Precompute period data once
    period_data = []
    for period_name, start, end in periods:
        mask = (ts >= start) & (ts <= end)
        df_period = df[mask].reset_index(drop=True)
        if len(df_period) < 500:
            continue
        df_ind = factory.compute_indicators(df_period)
        close = df_ind["close"].values
        features = precompute(df_ind)
        plabels, _ = find_opportunities(close, MIN_MOVE, HORIZON)
        period_data.append((period_name, features, plabels, len(df_ind)))

    seed_features = precompute(df_seed_ind)

    for nt in n_trains:
        log(f"\n{'=' * 90}")
        log(f"n_train={nt}, K={K}")
        log(f"{'=' * 90}")

        client = HolonClient(dimensions=DIM)
        rng = np.random.default_rng(42)

        t0 = time.time()
        subspaces = {}
        for label in ["BUY", "SELL", "QUIET"]:
            ss, count = train_subspaces(client, seed_features, seed_labels, label, nt, rng, len(df_seed_ind))
            if ss:
                subspaces[label] = ss
                log(f"  {label}: {count} windows")
        train_time = time.time() - t0
        log(f"  Training: {train_time:.0f}s")

        if len(subspaces) < 2:
            log("  Not enough subspaces, skipping")
            continue

        # Phase 2: find traps for doubt
        log(f"  Finding traps (scanning {PHASE2_SCAN} windows)...")
        t0 = time.time()
        scan_idx = rng.choice(range(WINDOW, min(len(df_seed_ind), 50_000)),
                              size=min(PHASE2_SCAN, len(df_seed_ind) - WINDOW), replace=False)
        trap_buy_v, trap_sell_v = [], []
        for idx in scan_idx:
            v = encode_fast(client, seed_features, int(idx))
            if v is None:
                continue
            residuals = {l: ss.residual(v) for l, ss in subspaces.items()}
            pred = min(residuals, key=residuals.get)
            actual = seed_labels[idx]
            if pred == "BUY" and actual != "BUY":
                trap_buy_v.append(v)
            elif pred == "SELL" and actual != "SELL":
                trap_sell_v.append(v)
        trap_time = time.time() - t0
        log(f"  Traps: {len(trap_buy_v)} TRAP_BUY, {len(trap_sell_v)} TRAP_SELL ({trap_time:.0f}s)")

        # Train doubt
        doubt = {}
        n_doubt = min(nt, 500)
        for trap_name, trap_vectors in [("TRAP_BUY", trap_buy_v), ("TRAP_SELL", trap_sell_v)]:
            if len(trap_vectors) < 20:
                continue
            ss = StripedSubspace(dim=DIM, k=K, n_stripes=N_STRIPES)
            sample = rng.choice(len(trap_vectors), size=min(n_doubt, len(trap_vectors)), replace=False)
            for i in sample:
                ss.update(trap_vectors[i])
            doubt[trap_name] = ss
            log(f"  {trap_name}: {len(sample)} vectors")

        # Grade on each period
        log(f"\n  {'Period':8s} | {'BUY acc':>8s} | {'SELL acc':>8s} | {'QUIET spec':>10s} | {'FP buy':>7s} | {'FP sell':>7s} | {'Doubt catches':>13s} | {'time':>5s}")
        log(f"  {'-'*8}-+-{'-'*8}-+-{'-'*8}-+-{'-'*10}-+-{'-'*7}-+-{'-'*7}-+-{'-'*13}-+-{'-'*5}")

        for period_name, features, plabels, n in period_data:
            t0 = time.time()
            r = grade_on_period(client, subspaces, doubt, features, plabels, rng, period_name)
            elapsed = time.time() - t0

            buy_acc = r["BUY"]["accuracy"] if r["BUY"]["n"] > 0 else 0
            sell_acc = r["SELL"]["accuracy"] if r["SELL"]["n"] > 0 else 0
            q = r["QUIET"]
            quiet_spec = q["specificity"] if q["n"] > 0 else 0
            fp_buy = q.get("false_buy", 0)
            fp_sell = q.get("false_sell", 0)
            doubt_c = q.get("doubt_catches", 0)

            log(f"  {period_name:8s} | {buy_acc:7.1f}% | {sell_acc:7.1f}% | {quiet_spec:9.1f}% | {fp_buy:7d} | {fp_sell:7d} | {doubt_c:13d} | {elapsed:4.0f}s")

        # Also grade on training data (should be best case)
        t0 = time.time()
        r_train = grade_on_period(client, subspaces, doubt, seed_features, seed_labels, rng, "train")
        elapsed = time.time() - t0
        buy_acc = r_train["BUY"]["accuracy"] if r_train["BUY"]["n"] > 0 else 0
        sell_acc = r_train["SELL"]["accuracy"] if r_train["SELL"]["n"] > 0 else 0
        q = r_train["QUIET"]
        quiet_spec = q["specificity"] if q["n"] > 0 else 0
        log(f"  {'TRAIN':8s} | {buy_acc:7.1f}% | {sell_acc:7.1f}% | {quiet_spec:9.1f}% | {q.get('false_buy',0):7d} | {q.get('false_sell',0):7d} | {q.get('doubt_catches',0):13d} | {elapsed:4.0f}s")

    log(f"\n{'=' * 90}")
    log("DONE")
    log(f"{'=' * 90}")


if __name__ == "__main__":
    main()
