"""Explore sequence-based encoding (v2) — correct API usage.

v1 was broken: it passed pre-encoded np.ndarray to encode_list, which
hashed them as strings. This version passes raw candle dicts through
the walkable interface, letting Holon handle encoding internally.

Tests:
  1. Non-striped: encode_walkable with list of candle dicts, various modes
  2. Striped current: flat tN keys (baseline)
  3. Manual per-stripe chaining: encode each candle striped, then chain
     per-stripe using bind() directly on the pre-encoded stripe vectors

Usage:
    ./scripts/run_with_venv.sh python holon-lab-trading/scripts/explore_sequence_v2.py
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


def get_candle_dicts(encoder, df_ind, idx):
    """Get list of raw candle dicts for a window ending at idx."""
    start = int(idx) - WINDOW + 1
    if start < 0 or int(idx) >= len(df_ind):
        return None
    candles = []
    for i in range(WINDOW):
        row_idx = start + i
        raw = encoder.factory.compute_candle_row(df_ind, row_idx)
        candles.append(encoder._wrap_candle(raw))
    return candles


def encode_as_list(client, candle_dicts, mode="chained"):
    """Encode a list of candle dicts using Holon's list encoding.

    Passes raw dicts through encode_walkable so Holon internally encodes
    each candle and then composes via the chosen list mode.
    """
    data = {"candles": candle_dicts}
    old_mode = client.encoder.default_list_mode
    client.encoder.default_list_mode = ListEncodeMode(mode)
    try:
        vec = client.encoder.encode_walkable(data)
    finally:
        client.encoder.default_list_mode = old_mode
    return vec


def encode_manual_chained_striped(client, encoder, candle_dicts):
    """Manually chain per-stripe: encode each candle striped, then bind per stripe.

    This avoids the walkable list→single-leaf collapse in encode_walkable_striped.
    """
    per_stripe = [[] for _ in range(N_STRIPES)]
    for cd in candle_dicts:
        stripe_vecs = client.encoder.encode_walkable_striped(cd, n_stripes=N_STRIPES)
        for s in range(N_STRIPES):
            per_stripe[s].append(stripe_vecs[s])

    result = []
    for s in range(N_STRIPES):
        vecs = per_stripe[s]
        if not vecs:
            result.append(np.zeros(DIM, dtype=np.int8))
            continue
        chained = vecs[-1]
        for prev in reversed(vecs[:-1]):
            chained = client.encoder.bind(prev, chained)
        result.append(chained)
    return result


def encode_manual_ngram_striped(client, encoder, candle_dicts, n=2):
    """Manual n-gram per stripe: encode pairs of consecutive candles."""
    per_stripe = [[] for _ in range(N_STRIPES)]
    for cd in candle_dicts:
        stripe_vecs = client.encoder.encode_walkable_striped(cd, n_stripes=N_STRIPES)
        for s in range(N_STRIPES):
            per_stripe[s].append(stripe_vecs[s])

    result = []
    for s in range(N_STRIPES):
        vecs = per_stripe[s]
        if len(vecs) < n:
            result.append(np.zeros(DIM, dtype=np.int8))
            continue
        ngrams = []
        for i in range(len(vecs) - n + 1):
            gram = vecs[i]
            for j in range(1, n):
                gram = client.encoder.bind(gram, vecs[i + j])
            ngrams.append(gram)
        bundled = np.sum(np.stack(ngrams), axis=0)
        bipolar = np.sign(bundled).astype(np.int8)
        result.append(bipolar)
    return result


def encode_windows(func, indices, max_n=200):
    vecs = []
    for idx in indices[:max_n + 50]:
        try:
            v = func(idx)
            if v is not None:
                vecs.append(v)
        except Exception:
            continue
        if len(vecs) >= max_n:
            break
    return vecs


def measure_single(name, buy_vecs, sell_vecs, hold_vecs, n_train=120, n_test=50):
    if len(buy_vecs) < n_train + n_test or len(sell_vecs) < n_train + n_test:
        log(f"  {name}: insufficient data")
        return None

    ss_b = OnlineSubspace(dim=DIM, k=K)
    ss_s = OnlineSubspace(dim=DIM, k=K)
    ss_h = OnlineSubspace(dim=DIM, k=K)
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
    align = ss_b.subspace_alignment(ss_s)
    log(f"  {name}: acc={acc:.0f}%  margin={np.mean(margins):.2f}  "
        f"buy_sep={np.mean(buy_seps):+.1f}  sell_sep={np.mean(sell_seps):+.1f}  "
        f"B-S align={align:.3f}")
    return {"accuracy": acc, "margin": np.mean(margins),
            "buy_sep": np.mean(buy_seps), "sell_sep": np.mean(sell_seps)}


def measure_striped(name, buy_vecs, sell_vecs, hold_vecs, n_train=120, n_test=50):
    if len(buy_vecs) < n_train + n_test or len(sell_vecs) < n_train + n_test:
        log(f"  {name}: insufficient data")
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

    # ===================================================================
    # BASELINE: current flat walkable striped (for comparison)
    # ===================================================================
    log("\n" + "=" * 70)
    log("BASELINE: flat tN-keyed walkable → striped")
    log("=" * 70)

    def enc_flat_striped(idx):
        start = int(idx) - WINDOW + 1
        w = df_ind.iloc[start:int(idx) + 1]
        return encoder.encode_from_precomputed(w) if len(w) >= WINDOW else None

    buy_flat = encode_windows(enc_flat_striped, troughs_ind, 200)
    sell_flat = encode_windows(enc_flat_striped, peaks_ind, 200)
    hold_flat = encode_windows(enc_flat_striped, hold_sample, 200)
    log(f"  {len(buy_flat)} BUY, {len(sell_flat)} SELL, {len(hold_flat)} HOLD")
    measure_striped("FLAT_STRIPED", buy_flat, sell_flat, hold_flat)

    # ===================================================================
    # EXP 1: List of candle dicts → encode_walkable with chained mode
    # ===================================================================
    log("\n" + "=" * 70)
    log("EXP 1: encode_walkable({candles: [dict,...]}, mode=chained)")
    log("  Holon internally encodes each candle dict, then chains them")
    log("=" * 70)

    def enc_list_chained(idx):
        cds = get_candle_dicts(encoder, df_ind, idx)
        return encode_as_list(client, cds, mode="chained") if cds else None

    buy_lc = encode_windows(enc_list_chained, troughs_ind, 200)
    sell_lc = encode_windows(enc_list_chained, peaks_ind, 200)
    hold_lc = encode_windows(enc_list_chained, hold_sample, 200)
    log(f"  {len(buy_lc)} BUY, {len(sell_lc)} SELL, {len(hold_lc)} HOLD")
    measure_single("LIST_CHAINED", buy_lc, sell_lc, hold_lc)

    # ===================================================================
    # EXP 2: List of candle dicts → encode_walkable with positional mode
    # ===================================================================
    log("\n" + "=" * 70)
    log("EXP 2: encode_walkable({candles: [dict,...]}, mode=positional)")
    log("=" * 70)

    def enc_list_pos(idx):
        cds = get_candle_dicts(encoder, df_ind, idx)
        return encode_as_list(client, cds, mode="positional") if cds else None

    buy_lp = encode_windows(enc_list_pos, troughs_ind, 200)
    sell_lp = encode_windows(enc_list_pos, peaks_ind, 200)
    hold_lp = encode_windows(enc_list_pos, hold_sample, 200)
    log(f"  {len(buy_lp)} BUY, {len(sell_lp)} SELL, {len(hold_lp)} HOLD")
    measure_single("LIST_POSITIONAL", buy_lp, sell_lp, hold_lp)

    # ===================================================================
    # EXP 3: List of candle dicts → encode_walkable with ngram mode
    # ===================================================================
    log("\n" + "=" * 70)
    log("EXP 3: encode_walkable({candles: [dict,...]}, mode=ngram)")
    log("=" * 70)

    def enc_list_ng(idx):
        cds = get_candle_dicts(encoder, df_ind, idx)
        return encode_as_list(client, cds, mode="ngram") if cds else None

    buy_ln = encode_windows(enc_list_ng, troughs_ind, 200)
    sell_ln = encode_windows(enc_list_ng, peaks_ind, 200)
    hold_ln = encode_windows(enc_list_ng, hold_sample, 200)
    log(f"  {len(buy_ln)} BUY, {len(sell_ln)} SELL, {len(hold_ln)} HOLD")
    measure_single("LIST_NGRAM", buy_ln, sell_ln, hold_ln)

    # ===================================================================
    # EXP 4: Manual per-stripe chaining (bypasses list→single-leaf issue)
    # ===================================================================
    log("\n" + "=" * 70)
    log("EXP 4: Manual per-stripe chaining")
    log("  Each candle encoded striped, then bind() per stripe across time")
    log("=" * 70)

    def enc_chain_striped(idx):
        cds = get_candle_dicts(encoder, df_ind, idx)
        return encode_manual_chained_striped(client, encoder, cds) if cds else None

    buy_cs = encode_windows(enc_chain_striped, troughs_ind, 200)
    sell_cs = encode_windows(enc_chain_striped, peaks_ind, 200)
    hold_cs = encode_windows(enc_chain_striped, hold_sample, 200)
    log(f"  {len(buy_cs)} BUY, {len(sell_cs)} SELL, {len(hold_cs)} HOLD")
    measure_striped("MANUAL_CHAIN_STRIPED", buy_cs, sell_cs, hold_cs)

    # ===================================================================
    # EXP 5: Manual per-stripe 2-gram
    # ===================================================================
    log("\n" + "=" * 70)
    log("EXP 5: Manual per-stripe 2-gram")
    log("  Consecutive candle pairs bound and bundled per stripe")
    log("=" * 70)

    def enc_ngram_striped(idx):
        cds = get_candle_dicts(encoder, df_ind, idx)
        return encode_manual_ngram_striped(client, encoder, cds, n=2) if cds else None

    buy_ns = encode_windows(enc_ngram_striped, troughs_ind, 200)
    sell_ns = encode_windows(enc_ngram_striped, peaks_ind, 200)
    hold_ns = encode_windows(enc_ngram_striped, hold_sample, 200)
    log(f"  {len(buy_ns)} BUY, {len(sell_ns)} SELL, {len(hold_ns)} HOLD")
    measure_striped("MANUAL_2GRAM_STRIPED", buy_ns, sell_ns, hold_ns)

    # ===================================================================
    # EXP 6: Manual per-stripe 3-gram
    # ===================================================================
    log("\n" + "=" * 70)
    log("EXP 6: Manual per-stripe 3-gram")
    log("  Triple-candle patterns bound and bundled per stripe")
    log("=" * 70)

    def enc_3gram_striped(idx):
        cds = get_candle_dicts(encoder, df_ind, idx)
        return encode_manual_ngram_striped(client, encoder, cds, n=3) if cds else None

    buy_3s = encode_windows(enc_3gram_striped, troughs_ind, 200)
    sell_3s = encode_windows(enc_3gram_striped, peaks_ind, 200)
    hold_3s = encode_windows(enc_3gram_striped, hold_sample, 200)
    log(f"  {len(buy_3s)} BUY, {len(sell_3s)} SELL, {len(hold_3s)} HOLD")
    measure_striped("MANUAL_3GRAM_STRIPED", buy_3s, sell_3s, hold_3s)

    # ===================================================================
    # SUMMARY
    # ===================================================================
    log("\n" + "=" * 70)
    log("SUMMARY — compare all approaches")
    log("=" * 70)


if __name__ == "__main__":
    main()
