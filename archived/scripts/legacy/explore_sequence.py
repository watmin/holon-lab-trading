"""Explore sequence-based encoding of candle windows.

Instead of encoding all 12 candles as one flat walkable dict, encode each
candle as its own vector and use Holon's list encoding modes (positional,
chained, ngram) to capture temporal dynamics.

Tests whether this approach produces better reversal discrimination than
the flat walkable approach.

Usage:
    ./scripts/run_with_venv.sh python holon-lab-trading/scripts/explore_sequence.py
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
from holon.kernel.encoder import ListEncodeMode
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


def encode_candle_sequence(client, encoder, df_ind, idx, mode="chained"):
    """Encode a window as a sequence of per-candle vectors.

    1. Build each candle's walkable dict (just the candle blob, no tN prefix)
    2. Encode each candle into a single vector via encode_walkable
    3. Compose the sequence using encode_list with the specified mode
    """
    start = int(idx) - WINDOW + 1
    if start < 0 or int(idx) >= len(df_ind):
        return None

    candle_vecs = []
    for i in range(WINDOW):
        row_idx = start + i
        candle_raw = encoder.factory.compute_candle_row(df_ind, row_idx)
        candle_walkable = encoder._wrap_candle(candle_raw)
        vec = client.encoder.encode_walkable(candle_walkable)
        candle_vecs.append(vec)

    return client.encoder.encode_list(candle_vecs, mode=mode)


def encode_candle_sequence_striped(client, encoder, df_ind, idx, mode="chained"):
    """Encode a window as sequence of per-candle vecs, then stripe the result.

    Each candle is encoded independently. The list encoding composes them.
    Then we use the FQDN paths from a single candle to distribute into stripes.

    Alternative: encode each candle striped, then compose per-stripe sequences.
    """
    start = int(idx) - WINDOW + 1
    if start < 0 or int(idx) >= len(df_ind):
        return None

    # Approach: encode per-stripe sequences
    # For each stripe, gather the per-candle contributions to that stripe,
    # then compose the sequence within each stripe
    per_stripe_candles = [[] for _ in range(N_STRIPES)]

    for i in range(WINDOW):
        row_idx = start + i
        candle_raw = encoder.factory.compute_candle_row(df_ind, row_idx)
        candle_walkable = encoder._wrap_candle(candle_raw)
        stripe_vecs = client.encoder.encode_walkable_striped(
            candle_walkable, n_stripes=N_STRIPES
        )
        for s in range(N_STRIPES):
            per_stripe_candles[s].append(stripe_vecs[s])

    result = []
    for s in range(N_STRIPES):
        seq_vec = client.encoder.encode_list(per_stripe_candles[s], mode=mode)
        result.append(seq_vec)
    return result


def encode_windows_seq(client, encoder, df_ind, indices, mode, striped, max_n=200):
    vecs = []
    for idx in indices[:max_n + 50]:
        try:
            if striped:
                v = encode_candle_sequence_striped(client, encoder, df_ind, idx, mode)
            else:
                v = encode_candle_sequence(client, encoder, df_ind, idx, mode)
            if v is not None:
                vecs.append(v)
        except Exception as e:
            continue
        if len(vecs) >= max_n:
            break
    return vecs


def measure_separation_single(name, buy_vecs, sell_vecs, hold_vecs, n_train=120, n_test=50):
    """Measure separation using OnlineSubspace (single-vector, not striped)."""
    if len(buy_vecs) < n_train + n_test or len(sell_vecs) < n_train + n_test:
        log(f"  {name}: insufficient data")
        return None

    ss_b = OnlineSubspace(dim=DIM, k=K)
    ss_s = OnlineSubspace(dim=DIM, k=K)
    ss_h = OnlineSubspace(dim=DIM, k=K)

    for v in buy_vecs[:n_train]:
        ss_b.update(v)
    for v in sell_vecs[:n_train]:
        ss_s.update(v)
    for v in hold_vecs[:min(n_train, len(hold_vecs))]:
        ss_h.update(v)

    correct = 0
    total = 0
    margins = []
    buy_seps = []
    sell_seps = []

    test_buy = buy_vecs[n_train:n_train + n_test]
    test_sell = sell_vecs[n_train:n_train + n_test]
    test_hold = hold_vecs[min(n_train, len(hold_vecs)):min(n_train, len(hold_vecs)) + n_test]

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
    align = ss_b.subspace_alignment(ss_s)

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


def measure_separation_striped(name, buy_vecs, sell_vecs, hold_vecs, n_train=120, n_test=50):
    """Measure separation using StripedSubspace."""
    if len(buy_vecs) < n_train + n_test or len(sell_vecs) < n_train + n_test:
        log(f"  {name}: insufficient data")
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

    correct = 0
    total = 0
    margins = []
    buy_seps = []
    sell_seps = []

    test_buy = buy_vecs[n_train:n_train + n_test]
    test_sell = sell_vecs[n_train:n_train + n_test]
    test_hold = hold_vecs[min(n_train, len(hold_vecs)):min(n_train, len(hold_vecs)) + n_test]

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


def measure_prototype(name, buy_vecs, sell_vecs, hold_vecs, n_train=120, n_test=50):
    """Measure prototype scoring discrimination (single-vector)."""
    if len(buy_vecs) < n_train + n_test or len(sell_vecs) < n_train + n_test:
        log(f"  {name}: insufficient data")
        return None

    bp = prototype([v for v in buy_vecs[:n_train]])
    sp = prototype([v for v in sell_vecs[:n_train]])
    hp = prototype([v for v in hold_vecs[:min(n_train, len(hold_vecs))]])

    buy_signal = negate(bp, hp)
    sell_signal = negate(sp, hp)

    test_buy = buy_vecs[n_train:n_train + n_test]
    test_sell = sell_vecs[n_train:n_train + n_test]
    test_hold = hold_vecs[min(n_train, len(hold_vecs)):min(n_train, len(hold_vecs)) + n_test]

    correct = 0
    total = 0
    for true_label, test_set in [("BUY", test_buy), ("SELL", test_sell), ("HOLD", test_hold)]:
        for v in test_set:
            bs = cos(v.astype(float), buy_signal.astype(float))
            ss = cos(v.astype(float), sell_signal.astype(float))
            if bs > ss and bs > 0.05:
                pred = "BUY"
            elif ss > bs and ss > 0.05:
                pred = "SELL"
            else:
                pred = "HOLD"
            if pred == true_label:
                correct += 1
            total += 1

    accuracy = correct / total * 100
    # Mean scores for BUY test windows
    buy_cos_buy = np.mean([cos(v.astype(float), buy_signal.astype(float)) for v in test_buy])
    sell_cos_sell = np.mean([cos(v.astype(float), sell_signal.astype(float)) for v in test_sell])
    hold_cos_buy = np.mean([cos(v.astype(float), buy_signal.astype(float)) for v in test_hold])

    log(f"  {name}: acc={accuracy:.0f}%  "
        f"buy→buy_sig={buy_cos_buy:+.4f}  sell→sell_sig={sell_cos_sell:+.4f}  "
        f"hold→buy_sig={hold_cos_buy:+.4f}")
    return {"accuracy": accuracy, "buy_cos": buy_cos_buy, "sell_cos": sell_cos_sell,
            "hold_cos": hold_cos_buy}


def main():
    df_ind, troughs_ind, peaks_ind = load_data()

    client = HolonClient(dimensions=DIM)
    encoder = OHLCVEncoder(client, n_stripes=N_STRIPES)
    rng = np.random.default_rng(42)

    rev_set = set(troughs_ind.tolist()) | set(peaks_ind.tolist())
    hold_pool = [i for i in range(WINDOW + 1, len(df_ind)) if i not in rev_set]
    hold_sample = rng.choice(hold_pool, size=400, replace=False)

    # ===================================================================
    # BASELINE: current flat walkable (for comparison)
    # ===================================================================
    log("\n" + "=" * 70)
    log("BASELINE: flat walkable → striped subspace")
    log("=" * 70)
    buy_flat = encode_windows_seq(client, encoder, df_ind, troughs_ind,
                                  mode=None, striped=False, max_n=200)
    # Use the existing encode_from_precomputed for baseline
    buy_flat_s = []
    sell_flat_s = []
    hold_flat_s = []
    for idx in troughs_ind[:250]:
        start = int(idx) - WINDOW + 1
        if start < 0 or int(idx) >= len(df_ind):
            continue
        w = df_ind.iloc[start:int(idx) + 1]
        if len(w) < WINDOW:
            continue
        try:
            v = encoder.encode_from_precomputed(w)
            buy_flat_s.append(v)
        except Exception:
            continue
        if len(buy_flat_s) >= 200:
            break

    for idx in peaks_ind[:250]:
        start = int(idx) - WINDOW + 1
        if start < 0 or int(idx) >= len(df_ind):
            continue
        w = df_ind.iloc[start:int(idx) + 1]
        if len(w) < WINDOW:
            continue
        try:
            v = encoder.encode_from_precomputed(w)
            sell_flat_s.append(v)
        except Exception:
            continue
        if len(sell_flat_s) >= 200:
            break

    for idx in hold_sample[:250]:
        start = int(idx) - WINDOW + 1
        if start < 0 or int(idx) >= len(df_ind):
            continue
        w = df_ind.iloc[start:int(idx) + 1]
        if len(w) < WINDOW:
            continue
        try:
            v = encoder.encode_from_precomputed(w)
            hold_flat_s.append(v)
        except Exception:
            continue
        if len(hold_flat_s) >= 200:
            break

    log(f"  Encoded: {len(buy_flat_s)} BUY, {len(sell_flat_s)} SELL, {len(hold_flat_s)} HOLD")
    measure_separation_striped("FLAT_STRIPED (baseline)", buy_flat_s, sell_flat_s, hold_flat_s)

    # ===================================================================
    # EXPERIMENT 1: Chained encoding → single vector
    # ===================================================================
    log("\n" + "=" * 70)
    log("EXPERIMENT 1: CHAINED encoding → single vector → OnlineSubspace")
    log("  bind(t0, bind(t1, ... bind(t10, t11)))")
    log("=" * 70)
    buy_ch = encode_windows_seq(client, encoder, df_ind, troughs_ind,
                                mode="chained", striped=False, max_n=200)
    sell_ch = encode_windows_seq(client, encoder, df_ind, peaks_ind,
                                mode="chained", striped=False, max_n=200)
    hold_ch = encode_windows_seq(client, encoder, df_ind, hold_sample,
                                mode="chained", striped=False, max_n=200)
    log(f"  Encoded: {len(buy_ch)} BUY, {len(sell_ch)} SELL, {len(hold_ch)} HOLD")
    measure_separation_single("CHAINED_SINGLE", buy_ch, sell_ch, hold_ch)
    measure_prototype("CHAINED_PROTO", buy_ch, sell_ch, hold_ch)

    # ===================================================================
    # EXPERIMENT 2: Positional encoding → single vector
    # ===================================================================
    log("\n" + "=" * 70)
    log("EXPERIMENT 2: POSITIONAL encoding → single vector")
    log("  Each candle bound with position vector, then bundled")
    log("=" * 70)
    buy_pos = encode_windows_seq(client, encoder, df_ind, troughs_ind,
                                 mode="positional", striped=False, max_n=200)
    sell_pos = encode_windows_seq(client, encoder, df_ind, peaks_ind,
                                 mode="positional", striped=False, max_n=200)
    hold_pos = encode_windows_seq(client, encoder, df_ind, hold_sample,
                                 mode="positional", striped=False, max_n=200)
    log(f"  Encoded: {len(buy_pos)} BUY, {len(sell_pos)} SELL, {len(hold_pos)} HOLD")
    measure_separation_single("POSITIONAL_SINGLE", buy_pos, sell_pos, hold_pos)
    measure_prototype("POSITIONAL_PROTO", buy_pos, sell_pos, hold_pos)

    # ===================================================================
    # EXPERIMENT 3: N-gram encoding → single vector
    # ===================================================================
    log("\n" + "=" * 70)
    log("EXPERIMENT 3: NGRAM encoding → single vector")
    log("  2-gram and 3-gram patterns of consecutive candles")
    log("=" * 70)
    buy_ng = encode_windows_seq(client, encoder, df_ind, troughs_ind,
                                mode="ngram", striped=False, max_n=200)
    sell_ng = encode_windows_seq(client, encoder, df_ind, peaks_ind,
                                mode="ngram", striped=False, max_n=200)
    hold_ng = encode_windows_seq(client, encoder, df_ind, hold_sample,
                                mode="ngram", striped=False, max_n=200)
    log(f"  Encoded: {len(buy_ng)} BUY, {len(sell_ng)} SELL, {len(hold_ng)} HOLD")
    measure_separation_single("NGRAM_SINGLE", buy_ng, sell_ng, hold_ng)
    measure_prototype("NGRAM_PROTO", buy_ng, sell_ng, hold_ng)

    # ===================================================================
    # EXPERIMENT 4: Chained → per-stripe sequences
    # ===================================================================
    log("\n" + "=" * 70)
    log("EXPERIMENT 4: CHAINED encoding → per-stripe → StripedSubspace")
    log("  Each stripe gets its own chained sequence of candle contributions")
    log("=" * 70)
    buy_ch_s = encode_windows_seq(client, encoder, df_ind, troughs_ind,
                                  mode="chained", striped=True, max_n=200)
    sell_ch_s = encode_windows_seq(client, encoder, df_ind, peaks_ind,
                                  mode="chained", striped=True, max_n=200)
    hold_ch_s = encode_windows_seq(client, encoder, df_ind, hold_sample,
                                  mode="chained", striped=True, max_n=200)
    log(f"  Encoded: {len(buy_ch_s)} BUY, {len(sell_ch_s)} SELL, {len(hold_ch_s)} HOLD")
    measure_separation_striped("CHAINED_STRIPED", buy_ch_s, sell_ch_s, hold_ch_s)

    # ===================================================================
    # EXPERIMENT 5: N-gram → per-stripe sequences
    # ===================================================================
    log("\n" + "=" * 70)
    log("EXPERIMENT 5: NGRAM encoding → per-stripe → StripedSubspace")
    log("=" * 70)
    buy_ng_s = encode_windows_seq(client, encoder, df_ind, troughs_ind,
                                  mode="ngram", striped=True, max_n=200)
    sell_ng_s = encode_windows_seq(client, encoder, df_ind, peaks_ind,
                                  mode="ngram", striped=True, max_n=200)
    hold_ng_s = encode_windows_seq(client, encoder, df_ind, hold_sample,
                                  mode="ngram", striped=True, max_n=200)
    log(f"  Encoded: {len(buy_ng_s)} BUY, {len(sell_ng_s)} SELL, {len(hold_ng_s)} HOLD")
    measure_separation_striped("NGRAM_STRIPED", buy_ng_s, sell_ng_s, hold_ng_s)

    # ===================================================================
    # SUMMARY
    # ===================================================================
    log("\n" + "=" * 70)
    log("SUMMARY")
    log("=" * 70)
    log("  See results above — compare accuracy, margin, and separation metrics")
    log("  Key question: does sequence encoding capture temporal dynamics")
    log("  that flat encoding misses?")


if __name__ == "__main__":
    main()
