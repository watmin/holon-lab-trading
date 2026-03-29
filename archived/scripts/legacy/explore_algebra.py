"""Explore Holon algebra primitives for trading discrimination.

Tests difference, prototype, negate, resonance, and segment against
the labeled reversal data to find which techniques improve BUY/SELL/HOLD
separation beyond raw window encoding.

Usage:
    ./scripts/run_with_venv.sh python holon-lab-trading/scripts/explore_algebra.py 2>&1 | tee holon-lab-trading/data/algebra_exploration.log
"""

from __future__ import annotations

import sys
import time
from pathlib import Path

import numpy as np
import pandas as pd
from scipy.signal import find_peaks

sys.path.insert(0, str(Path(__file__).parent.parent))

from trading.encoder import OHLCVEncoder
from trading.features import TechnicalFeatureFactory
from holon import HolonClient
from holon.kernel.primitives import (
    difference, prototype, negate, resonance, similarity_profile, blend,
)
from holon.memory import StripedSubspace

DIM = 1024
K = 4
N_STRIPES = 32
WINDOW = OHLCVEncoder.WINDOW_CANDLES


def log(msg: str):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


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
    peaks_ind = peaks_ind[peaks_ind >= WINDOW + 1]
    troughs_ind = troughs_ind[troughs_ind >= WINDOW + 1]

    log(f"  {len(troughs_ind)} BUY, {len(peaks_ind)} SELL reversals (encodable)")
    return df_ind, troughs_ind, peaks_ind


def encode_windows(encoder, df_ind, indices, max_n=200):
    vecs = []
    for idx in indices[:max_n + 50]:
        start = int(idx) - WINDOW + 1
        if start < 0 or int(idx) >= len(df_ind):
            continue
        w = df_ind.iloc[start:int(idx) + 1]
        if len(w) < WINDOW:
            continue
        try:
            v = encoder.encode_from_precomputed(w)
            vecs.append(v)
        except Exception:
            continue
        if len(vecs) >= max_n:
            break
    return vecs


def encode_window_pairs(encoder, df_ind, indices, max_n=200):
    """Encode consecutive window pairs for difference computation."""
    pairs = []
    for idx in indices[:max_n + 50]:
        idx = int(idx)
        start_curr = idx - WINDOW + 1
        start_prev = idx - WINDOW  # one candle earlier
        if start_prev < 0 or idx >= len(df_ind):
            continue
        w_curr = df_ind.iloc[start_curr:idx + 1]
        w_prev = df_ind.iloc[start_prev:idx]
        if len(w_curr) < WINDOW or len(w_prev) < WINDOW:
            continue
        try:
            v_curr = encoder.encode_from_precomputed(w_curr)
            v_prev = encoder.encode_from_precomputed(w_prev)
            pairs.append((v_prev, v_curr))
        except Exception:
            continue
        if len(pairs) >= max_n:
            break
    return pairs


