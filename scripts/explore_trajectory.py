"""Explore per-indicator trajectory encoding.

Instead of encoding whole candle blobs and chaining them, encode each
indicator's trajectory across the window separately:
  - rsi_trajectory = chain([rsi_t0, rsi_t1, ..., rsi_t11])
  - macd_trajectory = chain([macd_t0, macd_t1, ..., macd_t11])
  - etc.

Then bundle these trajectory vectors into stripe-compatible format.
The hypothesis: trajectory shapes differ between BUY/SELL/HOLD even when
point values overlap, and engrams can learn these trajectory manifolds.

Usage:
    ./scripts/run_with_venv.sh python holon-lab-trading/scripts/explore_trajectory.py
"""

from __future__ import annotations

import sys
import time
from pathlib import Path
from typing import Any

import numpy as np
import pandas as pd
from scipy.signal import find_peaks

sys.path.insert(0, str(Path(__file__).parent.parent))

from trading.encoder import OHLCVEncoder
from trading.features import TechnicalFeatureFactory
from holon import HolonClient
from holon.kernel.encoder import Encoder as HolonEncoder, ListEncodeMode
from holon.kernel.primitives import prototype, negate
from holon.memory import StripedSubspace, OnlineSubspace

DIM = 1024
K = 4
N_STRIPES = 32
WINDOW = OHLCVEncoder.WINDOW_CANDLES


def log(msg: str):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def cos(a, b):
    na, nb = np.linalg.norm(a), np.linalg.norm(b)
    return float(np.dot(a.astype(float), b.astype(float)) / (na * nb)) if na > 1e-9 and nb > 1e-9 else 0.0


def load_data():
    log("Loading data...")
    df = pd.read_parquet("holon-lab-trading/data/btc_5m_raw.parquet")
    ts = pd.to_datetime(df["ts"])
    df_seed = df[ts <= "2020-12-31"].reset_index(drop=True)
    close = df_seed["close"].values
    prominence = float(np.median(close)) * 0.02
    peaks, _ = find_peaks(close, prominence=prominence, distance=12)
    troughs, _ = find_peaks(-close, prominence=prominence, distance=12)
    factory = TechnicalFeatureFactory()
    df_ind = factory.compute_indicators(df_seed)
    n_dropped = len(df_seed) - len(df_ind)
    peaks_ind = peaks - n_dropped
    troughs_ind = troughs - n_dropped
    peaks_ind = peaks_ind[(peaks_ind >= WINDOW) & (peaks_ind < len(df_ind))]
    troughs_ind = troughs_ind[(troughs_ind >= WINDOW) & (troughs_ind < len(df_ind))]
    log(f"  {len(troughs_ind)} BUY, {len(peaks_ind)} SELL reversals")
    return df_ind, troughs_ind, peaks_ind


def collect_leaf_paths(d: dict, prefix: str = "") -> list[str]:
    """Collect all leaf paths from a nested dict."""
    paths = []
    for k, v in d.items():
        p = f"{prefix}.{k}" if prefix else k
        if isinstance(v, dict):
            paths.extend(collect_leaf_paths(v, p))
        else:
            paths.append(p)
    return paths


def get_leaf_value(d: dict, path: str) -> Any:
    """Get value at a dotted path."""
    parts = path.split(".")
    cur = d
    for part in parts:
        cur = cur[part]
    return cur


def encode_trajectory_striped(client, encoder, df_ind, idx):
    """Encode per-indicator trajectories and distribute to stripes.

    For each indicator field (rsi, macd.line_r, etc.), collect its values
    across the 12-candle window, encode each value, and chain them into
    a trajectory vector. Then assign the trajectory to a stripe based on
    the field path hash (same FNV-1a as flat encoding).
    """
    start = int(idx) - WINDOW + 1
    if start < 0 or int(idx) >= len(df_ind):
        return None

    # Get raw candle dicts for all positions
    candle_raws = []
    for i in range(WINDOW):
        row_idx = start + i
        raw = encoder.factory.compute_candle_row(df_ind, row_idx)
        candle_raws.append(encoder._wrap_candle(raw))

    # Get all leaf paths from first candle
    leaf_paths = collect_leaf_paths(candle_raws[0])

    # For each leaf, build trajectory across window and chain-encode
    stripes = [[] for _ in range(N_STRIPES)]

    for path in leaf_paths:
        # Collect the scalar wrapper at this path across all candles
        values = []
        for candle in candle_raws:
            values.append(get_leaf_value(candle, path))

        # Encode each scalar value via a tiny walkable dict
        value_vecs = []
        for val in values:
            vec = client.encoder.encode_walkable({"_v": val})
            value_vecs.append(vec)

        # Chain the trajectory: bind(v0, bind(v1, ... bind(v10, v11)))
        trajectory = value_vecs[-1].copy()
        for prev in reversed(value_vecs[:-1]):
            trajectory = client.encoder.bind(prev, trajectory)

        # Bind with field role vector
        role = client.encoder.vector_manager.get_vector(path)
        binding = role * trajectory

        # Assign to stripe via FNV-1a
        stripe_idx = HolonEncoder.field_stripe(path, N_STRIPES)
        stripes[stripe_idx].append(binding)

    # Bundle each stripe
    result = []
    for s_bindings in stripes:
        if s_bindings:
            bundled = np.sum(np.stack(s_bindings), axis=0)
            result.append(np.sign(bundled).astype(np.int8))
        else:
            result.append(np.zeros(DIM, dtype=np.int8))

    return result


