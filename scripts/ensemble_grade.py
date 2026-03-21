"""Ensemble gate — multiple concurrent perspectives composed into a signal.

Each perspective is a separate StripedSubspace with its own encoding:
  1. Candle geometry (body, wicks, close position)
  2. Momentum (RSI, MACD hist, ADX, returns)
  3. Volume profile (volume relative, volume trend)
  4. Price structure (SMA relationships, BB width)
  5. Regime (full indicator walkable — what we had before)

Each perspective produces a residual against BUY/SELL/QUIET subspaces.
The ensemble composes these residuals into a meta-feature vector that
a meta-discriminator uses to make the final BUY/SELL/QUIET decision.

The meta-discriminator is itself a subspace — it learns what COMBINATIONS
of perspective residuals precede profitable opportunities.

Usage:
    ./scripts/run_with_venv.sh python holon-lab-trading/scripts/ensemble_grade.py
"""

from __future__ import annotations

import sys
import time
from pathlib import Path

import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).parent.parent))

from trading.features import TechnicalFeatureFactory

from holon import HolonClient
from holon.kernel.walkable import LinearScale, WalkableSpread
from holon.memory import StripedSubspace

MIN_MOVE = 0.5
HORIZON = 36
SAMPLES_PER_CLASS = 500

DIM = 1024
K = 32
N_STRIPES = 32
WINDOW = 12


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
        tu = entry * (1 + min_move_pct / 100)
        td = entry * (1 - min_move_pct / 100)
        bh = sh = -1
        for j in range(i + 1, end):
            if bh < 0 and close[j] >= tu:
                bh = j
            if sh < 0 and close[j] <= td:
                sh = j
            if bh >= 0 and sh >= 0:
                break
        if bh >= 0 and (sh < 0 or bh <= sh):
            labels[i] = "BUY"
        elif sh >= 0:
            labels[i] = "SELL"
    return labels


# --- Perspective encoders ---
# Each returns a dict of WalkableSpread entries for a window ending at idx.

def precompute_all(df_ind):
    """Precompute all arrays needed by all perspectives."""
    n = len(df_ind)
    o = df_ind["open"].values.astype(float)
    h = df_ind["high"].values.astype(float)
    l = df_ind["low"].values.astype(float)
    c = df_ind["close"].values.astype(float)
    v = df_ind["volume"].values.astype(float)
    rng = np.maximum(h - l, 1e-10)

    ret = np.zeros(n)
    ret[1:] = (c[1:] / c[:-1] - 1) * 100

    range_chg = np.zeros(n)
    raw_rng = h - l
    safe = raw_rng[:-1] > 1e-10
    range_chg[1:] = np.where(safe, raw_rng[1:] / np.maximum(raw_rng[:-1], 1e-10) - 1, 0)

    vol_sma = pd.Series(v).rolling(20, min_periods=1).mean().values
    vol_rel = v / np.maximum(vol_sma, 1e-10)

    return {
        "body": (c - o) / rng,
        "upper_wick": (h - np.maximum(o, c)) / rng,
        "lower_wick": (np.minimum(o, c) - l) / rng,
        "close_pos": (c - l) / rng,
        "ret": ret,
        "range_chg": range_chg,
        "vol_rel": vol_rel,
        "rsi": df_ind["rsi"].values if "rsi" in df_ind.columns else np.full(n, 50.0),
        "macd_hist": df_ind["macd_hist_r"].values if "macd_hist_r" in df_ind.columns else np.zeros(n),
        "adx": df_ind["adx"].values if "adx" in df_ind.columns else np.full(n, 25.0),
        "sma20_r": df_ind["sma20_r"].values if "sma20_r" in df_ind.columns else np.zeros(n),
        "sma50_r": df_ind["sma50_r"].values if "sma50_r" in df_ind.columns else np.zeros(n),
        "bb_width": df_ind["bb_width"].values if "bb_width" in df_ind.columns else np.zeros(n),
        "open_r": df_ind["open_r"].values if "open_r" in df_ind.columns else np.zeros(n),
        "high_r": df_ind["high_r"].values if "high_r" in df_ind.columns else np.zeros(n),
        "low_r": df_ind["low_r"].values if "low_r" in df_ind.columns else np.zeros(n),
        "close": c,
        "high": h,
        "low": l,
    }


