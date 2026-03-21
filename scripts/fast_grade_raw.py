"""Fast grade with raw candle geometry encoding — no TA indicators.

Clean reset: strip encoding to just candle shape + volume + returns.
Test against oracle labels (profitable opportunities) using sample-based grading.

Encoding: 7 features per candle across window
  - body_ratio: (close-open)/range
  - upper_wick: upper wick / range
  - lower_wick: lower wick / range
  - close_pos: (close-low) / range
  - vol_rel: volume relative to window mean
  - ret: inter-candle return
  - range_chg: range expansion/contraction

Plus window-level summary stats.

Sweeps: n_train, window size

Usage:
    ./scripts/run_with_venv.sh python holon-lab-trading/scripts/fast_grade_raw.py
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

DIM = 1024
K = 32
N_STRIPES = 32


def log(msg: str):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def find_opportunities(close, min_move_pct, horizon):
    n = len(close)
    labels = np.full(n, "QUIET", dtype=object)
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
        elif sell_hit >= 0:
            labels[i] = "SELL"
    return labels


def precompute_raw(df, window):
    """Precompute raw candle geometry arrays — no TA indicators."""
    o = df["open"].values.astype(float)
    h = df["high"].values.astype(float)
    l = df["low"].values.astype(float)
    c = df["close"].values.astype(float)
    v = df["volume"].values.astype(float)

    rng = np.maximum(h - l, 1e-10)

    body = (c - o) / rng
    upper_wick = (h - np.maximum(o, c)) / rng
    lower_wick = (np.minimum(o, c) - l) / rng
    close_pos = (c - l) / rng

    ret = np.zeros(len(c))
    ret[1:] = (c[1:] / c[:-1] - 1) * 100

    range_chg = np.zeros(len(c))
    raw_rng = h - l
    range_chg[1:] = np.where(raw_rng[:-1] > 1e-10, raw_rng[1:] / raw_rng[:-1] - 1, 0)

    # Rolling volume mean for relative volume
    vol_rm = np.zeros(len(v))
    for i in range(window, len(v)):
        vol_rm[i] = np.mean(v[i - window + 1:i + 1])
    vol_rm = np.maximum(vol_rm, 1e-10)
    vol_rel = v / vol_rm

    # Window-level summary features (computed per-window at encode time)
    return {
        "body": body,
        "upper_wick": upper_wick,
        "lower_wick": lower_wick,
        "close_pos": close_pos,
        "vol_rel": vol_rel,
        "ret": ret,
        "range_chg": range_chg,
        "close": c,
        "high": h,
        "low": l,
    }


def encode_raw(client, features, idx, window):
    """Encode raw candle geometry for a window ending at idx."""
    start = int(idx) - window + 1
    if start < 0:
        return None

    walkable = {}
    for name in ["body", "upper_wick", "lower_wick", "close_pos", "vol_rel", "ret", "range_chg"]:
        arr = features[name]
        walkable[name] = WalkableSpread(
            [LinearScale(float(arr[start + i])) for i in range(window)]
        )

    # Window-level summaries
    rets = features["ret"][start:start + window]
    vols = features["vol_rel"][start:start + window]
    bodies = features["body"][start:start + window]
    ranges = features["range_chg"][start:start + window]
    lows = features["low"][start:start + window]
    highs = features["high"][start:start + window]

    up_count = float(np.sum(rets > 0)) / max(window - 1, 1)
    vol_trend = float(vols[-1] / max(vols[0], 1e-10))
    body_trend = float(bodies[-1] - bodies[0])
    range_trend = float(ranges[-1])
    min_pos = float(np.argmin(lows)) / max(window - 1, 1)
    max_pos = float(np.argmax(highs)) / max(window - 1, 1)

    walkable["summary"] = {
        "up_count": LinearScale(up_count),
        "vol_trend": LinearScale(vol_trend),
        "body_trend": LinearScale(body_trend),
        "range_trend": LinearScale(range_trend),
        "min_pos": LinearScale(min_pos),
        "max_pos": LinearScale(max_pos),
    }

    return client.encoder.encode_walkable_striped(walkable, n_stripes=N_STRIPES)


def train_subspaces(client, features, labels, target_label, n_train, window, rng, n_data):
    indices = [i for i in range(window, n_data) if labels[i] == target_label]
    if len(indices) < 20:
        return None, 0
    sample = rng.choice(indices, size=min(n_train + 50, len(indices)), replace=False)
    ss = StripedSubspace(dim=DIM, k=K, n_stripes=N_STRIPES)
    count = 0
    for idx in sample:
        v = encode_raw(client, features, idx, window)
        if v is not None:
            ss.update(v)
            count += 1
        if count >= n_train:
            break
    return (ss if count >= 20 else None), count


def grade(client, subspaces, doubt, features, labels, window, rng):
    """Sample-based grading."""
    n = len(labels)
    results = {}
    for true_class in ["BUY", "SELL", "QUIET"]:
        indices = [i for i in range(window, n) if labels[i] == true_class]
        if len(indices) < 10:
            results[true_class] = {"n": 0, "accuracy": 0, "specificity": 0}
            continue
        sample = rng.choice(indices, size=min(SAMPLES_PER_CLASS, len(indices)), replace=False)
        preds = []
        doubt_catches = 0
        for idx in sample:
            v = encode_raw(client, features, idx, window)
            if v is None:
                continue
            residuals = {l: ss.residual(v) for l, ss in subspaces.items()}
            predicted = min(residuals, key=residuals.get)

            doubt_rejected = False
            if predicted in ("BUY", "SELL") and doubt:
                tk = f"TRAP_{predicted}"
                if tk in doubt and doubt[tk].residual(v) < residuals[predicted]:
                    doubt_rejected = True
                    doubt_catches += 1

            preds.append("QUIET" if doubt_rejected else predicted)

        preds = np.array(preds)
        n_tested = len(preds)
        if true_class in ("BUY", "SELL"):
            correct = (preds == true_class).sum()
            results[true_class] = {"n": n_tested, "correct": correct, "accuracy": correct / n_tested * 100 if n_tested else 0}
        else:
            quiet_ok = (preds == "QUIET").sum()
            results[true_class] = {
                "n": n_tested, "specificity": quiet_ok / n_tested * 100 if n_tested else 0,
                "false_buy": (preds == "BUY").sum(), "false_sell": (preds == "SELL").sum(),
                "doubt_catches": doubt_catches,
            }
    return results


def main():
    log("Loading data...")
    df_raw = pd.read_parquet("holon-lab-trading/data/btc_5m_raw.parquet")
    ts = pd.to_datetime(df_raw["ts"])

    df_seed = df_raw[ts <= "2020-12-31"].reset_index(drop=True)
    close_seed = df_seed["close"].values
    seed_labels = find_opportunities(close_seed, MIN_MOVE, HORIZON)
    log(f"  {(seed_labels=='BUY').sum()}B / {(seed_labels=='SELL').sum()}S / {(seed_labels=='QUIET').sum()}Q")

    periods = [
        ("2021", "2021-01-01", "2021-12-31"),
        ("2022", "2022-01-01", "2022-12-31"),
        ("2023", "2023-01-01", "2023-12-31"),
        ("2024", "2024-01-01", "2024-12-31"),
    ]

    # Precompute period data
    period_data = []
    for pname, start, end in periods:
        mask = (ts >= start) & (ts <= end)
        dp = df_raw[mask].reset_index(drop=True)
        if len(dp) < 500:
            continue
        close = dp["close"].values.astype(float)
        plabels = find_opportunities(close, MIN_MOVE, HORIZON)
        period_data.append((pname, dp, plabels))

    # Sweep: window size × n_train
    windows = [6, 12, 24]  # 30min, 1h, 2h
    n_trains = [300, 1000, 2000]

    for window in windows:
        for nt in n_trains:
            log(f"\n{'=' * 90}")
            log(f"WINDOW={window} ({window*5}min), n_train={nt}, K={K}, encoding=RAW_GEOMETRY")
            log(f"{'=' * 90}")

            client = HolonClient(dimensions=DIM)
            rng = np.random.default_rng(42)

            seed_features = precompute_raw(df_seed, window)

            t0 = time.time()
            subspaces = {}
            for label in ["BUY", "SELL", "QUIET"]:
                ss, count = train_subspaces(client, seed_features, seed_labels, label, nt, window, rng, len(df_seed))
                if ss:
                    subspaces[label] = ss
                    log(f"  {label}: {count}")
            train_time = time.time() - t0
            log(f"  Training: {train_time:.0f}s")

            if len(subspaces) < 2:
                continue

            # Find traps
            log(f"  Finding traps ({PHASE2_SCAN} windows)...")
            t0 = time.time()
            scan_idx = rng.choice(range(window, min(len(df_seed), 50_000)),
                                  size=min(PHASE2_SCAN, len(df_seed) - window), replace=False)
            trap_vecs = {"TRAP_BUY": [], "TRAP_SELL": []}
            for idx in scan_idx:
                v = encode_raw(client, seed_features, int(idx), window)
                if v is None:
                    continue
                residuals = {l: ss.residual(v) for l, ss in subspaces.items()}
                pred = min(residuals, key=residuals.get)
                actual = seed_labels[idx]
                if pred == "BUY" and actual != "BUY":
                    trap_vecs["TRAP_BUY"].append(v)
                elif pred == "SELL" and actual != "SELL":
                    trap_vecs["TRAP_SELL"].append(v)
            trap_time = time.time() - t0
            log(f"  Traps: {len(trap_vecs['TRAP_BUY'])} TB, {len(trap_vecs['TRAP_SELL'])} TS ({trap_time:.0f}s)")

            doubt = {}
            n_doubt = min(nt, 500)
            for tk, tvecs in trap_vecs.items():
                if len(tvecs) < 20:
                    continue
                ss = StripedSubspace(dim=DIM, k=K, n_stripes=N_STRIPES)
                sample = rng.choice(len(tvecs), size=min(n_doubt, len(tvecs)), replace=False)
                for i in sample:
                    ss.update(tvecs[i])
                doubt[tk] = ss

            # Grade
            log(f"\n  {'Period':8s} | {'BUY acc':>8s} | {'SELL acc':>8s} | {'QUIET spec':>10s} | {'FP buy':>7s} | {'FP sell':>7s} | {'Doubt':>6s}")
            log(f"  {'-'*8}-+-{'-'*8}-+-{'-'*8}-+-{'-'*10}-+-{'-'*7}-+-{'-'*7}-+-{'-'*6}")

            for pname, dp, plabels in period_data:
                pfeatures = precompute_raw(dp, window)
                t0 = time.time()
                r = grade(client, subspaces, doubt, pfeatures, plabels, window, rng)
                elapsed = time.time() - t0

                ba = r["BUY"].get("accuracy", 0)
                sa = r["SELL"].get("accuracy", 0)
                q = r["QUIET"]
                qs = q.get("specificity", 0)
                fb = q.get("false_buy", 0)
                fs = q.get("false_sell", 0)
                dc = q.get("doubt_catches", 0)
                log(f"  {pname:8s} | {ba:7.1f}% | {sa:7.1f}% | {qs:9.1f}% | {fb:7d} | {fs:7d} | {dc:6d} | {elapsed:.0f}s")

            # Training data grade
            r_t = grade(client, subspaces, doubt, seed_features, seed_labels, window, rng)
            ba = r_t["BUY"].get("accuracy", 0)
            sa = r_t["SELL"].get("accuracy", 0)
            qs = r_t["QUIET"].get("specificity", 0)
            log(f"  {'TRAIN':8s} | {ba:7.1f}% | {sa:7.1f}% | {qs:9.1f}% |")

    log(f"\n{'=' * 90}")
    log("DONE")
    log(f"{'=' * 90}")


if __name__ == "__main__":
    main()