def measure_separation(name, buy_vecs, sell_vecs, hold_vecs, n_train=120, n_test=50):
    """Train per-class subspaces and measure discrimination."""
    if len(buy_vecs) < n_train + n_test or len(sell_vecs) < n_train + n_test:
        log(f"  {name}: insufficient data (buy={len(buy_vecs)}, sell={len(sell_vecs)})")
        return None

    ss_b = StripedSubspace(dim=DIM, k=K, n_stripes=N_STRIPES)
    ss_s = StripedSubspace(dim=DIM, k=K, n_stripes=N_STRIPES)
    ss_h = StripedSubspace(dim=DIM, k=K, n_stripes=N_STRIPES)

    for v in buy_vecs[:n_train]:
        ss_b.update(v)
    for v in sell_vecs[:n_train]:
        ss_s.update(v)
    for v in hold_vecs[:min(n_train, len(hold_vecs))]:
        ss_h.update(v)

    test_buy = buy_vecs[n_train:n_train + n_test]
    test_sell = sell_vecs[n_train:n_train + n_test]
    test_hold = hold_vecs[min(n_train, len(hold_vecs)):min(n_train, len(hold_vecs)) + n_test]

    correct = 0
    total = 0
    margins = []
    buy_seps = []
    sell_seps = []

    for label_idx, test_set in [(0, test_buy), (1, test_sell), (2, test_hold)]:
        for v in test_set:
            rs = [ss_b.residual(v), ss_s.residual(v), ss_h.residual(v)]
            best = int(np.argmin(rs))
            if best == label_idx:
                correct += 1
            total += 1
            sorted_r = sorted(rs)
            margins.append(sorted_r[1] - sorted_r[0])

    for v in test_buy:
        buy_seps.append(ss_h.residual(v) - ss_b.residual(v))
    for v in test_sell:
        sell_seps.append(ss_h.residual(v) - ss_s.residual(v))

    accuracy = correct / total * 100 if total > 0 else 0
    align = ss_b._stripes[0].subspace_alignment(ss_s._stripes[0])

    result = {
        "accuracy": accuracy,
        "margin": np.mean(margins),
        "buy_sep": np.mean(buy_seps),
        "sell_sep": np.mean(sell_seps),
        "alignment": align,
    }

    log(f"  {name}: acc={accuracy:.0f}%  margin={np.mean(margins):.2f}  "
        f"buy_sep={np.mean(buy_seps):+.1f}  sell_sep={np.mean(sell_seps):+.1f}  "
        f"B-S align={align:.3f}")
    return result


