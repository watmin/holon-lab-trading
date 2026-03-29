"""Validate gate signals: which Holon primitives fire at labeled reversals?

Encodes a continuous stream of candles (one vector per candle), then tests
multiple Holon primitives as "surprise detectors" to see if they spike at
labeled reversal points disproportionately vs random candles.

Primitives tested:
  1. drift_rate     — temporal derivative of consecutive similarity
  2. segment        — structural breakpoint detection (prototype method)
  3. complexity     — vector mixedness / entropy
  4. coherence      — recent window cluster tightness drop
  5. subspace residual — OnlineSubspace anomaly score
  6. diff cosine    — raw consecutive cosine distance

For each, we measure:
  - Signal value at labeled reversal points vs random points
  - Precision/recall at various thresholds
  - How selective the gate is (% of candles that fire)

Uses single-candle encoding (flat walkable, not windowed SPREAD) so the
stream captures per-candle character, and the primitives detect when that
character shifts.

Usage:
    ./scripts/run_with_venv.sh python holon-lab-trading/scripts/explore_gate_signals.py
"""

from __future__ import annotations

import sys
import time
from pathlib import Path

import numpy as np
import pandas as pd
from scipy.signal import find_peaks

sys.path.insert(0, str(Path(__file__).parent.parent))

from trading.features import TechnicalFeatureFactory
from holon import HolonClient
from holon.kernel.primitives import (
    coherence,
    complexity,
    drift_rate,
    segment,
)
from holon.kernel.distance import cosine_similarity
from holon.kernel.walkable import LinearScale, LogScale
from holon.memory import OnlineSubspace

DIM = 1024
K = 4


def log(msg: str):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def encode_candle(client, factory, df_ind, idx):
    """Encode a single candle as a flat hypervector."""
    row = factory.compute_candle_row(df_ind, idx)

    walkable = {
        "open_r": LinearScale(row["ohlcv"]["open_r"]),
        "high_r": LinearScale(row["ohlcv"]["high_r"]),
        "low_r": LinearScale(row["ohlcv"]["low_r"]),
        "vol_r": LinearScale(row["vol_r"]),
        "rsi": LinearScale(row["rsi"]),
        "ret": LinearScale(row["ret"]),
        "sma20_r": LinearScale(row["sma"]["s20_r"]),
        "sma50_r": LinearScale(row["sma"]["s50_r"]),
        "macd_hist_r": LinearScale(row["macd"]["hist_r"]),
        "bb_width": LinearScale(row["bb"]["width"]),
        "adx": LinearScale(row["dmi"]["adx"]),
    }

    # Candle geometry (price-independent)
    r = df_ind.iloc[idx]
    o, h, l, c = r["open"], r["high"], r["low"], r["close"]
    rng = max(h - l, 1e-10)
    walkable["body"] = LinearScale((c - o) / rng)
    walkable["upper_wick"] = LinearScale((h - max(o, c)) / rng)
    walkable["lower_wick"] = LinearScale((min(o, c) - l) / rng)
    walkable["close_pos"] = LinearScale((c - l) / rng)

    return client.encoder.encode_walkable(walkable)


def build_stream(client, factory, df_ind, start, end):
    """Encode a contiguous range of candles into a vector stream."""
    vecs = []
    for i in range(start, end):
        try:
            v = encode_candle(client, factory, df_ind, i)
            vecs.append(v)
        except Exception:
            vecs.append(np.zeros(DIM, dtype=np.int8))
    return vecs


def measure_gate_quality(signal_values, is_reversal, name, top_pcts=(1, 2, 5, 10)):
    """Measure how well a signal distinguishes reversals from non-reversals."""
    signal_values = np.array(signal_values)
    is_reversal = np.array(is_reversal)

    n_total = len(signal_values)
    n_rev = is_reversal.sum()
    base_rate = n_rev / n_total

    rev_vals = signal_values[is_reversal]
    non_vals = signal_values[~is_reversal]

    log(f"\n  {name}:")
    log(f"    reversal mean={np.mean(rev_vals):.4f}  non-reversal mean={np.mean(non_vals):.4f}")
    log(f"    reversal p50={np.median(rev_vals):.4f}  p90={np.percentile(rev_vals, 90):.4f}  "
        f"p99={np.percentile(rev_vals, 99):.4f}")
    log(f"    non-rev  p50={np.median(non_vals):.4f}  p90={np.percentile(non_vals, 90):.4f}  "
        f"p99={np.percentile(non_vals, 99):.4f}")

    log(f"    base rate: {base_rate*100:.2f}% ({n_rev}/{n_total})")

    for pct in top_pcts:
        threshold = np.percentile(signal_values, 100 - pct)
        fired = signal_values >= threshold
        n_fired = fired.sum()
        n_rev_fired = (fired & is_reversal).sum()
        precision = n_rev_fired / n_fired if n_fired > 0 else 0
        recall = n_rev_fired / n_rev if n_rev > 0 else 0
        lift = precision / base_rate if base_rate > 0 else 0
        log(f"    top {pct:2d}%: threshold={threshold:.4f}  fired={n_fired:,}  "
            f"rev_caught={n_rev_fired}  prec={precision:.3f}  "
            f"recall={recall:.3f}  lift={lift:.1f}x")