PERSPECTIVES = {
    "candle": ["body", "upper_wick", "lower_wick", "close_pos"],
    "momentum": ["rsi", "macd_hist", "adx", "ret"],
    "volume": ["vol_rel", "range_chg"],
    "structure": ["sma20_r", "sma50_r", "bb_width"],
    "price": ["open_r", "high_r", "low_r", "close_pos"],
}


def encode_perspective(client, features, idx, perspective_name, window=WINDOW):
    """Encode a single perspective for a window."""
    start = int(idx) - window + 1
    if start < 0:
        return None

    field_names = PERSPECTIVES[perspective_name]
    walkable = {}
    for name in field_names:
        arr = features[name]
        walkable[name] = WalkableSpread(
            [LinearScale(float(arr[start + i])) for i in range(window)]
        )
    return client.encoder.encode_walkable_striped(walkable, n_stripes=N_STRIPES)


class EnsembleGate:
    """Multiple perspectives, each with BUY/SELL/QUIET subspaces.

    Meta-discriminator learns from the composed residual profile.
    """

    def __init__(self, client: HolonClient):
        self.client = client
        self.perspectives: dict[str, dict[str, StripedSubspace]] = {}
        self.meta: dict[str, StripedSubspace] = {}

    def train_perspective(self, name, features, labels, n_train, rng, n_data):
        """Train BUY/SELL/QUIET subspaces for one perspective."""
        self.perspectives[name] = {}
        for label in ["BUY", "SELL", "QUIET"]:
            indices = [i for i in range(WINDOW, n_data) if labels[i] == label]
            if len(indices) < 20:
                continue
            sample = rng.choice(indices, size=min(n_train + 50, len(indices)), replace=False)
            ss = StripedSubspace(dim=DIM, k=K, n_stripes=N_STRIPES)
            count = 0
            for idx in sample:
                v = encode_perspective(self.client, features, idx, name)
                if v is not None:
                    ss.update(v)
                    count += 1
                if count >= n_train:
                    break
            if count >= 20:
                self.perspectives[name][label] = ss
        return len(self.perspectives[name])

    def get_residual_profile(self, features, idx):
        """Get residual profile across all perspectives.

        Returns a flat array: [p1_buy_r, p1_sell_r, p1_quiet_r, p2_buy_r, ...].
        This IS the ensemble signal — what each perspective thinks.
        """
        profile = []
        for pname in sorted(PERSPECTIVES.keys()):
            if pname not in self.perspectives:
                profile.extend([0.0, 0.0, 0.0])
                continue

            v = encode_perspective(self.client, features, idx, pname)
            if v is None:
                profile.extend([0.0, 0.0, 0.0])
                continue

            subs = self.perspectives[pname]
            for label in ["BUY", "SELL", "QUIET"]:
                if label in subs:
                    profile.append(subs[label].residual(v))
                else:
                    profile.append(0.0)

        return np.array(profile, dtype=float)

    def train_meta(self, features, labels, n_train, rng, n_data):
        """Train meta-discriminator on residual profiles."""
        log("    Training meta-discriminator on residual profiles...")
        self.meta = {}

        for label in ["BUY", "SELL", "QUIET"]:
            indices = [i for i in range(WINDOW, n_data) if labels[i] == label]
            if len(indices) < 20:
                continue
            sample = rng.choice(indices, size=min(n_train + 50, len(indices)), replace=False)

            # Meta uses a simple subspace on the residual profile vector
            profile_dim = len(PERSPECTIVES) * 3  # 5 perspectives × 3 labels = 15
            ss = StripedSubspace(dim=profile_dim, k=min(K, profile_dim - 1), n_stripes=1)
            count = 0
            for idx in sample:
                profile = self.get_residual_profile(features, idx)
                if profile is not None and len(profile) == profile_dim:
                    # StripedSubspace expects list of stripe vectors
                    ss.update([profile])
                    count += 1
                if count >= n_train:
                    break

            if count >= 20:
                self.meta[label] = ss
                log(f"      META {label}: {count} profiles")

    def classify_ensemble(self, features, idx):
        """Classify using individual perspectives (vote)."""
        votes = {"BUY": 0, "SELL": 0, "QUIET": 0}

        for pname in sorted(PERSPECTIVES.keys()):
            if pname not in self.perspectives:
                continue
            v = encode_perspective(self.client, features, idx, pname)
            if v is None:
                continue
            subs = self.perspectives[pname]
            residuals = {l: ss.residual(v) for l, ss in subs.items()}
            winner = min(residuals, key=residuals.get)
            votes[winner] += 1

        return max(votes, key=votes.get), votes

    def classify_meta(self, features, idx):
        """Classify using meta-discriminator on residual profiles."""
        if not self.meta:
            return "QUIET", {}

        profile = self.get_residual_profile(features, idx)
        profile_dim = len(PERSPECTIVES) * 3

        if len(profile) != profile_dim:
            return "QUIET", {}

        residuals = {}
        for label, ss in self.meta.items():
            residuals[label] = ss.residual([profile])

        best = min(residuals, key=residuals.get)
        return best, residuals