def encode_trajectory_ngram_striped(client, encoder, df_ind, idx, n=2):
    """Like trajectory but using n-gram instead of chaining."""
    start = int(idx) - WINDOW + 1
    if start < 0 or int(idx) >= len(df_ind):
        return None

    candle_raws = []
    for i in range(WINDOW):
        row_idx = start + i
        raw = encoder.factory.compute_candle_row(df_ind, row_idx)
        candle_raws.append(encoder._wrap_candle(raw))

    leaf_paths = collect_leaf_paths(candle_raws[0])
    stripes = [[] for _ in range(N_STRIPES)]

    for path in leaf_paths:
        values = [get_leaf_value(candle, path) for candle in candle_raws]

        value_vecs = []
        for val in values:
            vec = client.encoder.encode_walkable({"_v": val})
            value_vecs.append(vec)

        # N-gram: bind consecutive pairs/triples, then bundle
        ngrams = []
        for i in range(len(value_vecs) - n + 1):
            gram = value_vecs[i]
            for j in range(1, n):
                gram = client.encoder.bind(gram, value_vecs[i + j])
            ngrams.append(gram)
        trajectory = np.sum(np.stack(ngrams), axis=0)
        trajectory = np.sign(trajectory).astype(np.int8)

        role = client.encoder.vector_manager.get_vector(path)
        binding = role * trajectory
        stripe_idx = HolonEncoder.field_stripe(path, N_STRIPES)
        stripes[stripe_idx].append(binding)

    result = []
    for s_bindings in stripes:
        if s_bindings:
            bundled = np.sum(np.stack(s_bindings), axis=0)
            result.append(np.sign(bundled).astype(np.int8))
        else:
            result.append(np.zeros(DIM, dtype=np.int8))
    return result


def encode_hybrid_striped(client, encoder, df_ind, idx):
    """Hybrid: flat values + trajectory chains in the same stripe.

    Each stripe gets both:
    - The flat tN-keyed bindings (point values at each time)
    - The chained trajectory binding (temporal shape)
    """
    start = int(idx) - WINDOW + 1
    if start < 0 or int(idx) >= len(df_ind):
        return None

    w = df_ind.iloc[start:int(idx) + 1]
    if len(w) < WINDOW:
        return None

    # Get flat striped encoding (baseline)
    flat_stripes = encoder.encode_from_precomputed(w)

    # Get trajectory encoding
    traj_stripes = encode_trajectory_striped(client, encoder, df_ind, idx)
    if traj_stripes is None:
        return None

    # Combine: bundle flat + trajectory per stripe
    result = []
    for s in range(N_STRIPES):
        combined = flat_stripes[s].astype(np.float64) + traj_stripes[s].astype(np.float64)
        result.append(np.sign(combined).astype(np.int8))
    return result


def encode_windows(func, indices, max_n=200):
    vecs = []
    for idx in indices[:max_n + 50]:
        try:
            v = func(idx)
            if v is not None:
                vecs.append(v)
        except Exception as e:
            if len(vecs) < 3:
                log(f"    encode error: {e}")
            continue
        if len(vecs) >= max_n:
            break
    return vecs


def measure_striped(name, buy_vecs, sell_vecs, hold_vecs, n_train=120, n_test=50):
    if len(buy_vecs) < n_train + n_test or len(sell_vecs) < n_train + n_test:
        log(f"  {name}: insufficient data (b={len(buy_vecs)} s={len(sell_vecs)})")
        return None

    ss_b = StripedSubspace(dim=DIM, k=K, n_stripes=N_STRIPES)
    ss_s = StripedSubspace(dim=DIM, k=K, n_stripes=N_STRIPES)
    ss_h = StripedSubspace(dim=DIM, k=K, n_stripes=N_STRIPES)
    for v in buy_vecs[:n_train]: ss_b.update(v)
    for v in sell_vecs[:n_train]: ss_s.update(v)
    for v in hold_vecs[:min(n_train, len(hold_vecs))]: ss_h.update(v)

    correct, total, margins, buy_seps, sell_seps = 0, 0, [], [], []
    test_b = buy_vecs[n_train:n_train + n_test]
    test_s = sell_vecs[n_train:n_train + n_test]
    test_h = hold_vecs[min(n_train, len(hold_vecs)):min(n_train, len(hold_vecs)) + n_test]

    for li, ts in [(0, test_b), (1, test_s), (2, test_h)]:
        for v in ts:
            rs = [ss_b.residual(v), ss_s.residual(v), ss_h.residual(v)]
            if int(np.argmin(rs)) == li: correct += 1
            total += 1
            sr = sorted(rs)
            margins.append(sr[1] - sr[0])
    for v in test_b: buy_seps.append(ss_h.residual(v) - ss_b.residual(v))
    for v in test_s: sell_seps.append(ss_h.residual(v) - ss_s.residual(v))

    acc = correct / total * 100
    align = ss_b._stripes[0].subspace_alignment(ss_s._stripes[0])
    log(f"  {name}: acc={acc:.0f}%  margin={np.mean(margins):.2f}  "
        f"buy_sep={np.mean(buy_seps):+.1f}  sell_sep={np.mean(sell_seps):+.1f}  "
        f"B-S align={align:.3f}")
    return {"accuracy": acc, "margin": np.mean(margins),
            "buy_sep": np.mean(buy_seps), "sell_sep": np.mean(sell_seps)}