def main():
    df_ind, troughs_ind, peaks_ind = load_data()

    client = HolonClient(dimensions=DIM)
    encoder = OHLCVEncoder(client, n_stripes=N_STRIPES)
    rng = np.random.default_rng(42)

    # HOLD indices
    rev_set = set(troughs_ind.tolist()) | set(peaks_ind.tolist())
    hold_pool = [i for i in range(WINDOW + 1, len(df_ind)) if i not in rev_set]
    hold_sample = rng.choice(hold_pool, size=400, replace=False)

    # ===================================================================
    # EXPERIMENT 1: BASELINE — raw window encoding (what we have now)
    # ===================================================================
    log("\n" + "=" * 70)
    log("EXPERIMENT 1: BASELINE — raw window encoding")
    log("=" * 70)
    buy_raw = encode_windows(encoder, df_ind, troughs_ind, max_n=200)
    sell_raw = encode_windows(encoder, df_ind, peaks_ind, max_n=200)
    hold_raw = encode_windows(encoder, df_ind, hold_sample, max_n=200)
    log(f"  Encoded: {len(buy_raw)} BUY, {len(sell_raw)} SELL, {len(hold_raw)} HOLD")
    baseline = measure_separation("BASELINE", buy_raw, sell_raw, hold_raw)

    # ===================================================================
    # EXPERIMENT 2: DIFFERENCE — encode transitions, not states
    # ===================================================================
    log("\n" + "=" * 70)
    log("EXPERIMENT 2: DIFFERENCE — encode transitions")
    log("  difference(window_t-1, window_t) per stripe")
    log("=" * 70)

    buy_pairs = encode_window_pairs(encoder, df_ind, troughs_ind, max_n=200)
    sell_pairs = encode_window_pairs(encoder, df_ind, peaks_ind, max_n=200)
    hold_pairs = encode_window_pairs(encoder, df_ind, hold_sample, max_n=200)

    buy_diff = [
        [difference(prev[s], curr[s]) for s in range(N_STRIPES)]
        for prev, curr in buy_pairs
    ]
    sell_diff = [
        [difference(prev[s], curr[s]) for s in range(N_STRIPES)]
        for prev, curr in sell_pairs
    ]
    hold_diff = [
        [difference(prev[s], curr[s]) for s in range(N_STRIPES)]
        for prev, curr in hold_pairs
    ]
    log(f"  Encoded: {len(buy_diff)} BUY, {len(sell_diff)} SELL, {len(hold_diff)} HOLD diffs")
    diff_result = measure_separation("DIFFERENCE", buy_diff, sell_diff, hold_diff)

    # ===================================================================
    # EXPERIMENT 3: PROTOTYPE + NEGATE — extract class-specific signal
    # ===================================================================
    log("\n" + "=" * 70)
    log("EXPERIMENT 3: PROTOTYPE + NEGATE")
    log("  Extract BUY prototype, negate HOLD prototype from it")
    log("=" * 70)

    # Compute per-stripe prototypes
    buy_protos = []
    sell_protos = []
    hold_protos = []
    for s in range(N_STRIPES):
        bp = prototype([v[s] for v in buy_raw[:100]])
        sp = prototype([v[s] for v in sell_raw[:100]])
        hp = prototype([v[s] for v in hold_raw[:100]])
        buy_protos.append(bp)
        sell_protos.append(sp)
        hold_protos.append(hp)

    # Negate hold from buy/sell to get "what's unique about reversals"
    buy_signal = [negate(buy_protos[s], hold_protos[s]) for s in range(N_STRIPES)]
    sell_signal = [negate(sell_protos[s], hold_protos[s]) for s in range(N_STRIPES)]

    # Cosine between raw windows and the cleaned signal
    def cos(a, b):
        na, nb = np.linalg.norm(a), np.linalg.norm(b)
        return float(np.dot(a, b) / (na * nb)) if na > 1e-9 and nb > 1e-9 else 0.0

    # Measure: does the negated signal discriminate?
    buy_cos_buy = [np.mean([cos(v[s].astype(float), buy_signal[s].astype(float))
                           for s in range(N_STRIPES)]) for v in buy_raw[100:150]]
    sell_cos_buy = [np.mean([cos(v[s].astype(float), buy_signal[s].astype(float))
                            for s in range(N_STRIPES)]) for v in sell_raw[100:150]]
    hold_cos_buy = [np.mean([cos(v[s].astype(float), buy_signal[s].astype(float))
                            for s in range(N_STRIPES)]) for v in hold_raw[100:150]]

    buy_cos_sell = [np.mean([cos(v[s].astype(float), sell_signal[s].astype(float))
                            for s in range(N_STRIPES)]) for v in buy_raw[100:150]]
    sell_cos_sell = [np.mean([cos(v[s].astype(float), sell_signal[s].astype(float))
                             for s in range(N_STRIPES)]) for v in sell_raw[100:150]]
    hold_cos_sell = [np.mean([cos(v[s].astype(float), sell_signal[s].astype(float))
                             for s in range(N_STRIPES)]) for v in hold_raw[100:150]]

    log(f"  Against BUY_signal:  BUY={np.mean(buy_cos_buy):.4f}  "
        f"SELL={np.mean(sell_cos_buy):.4f}  HOLD={np.mean(hold_cos_buy):.4f}")
    log(f"  Against SELL_signal: BUY={np.mean(buy_cos_sell):.4f}  "
        f"SELL={np.mean(sell_cos_sell):.4f}  HOLD={np.mean(hold_cos_sell):.4f}")

    # Sparsity of the negated signals
    buy_nonzero = np.mean([np.count_nonzero(buy_signal[s]) / DIM for s in range(N_STRIPES)])
    sell_nonzero = np.mean([np.count_nonzero(sell_signal[s]) / DIM for s in range(N_STRIPES)])
    log(f"  Signal density: BUY={buy_nonzero:.1%}  SELL={sell_nonzero:.1%}")

    # ===================================================================
    # EXPERIMENT 4: RESONANCE — filter windows through prototype
    # ===================================================================
    log("\n" + "=" * 70)
    log("EXPERIMENT 4: RESONANCE — filter windows through class signal")
    log("  resonance(window, buy_signal) keeps only BUY-consistent dims")
    log("=" * 70)

    buy_res = [
        [resonance(v[s], buy_signal[s]) for s in range(N_STRIPES)]
        for v in buy_raw
    ]
    sell_res = [
        [resonance(v[s], buy_signal[s]) for s in range(N_STRIPES)]
        for v in sell_raw
    ]
    hold_res = [
        [resonance(v[s], buy_signal[s]) for s in range(N_STRIPES)]
        for v in hold_raw
    ]
    log(f"  Filtered: {len(buy_res)} BUY, {len(sell_res)} SELL, {len(hold_res)} HOLD")
    res_result = measure_separation("RESONANCE(buy_signal)", buy_res, sell_res, hold_res)

    # ===================================================================
    # EXPERIMENT 5: DIFFERENCE + RESONANCE combo
    # ===================================================================
    log("\n" + "=" * 70)
    log("EXPERIMENT 5: DIFFERENCE + RESONANCE combo")
    log("  difference(prev, curr) then resonance with buy_signal")
    log("=" * 70)

    # Build diff prototypes
    buy_diff_protos = []
    hold_diff_protos = []
    for s in range(N_STRIPES):
        bdp = prototype([v[s] for v in buy_diff[:80]])
        hdp = prototype([v[s] for v in hold_diff[:80]])
        buy_diff_protos.append(bdp)
        hold_diff_protos.append(hdp)

    buy_diff_signal = [negate(buy_diff_protos[s], hold_diff_protos[s])
                       for s in range(N_STRIPES)]

    buy_dr = [
        [resonance(v[s], buy_diff_signal[s]) for s in range(N_STRIPES)]
        for v in buy_diff
    ]
    sell_dr = [
        [resonance(v[s], buy_diff_signal[s]) for s in range(N_STRIPES)]
        for v in sell_diff
    ]
    hold_dr = [
        [resonance(v[s], buy_diff_signal[s]) for s in range(N_STRIPES)]
        for v in hold_diff
    ]
    log(f"  Filtered diffs: {len(buy_dr)} BUY, {len(sell_dr)} SELL, {len(hold_dr)} HOLD")
    dr_result = measure_separation("DIFF+RESONANCE", buy_dr, sell_dr, hold_dr)

    # ===================================================================
    # EXPERIMENT 6: SIMILARITY_PROFILE — per-dimension agreement
    # ===================================================================
    log("\n" + "=" * 70)
    log("EXPERIMENT 6: SIMILARITY_PROFILE as features")
    log("  similarity_profile(window, buy_proto) per stripe → discrimination")
    log("=" * 70)

    buy_sp = [
        [similarity_profile(v[s], buy_protos[s]) for s in range(N_STRIPES)]
        for v in buy_raw
    ]
    sell_sp = [
        [similarity_profile(v[s], buy_protos[s]) for s in range(N_STRIPES)]
        for v in sell_raw
    ]
    hold_sp = [
        [similarity_profile(v[s], buy_protos[s]) for s in range(N_STRIPES)]
        for v in hold_raw
    ]
    log(f"  Profiles: {len(buy_sp)} BUY, {len(sell_sp)} SELL, {len(hold_sp)} HOLD")
    sp_result = measure_separation("SIM_PROFILE(buy_proto)", buy_sp, sell_sp, hold_sp)

    # ===================================================================
    # SUMMARY
    # ===================================================================
    log("\n" + "=" * 70)
    log("SUMMARY — Separation from HOLD (higher = better)")
    log("=" * 70)

    results = [
        ("BASELINE (raw window)", baseline),
        ("DIFFERENCE (transitions)", diff_result),
        ("RESONANCE (buy filter)", res_result),
        ("DIFF + RESONANCE", dr_result),
        ("SIMILARITY_PROFILE", sp_result),
    ]

    for name, r in results:
        if r is None:
            log(f"  {name:>35s}: FAILED")
        else:
            log(f"  {name:>35s}: acc={r['accuracy']:.0f}%  "
                f"margin={r['margin']:.2f}  "
                f"buy_sep={r['buy_sep']:+.1f}  "
                f"sell_sep={r['sell_sep']:+.1f}  "
                f"B-S_align={r['alignment']:.3f}")


if __name__ == "__main__":
    main()