def grade(gate, features, labels, method="vote", rng=None):
    """Sample-based grading."""
    results = {}
    for true_class in ["BUY", "SELL", "QUIET"]:
        indices = [i for i in range(WINDOW, len(labels)) if labels[i] == true_class]
        if len(indices) < 10:
            results[true_class] = {"n": 0}
            continue
        sample = rng.choice(indices, size=min(SAMPLES_PER_CLASS, len(indices)), replace=False)
        preds = []
        for idx in sample:
            if method == "vote":
                pred, _ = gate.classify_ensemble(features, idx)
            else:
                pred, _ = gate.classify_meta(features, idx)
            preds.append(pred)

        preds = np.array(preds)
        n_t = len(preds)
        if true_class in ("BUY", "SELL"):
            correct = (preds == true_class).sum()
            results[true_class] = {"n": n_t, "accuracy": correct / n_t * 100 if n_t else 0}
        else:
            quiet_ok = (preds == "QUIET").sum()
            results[true_class] = {
                "n": n_t, "specificity": quiet_ok / n_t * 100 if n_t else 0,
                "false_buy": (preds == "BUY").sum(), "false_sell": (preds == "SELL").sum(),
            }
    return results


def main():
    log("Loading data...")
    df_raw = pd.read_parquet("holon-lab-trading/data/btc_5m_raw.parquet")
    ts = pd.to_datetime(df_raw["ts"])
    factory = TechnicalFeatureFactory()

    df_seed = df_raw[ts <= "2020-12-31"].reset_index(drop=True)
    df_seed_ind = factory.compute_indicators(df_seed)
    close_seed = df_seed_ind["close"].values
    seed_labels = find_opportunities(close_seed, MIN_MOVE, HORIZON)
    log(f"  {(seed_labels=='BUY').sum()}B / {(seed_labels=='SELL').sum()}S / {(seed_labels=='QUIET').sum()}Q")

    client = HolonClient(dimensions=DIM)
    rng = np.random.default_rng(42)

    features_seed = precompute_all(df_seed_ind)

    # Train all perspectives
    gate = EnsembleGate(client)
    n_train = 1000

    log("\nTraining perspectives...")
    for pname in sorted(PERSPECTIVES.keys()):
        t0 = time.time()
        n_cls = gate.train_perspective(pname, features_seed, seed_labels, n_train, rng, len(df_seed_ind))
        log(f"  {pname}: {n_cls} classes in {time.time()-t0:.0f}s")

    # Train meta-discriminator
    t0 = time.time()
    gate.train_meta(features_seed, seed_labels, n_train, rng, len(df_seed_ind))
    meta_time = time.time() - t0
    log(f"  Meta training: {meta_time:.0f}s")

    # Prepare periods
    periods = [
        ("2021", "2021-01-01", "2021-12-31"),
        ("2022", "2022-01-01", "2022-12-31"),
        ("2023", "2023-01-01", "2023-12-31"),
        ("2024", "2024-01-01", "2024-12-31"),
    ]

    period_data = []
    for pname, start, end in periods:
        mask = (ts >= start) & (ts <= end)
        dp = df_raw[mask].reset_index(drop=True)
        if len(dp) < 500:
            continue
        dp_ind = factory.compute_indicators(dp)
        plabels = find_opportunities(dp_ind["close"].values, MIN_MOVE, HORIZON)
        pfeatures = precompute_all(dp_ind)
        period_data.append((pname, pfeatures, plabels))

    # Grade: voting
    log(f"\n{'=' * 80}")
    log("METHOD: Majority vote across perspectives")
    log(f"{'=' * 80}")
    log(f"  {'Period':8s} | {'BUY acc':>8s} | {'SELL acc':>8s} | {'QUIET spec':>10s} | {'FP buy':>7s} | {'FP sell':>7s}")
    log(f"  {'-'*8}-+-{'-'*8}-+-{'-'*8}-+-{'-'*10}-+-{'-'*7}-+-{'-'*7}")

    for pname, pfeatures, plabels in period_data:
        t0 = time.time()
        r = grade(gate, pfeatures, plabels, method="vote", rng=rng)
        elapsed = time.time() - t0
        ba = r["BUY"].get("accuracy", 0)
        sa = r["SELL"].get("accuracy", 0)
        q = r["QUIET"]
        log(f"  {pname:8s} | {ba:7.1f}% | {sa:7.1f}% | {q.get('specificity',0):9.1f}% | {q.get('false_buy',0):7d} | {q.get('false_sell',0):7d} | {elapsed:.0f}s")

    # Training data
    r_t = grade(gate, features_seed, seed_labels, method="vote", rng=rng)
    log(f"  {'TRAIN':8s} | {r_t['BUY'].get('accuracy',0):7.1f}% | {r_t['SELL'].get('accuracy',0):7.1f}% | {r_t['QUIET'].get('specificity',0):9.1f}%")

    # Grade: meta-discriminator
    log(f"\n{'=' * 80}")
    log("METHOD: Meta-discriminator on residual profiles")
    log(f"{'=' * 80}")
    log(f"  {'Period':8s} | {'BUY acc':>8s} | {'SELL acc':>8s} | {'QUIET spec':>10s} | {'FP buy':>7s} | {'FP sell':>7s}")
    log(f"  {'-'*8}-+-{'-'*8}-+-{'-'*8}-+-{'-'*10}-+-{'-'*7}-+-{'-'*7}")

    for pname, pfeatures, plabels in period_data:
        t0 = time.time()
        r = grade(gate, pfeatures, plabels, method="meta", rng=rng)
        elapsed = time.time() - t0
        ba = r["BUY"].get("accuracy", 0)
        sa = r["SELL"].get("accuracy", 0)
        q = r["QUIET"]
        log(f"  {pname:8s} | {ba:7.1f}% | {sa:7.1f}% | {q.get('specificity',0):9.1f}% | {q.get('false_buy',0):7d} | {q.get('false_sell',0):7d} | {elapsed:.0f}s")

    r_t = grade(gate, features_seed, seed_labels, method="meta", rng=rng)
    log(f"  {'TRAIN':8s} | {r_t['BUY'].get('accuracy',0):7.1f}% | {r_t['SELL'].get('accuracy',0):7.1f}% | {r_t['QUIET'].get('specificity',0):9.1f}%")

    # Per-perspective individual accuracy (which perspectives carry weight?)
    log(f"\n{'=' * 80}")
    log("PER-PERSPECTIVE ACCURACY (individual, 2021)")
    log(f"{'=' * 80}")
    p2021_feat = period_data[0][1]
    p2021_labels = period_data[0][2]

    for pname in sorted(PERSPECTIVES.keys()):
        if pname not in gate.perspectives:
            continue
        subs = gate.perspectives[pname]
        correct_buy = correct_sell = correct_quiet = 0
        n_buy = n_sell = n_quiet = 0

        for true_class, counter_ref in [("BUY", "n_buy"), ("SELL", "n_sell"), ("QUIET", "n_quiet")]:
            indices = [i for i in range(WINDOW, len(p2021_labels)) if p2021_labels[i] == true_class]
            if len(indices) < 10:
                continue
            sample = rng.choice(indices, size=min(200, len(indices)), replace=False)
            for idx in sample:
                v = encode_perspective(client, p2021_feat, idx, pname)
                if v is None:
                    continue
                residuals = {l: ss.residual(v) for l, ss in subs.items()}
                pred = min(residuals, key=residuals.get)
                if true_class == "BUY":
                    n_buy += 1
                    if pred == "BUY":
                        correct_buy += 1
                elif true_class == "SELL":
                    n_sell += 1
                    if pred == "SELL":
                        correct_sell += 1
                else:
                    n_quiet += 1
                    if pred == "QUIET":
                        correct_quiet += 1

        ba = correct_buy / n_buy * 100 if n_buy else 0
        sa = correct_sell / n_sell * 100 if n_sell else 0
        qa = correct_quiet / n_quiet * 100 if n_quiet else 0
        log(f"  {pname:12s} | BUY {ba:5.1f}% | SELL {sa:5.1f}% | QUIET {qa:5.1f}%")

    log(f"\n{'=' * 80}")
    log("DONE")
    log(f"{'=' * 80}")


if __name__ == "__main__":
    main()