def main():
    df_ind, troughs_ind, peaks_ind = load_data()
    client = HolonClient(dimensions=DIM)
    encoder = OHLCVEncoder(client, n_stripes=N_STRIPES)
    rng = np.random.default_rng(42)

    rev_set = set(troughs_ind.tolist()) | set(peaks_ind.tolist())
    hold_pool = [i for i in range(WINDOW + 1, len(df_ind)) if i not in rev_set]
    hold_sample = rng.choice(hold_pool, size=400, replace=False)

    log(f"  Leaf paths per candle: {len(collect_leaf_paths(encoder._wrap_candle(encoder.factory.compute_candle_row(df_ind, WINDOW))))}")

    # ===================================================================
    # BASELINE
    # ===================================================================
    log("\n" + "=" * 70)
    log("BASELINE: flat tN-keyed walkable → striped")
    log("=" * 70)

    def enc_flat(idx):
        start = int(idx) - WINDOW + 1
        w = df_ind.iloc[start:int(idx) + 1]
        return encoder.encode_from_precomputed(w) if len(w) >= WINDOW else None

    buy_flat = encode_windows(enc_flat, troughs_ind, 200)
    sell_flat = encode_windows(enc_flat, peaks_ind, 200)
    hold_flat = encode_windows(enc_flat, hold_sample, 200)
    log(f"  {len(buy_flat)} BUY, {len(sell_flat)} SELL, {len(hold_flat)} HOLD")
    measure_striped("FLAT_STRIPED", buy_flat, sell_flat, hold_flat)

    # ===================================================================
    # EXP 1: Per-indicator chained trajectory → striped
    # ===================================================================
    log("\n" + "=" * 70)
    log("EXP 1: Per-indicator CHAINED trajectory → striped")
    log("  Each indicator's 12-step trajectory chained, then striped by field path")
    log("=" * 70)

    def enc_traj(idx):
        return encode_trajectory_striped(client, encoder, df_ind, idx)

    buy_tr = encode_windows(enc_traj, troughs_ind, 200)
    sell_tr = encode_windows(enc_traj, peaks_ind, 200)
    hold_tr = encode_windows(enc_traj, hold_sample, 200)
    log(f"  {len(buy_tr)} BUY, {len(sell_tr)} SELL, {len(hold_tr)} HOLD")
    if buy_tr:
        measure_striped("TRAJECTORY_CHAINED", buy_tr, sell_tr, hold_tr)

    # ===================================================================
    # EXP 2: Per-indicator 2-gram trajectory → striped
    # ===================================================================
    log("\n" + "=" * 70)
    log("EXP 2: Per-indicator 2-GRAM trajectory → striped")
    log("  Consecutive value pairs bound, then bundled per indicator")
    log("=" * 70)

    def enc_traj_ng(idx):
        return encode_trajectory_ngram_striped(client, encoder, df_ind, idx, n=2)

    buy_tn = encode_windows(enc_traj_ng, troughs_ind, 200)
    sell_tn = encode_windows(enc_traj_ng, peaks_ind, 200)
    hold_tn = encode_windows(enc_traj_ng, hold_sample, 200)
    log(f"  {len(buy_tn)} BUY, {len(sell_tn)} SELL, {len(hold_tn)} HOLD")
    if buy_tn:
        measure_striped("TRAJECTORY_2GRAM", buy_tn, sell_tn, hold_tn)

    # ===================================================================
    # EXP 3: Hybrid — flat values + trajectory in same stripe
    # ===================================================================
    log("\n" + "=" * 70)
    log("EXP 3: HYBRID — flat values + chained trajectory per stripe")
    log("  Combines point-in-time values with temporal shape")
    log("=" * 70)

    def enc_hybrid(idx):
        return encode_hybrid_striped(client, encoder, df_ind, idx)

    buy_hy = encode_windows(enc_hybrid, troughs_ind, 200)
    sell_hy = encode_windows(enc_hybrid, peaks_ind, 200)
    hold_hy = encode_windows(enc_hybrid, hold_sample, 200)
    log(f"  {len(buy_hy)} BUY, {len(sell_hy)} SELL, {len(hold_hy)} HOLD")
    if buy_hy:
        measure_striped("HYBRID", buy_hy, sell_hy, hold_hy)

    log("\n" + "=" * 70)
    log("DONE")
    log("=" * 70)


if __name__ == "__main__":
    main()