def main():
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

    valid_peaks = set(peaks_ind[(peaks_ind >= 0) & (peaks_ind < len(df_ind))].tolist())
    valid_troughs = set(troughs_ind[(troughs_ind >= 0) & (troughs_ind < len(df_ind))].tolist())
    all_reversals = valid_peaks | valid_troughs

    log(f"  {len(df_ind):,} candles, {len(valid_troughs)} BUY, {len(valid_peaks)} SELL reversals")
    log(f"  reversal base rate: {len(all_reversals)/len(df_ind)*100:.2f}%")

    client = HolonClient(dimensions=DIM)

    # Use a contiguous chunk for stream analysis (last 50k candles of seed era)
    stream_len = min(50_000, len(df_ind))
    stream_start = len(df_ind) - stream_len

    log(f"\nEncoding stream: {stream_len:,} candles starting at index {stream_start}...")
    t0 = time.time()
    stream = build_stream(client, factory, df_ind, stream_start, stream_start + stream_len)
    log(f"  Encoded in {time.time()-t0:.0f}s")

    reversal_mask = np.array([
        (stream_start + i) in all_reversals
        for i in range(stream_len)
    ])
    buy_mask = np.array([(stream_start + i) in valid_troughs for i in range(stream_len)])
    sell_mask = np.array([(stream_start + i) in valid_peaks for i in range(stream_len)])

    log(f"  Reversals in stream: {reversal_mask.sum()} "
        f"(BUY={buy_mask.sum()}, SELL={sell_mask.sum()})")

    # =================================================================
    # SIGNAL 1: Consecutive cosine distance (simplest baseline)
    # =================================================================
    log("\n" + "=" * 70)
    log("SIGNAL 1: Consecutive cosine distance")
    log("=" * 70)
    cos_dists = [0.0]
    for i in range(1, stream_len):
        sim = cosine_similarity(stream[i], stream[i - 1])
        cos_dists.append(1.0 - sim)
    measure_gate_quality(cos_dists, reversal_mask, "cos_distance")

    # =================================================================
    # SIGNAL 2: drift_rate
    # =================================================================
    log("\n" + "=" * 70)
    log("SIGNAL 2: drift_rate (temporal similarity derivative)")
    log("=" * 70)

    for window in [1, 3, 6]:
        rates = drift_rate(stream, window=window)
        # drift_rate returns len(stream)-2 values; pad to align with stream
        padded = [0.0, 0.0] + rates
        abs_rates = [abs(r) for r in padded]
        neg_rates = [-r for r in padded]  # negative drift = diverging = interesting
        measure_gate_quality(abs_rates, reversal_mask, f"abs_drift_rate(w={window})")
        measure_gate_quality(neg_rates, reversal_mask, f"neg_drift_rate(w={window})")

    # =================================================================
    # SIGNAL 3: segment breakpoints
    # =================================================================
    log("\n" + "=" * 70)
    log("SIGNAL 3: segment breakpoints")
    log("=" * 70)

    for method in ["prototype", "diff"]:
        for thresh in [0.3, 0.5, 0.7]:
            breakpoints = set(segment(stream, window=50, threshold=thresh, method=method))
            is_bp = np.array([i in breakpoints for i in range(stream_len)])
            n_bp = is_bp.sum()
            bp_rev = (is_bp & reversal_mask).sum()
            bp_rate = n_bp / stream_len * 100
            rev_rate = bp_rev / max(reversal_mask.sum(), 1) * 100
            precision = bp_rev / max(n_bp, 1) * 100
            base = reversal_mask.mean() * 100
            lift = (precision / base) if base > 0 else 0
            log(f"  segment({method}, t={thresh}): breakpoints={n_bp:,} ({bp_rate:.1f}%)  "
                f"rev_caught={bp_rev} ({rev_rate:.1f}% recall)  "
                f"precision={precision:.2f}%  lift={lift:.1f}x")

    # =================================================================
    # SIGNAL 4: complexity change
    # =================================================================
    log("\n" + "=" * 70)
    log("SIGNAL 4: complexity (vector mixedness)")
    log("=" * 70)

    complexities = [complexity(v) for v in stream]
    measure_gate_quality(complexities, reversal_mask, "complexity")

    # Complexity *change* — sudden shifts in complexity
    complexity_delta = [0.0]
    for i in range(1, stream_len):
        complexity_delta.append(abs(complexities[i] - complexities[i - 1]))
    measure_gate_quality(complexity_delta, reversal_mask, "abs_complexity_delta")

    # =================================================================
    # SIGNAL 5: coherence drop in rolling window
    # =================================================================
    log("\n" + "=" * 70)
    log("SIGNAL 5: coherence (rolling window tightness)")
    log("=" * 70)

    for coh_window in [6, 12]:
        coh_values = []
        for i in range(stream_len):
            if i < coh_window:
                coh_values.append(1.0)
            else:
                c = coherence(stream[i - coh_window:i])
                coh_values.append(c)

        neg_coh = [1.0 - c for c in coh_values]
        measure_gate_quality(neg_coh, reversal_mask, f"neg_coherence(w={coh_window})")

        coh_delta = [0.0]
        for i in range(1, stream_len):
            coh_delta.append(abs(coh_values[i] - coh_values[i - 1]))
        measure_gate_quality(coh_delta, reversal_mask, f"abs_coherence_delta(w={coh_window})")

    # =================================================================
    # SIGNAL 6: OnlineSubspace residual
    # =================================================================
    log("\n" + "=" * 70)
    log("SIGNAL 6: OnlineSubspace residual (learned normal)")
    log("=" * 70)

    ss = OnlineSubspace(dim=DIM, k=K)
    residuals = []
    for v in stream:
        r = ss.residual(v) if ss.n >= K else 0.0
        residuals.append(r)
        ss.update(v)
    measure_gate_quality(residuals, reversal_mask, "subspace_residual")

    # Residual *spike* — sudden increase
    residual_delta = [0.0]
    for i in range(1, stream_len):
        residual_delta.append(max(0, residuals[i] - residuals[i - 1]))
    measure_gate_quality(residual_delta, reversal_mask, "residual_spike")

    # =================================================================
    # SIGNAL 7: Combined signals
    # =================================================================
    log("\n" + "=" * 70)
    log("SIGNAL 7: Combined gate signals")
    log("=" * 70)

    # Normalize each signal to [0, 1] range
    def norm01(vals):
        arr = np.array(vals, dtype=np.float64)
        mn, mx = arr.min(), arr.max()
        if mx - mn < 1e-10:
            return np.zeros_like(arr)
        return (arr - mn) / (mx - mn)

    n_cos = norm01(cos_dists)
    n_drift = norm01([abs(r) for r in ([0.0, 0.0] + drift_rate(stream, window=1))])
    n_resid = norm01(residuals)
    n_cdelta = norm01(complexity_delta)

    # Simple average combination
    combined_avg = (n_cos + n_drift + n_resid + n_cdelta) / 4
    measure_gate_quality(combined_avg, reversal_mask, "combined_avg(cos+drift+resid+cdelta)")

    # Max of normalized signals — fire if ANY signal is extreme
    combined_max = np.maximum(np.maximum(n_cos, n_drift), np.maximum(n_resid, n_cdelta))
    measure_gate_quality(combined_max, reversal_mask, "combined_max(cos+drift+resid+cdelta)")

    # =================================================================
    # SIGNAL 8: Proximity-tolerant evaluation
    # =================================================================
    log("\n" + "=" * 70)
    log("SIGNAL 8: Proximity-tolerant (fire within +/-3 candles of reversal)")
    log("=" * 70)

    # A gate that fires 1-3 candles before or after a reversal is still useful
    proximity_mask = np.zeros(stream_len, dtype=bool)
    for i in range(stream_len):
        if reversal_mask[i]:
            for delta in range(-3, 4):
                j = i + delta
                if 0 <= j < stream_len:
                    proximity_mask[j] = True

    log(f"  Proximity reversal rate: {proximity_mask.mean()*100:.2f}% "
        f"(vs strict {reversal_mask.mean()*100:.2f}%)")

    measure_gate_quality(cos_dists, proximity_mask, "cos_distance (proximity)")
    measure_gate_quality(
        [abs(r) for r in ([0.0, 0.0] + drift_rate(stream, window=1))],
        proximity_mask, "abs_drift_rate(w=1) (proximity)")
    measure_gate_quality(residuals, proximity_mask, "subspace_residual (proximity)")
    measure_gate_quality(combined_avg.tolist(), proximity_mask,
                         "combined_avg (proximity)")

    log("\n" + "=" * 70)
    log("DONE")
    log("=" * 70)


if __name__ == "__main__":
    main()
