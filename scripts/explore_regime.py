"""Validate regime classification as the Holon gate signal.

Instead of detecting reversals directly, classify the market into regimes:
  - TREND_UP: sustained price increase
  - TREND_DOWN: sustained price decrease
  - CONSOLIDATION: sideways / range-bound
  - VOLATILE: high ATR / explosive moves

Then check: do regime TRANSITIONS cluster near labeled reversal points?

Each regime is a StripedSubspace (= an engram). The gate fires when the
dominant regime changes, and the tree decides what to do.

Uses sliding window encoding (w=12 = 1 hour) with SPREAD layout.

Usage:
    ./scripts/run_with_venv.sh python holon-lab-trading/scripts/explore_regime.py
"""

from __future__ import annotations

import sys
import time
from collections import deque
from pathlib import Path

import numpy as np
import pandas as pd
from scipy.signal import find_peaks

sys.path.insert(0, str(Path(__file__).parent.parent))

from trading.features import TechnicalFeatureFactory
from holon import HolonClient
from holon.kernel.walkable import LinearScale, WalkableSpread
from holon.memory import StripedSubspace

DIM = 1024
K = 4
N_STRIPES = 32
WINDOW = 12  # 1 hour


def log(msg: str):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


# -------------------------------------------------------------------
# Regime labeling — pure price action, no ML
# -------------------------------------------------------------------

def label_regimes(df_ind, window=12):
    """Label each candle with a regime based on the surrounding window.

    Labels are based on the window ENDING at this candle (backward-looking,
    so they're causal — no future leak).

    Returns array of regime labels aligned with df_ind index.
    """
    n = len(df_ind)
    labels = np.full(n, "UNKNOWN", dtype=object)

    close = df_ind["close"].values
    atr = df_ind["atr"].values if "atr" in df_ind.columns else np.ones(n)
    vol = df_ind["volume"].values if "volume" in df_ind.columns else np.ones(n)

    for i in range(window, n):
        start = i - window
        window_close = close[start:i + 1]
        window_atr = atr[start:i + 1]

        ret_total = (window_close[-1] / window_close[0] - 1) * 100
        path_returns = np.diff(window_close) / window_close[:-1] * 100

        # Monotonicity: what fraction of candles moved in the dominant direction?
        if ret_total > 0:
            monotonicity = np.mean(path_returns > 0)
        else:
            monotonicity = np.mean(path_returns < 0)

        # Volatility: ATR relative to price
        mean_atr_r = np.mean(window_atr) / np.mean(window_close)

        # Range: high-low range of window relative to price
        window_range = (np.max(window_close) - np.min(window_close)) / np.mean(window_close)

        # Classification rules (simple, mechanical, tunable)
        if mean_atr_r > 0.015:  # ~1.5% ATR/price = high volatility
            labels[i] = "VOLATILE"
        elif abs(ret_total) > 0.8 and monotonicity > 0.6:
            if ret_total > 0:
                labels[i] = "TREND_UP"
            else:
                labels[i] = "TREND_DOWN"
        elif window_range < 0.005:  # Very tight range
            labels[i] = "CONSOLIDATION"
        elif abs(ret_total) < 0.3 and window_range < 0.015:
            labels[i] = "CONSOLIDATION"
        else:
            # Mild directional bias or no clear regime
            if ret_total > 0.3:
                labels[i] = "TREND_UP"
            elif ret_total < -0.3:
                labels[i] = "TREND_DOWN"
            else:
                labels[i] = "CONSOLIDATION"

    return labels


# -------------------------------------------------------------------
# Encoding
# -------------------------------------------------------------------

def build_window_walkable(factory, df_ind, idx):
    start = int(idx) - WINDOW + 1
    if start < 0 or int(idx) >= len(df_ind):
        return None

    candles = []
    for i in range(WINDOW):
        raw = factory.compute_candle_row(df_ind, start + i)
        candles.append(raw)

    walkable = {}
    for name, extractor in [
        ("open_r",    lambda c: c["ohlcv"]["open_r"]),
        ("high_r",    lambda c: c["ohlcv"]["high_r"]),
        ("low_r",     lambda c: c["ohlcv"]["low_r"]),
        ("vol_r",     lambda c: c["vol_r"]),
        ("rsi",       lambda c: c["rsi"]),
        ("ret",       lambda c: c["ret"]),
        ("sma20_r",   lambda c: c["sma"]["s20_r"]),
        ("sma50_r",   lambda c: c["sma"]["s50_r"]),
        ("macd_hist", lambda c: c["macd"]["hist_r"]),
        ("bb_width",  lambda c: c["bb"]["width"]),
        ("adx",       lambda c: c["dmi"]["adx"]),
    ]:
        walkable[name] = WalkableSpread([LinearScale(extractor(c)) for c in candles])

    # Candle geometry
    for i in range(WINDOW):
        row = df_ind.iloc[start + i]
        o, h, l, c = row["open"], row["high"], row["low"], row["close"]
        rng = max(h - l, 1e-10)
        if "body" not in walkable:
            walkable["body"] = []
            walkable["upper_wick"] = []
            walkable["lower_wick"] = []
            walkable["close_pos"] = []
        walkable.setdefault("_body", []).append(LinearScale((c - o) / rng))
        walkable.setdefault("_upper", []).append(LinearScale((h - max(o, c)) / rng))
        walkable.setdefault("_lower", []).append(LinearScale((min(o, c) - l) / rng))
        walkable.setdefault("_cpos", []).append(LinearScale((c - l) / rng))

    walkable["body"] = WalkableSpread(walkable.pop("_body"))
    walkable["upper_wick"] = WalkableSpread(walkable.pop("_upper"))
    walkable["lower_wick"] = WalkableSpread(walkable.pop("_lower"))
    walkable["close_pos"] = WalkableSpread(walkable.pop("_cpos"))

    return walkable


def encode_at(client, factory, df_ind, idx):
    w = build_window_walkable(factory, df_ind, idx)
    if w is None:
        return None
    return client.encoder.encode_walkable_striped(w, n_stripes=N_STRIPES)


# -------------------------------------------------------------------
# Main experiment
# -------------------------------------------------------------------

def main():
    log("Loading data...")
    df = pd.read_parquet("holon-lab-trading/data/btc_5m_raw.parquet")
    ts = pd.to_datetime(df["ts"])

    df_seed = df[ts <= "2020-12-31"].reset_index(drop=True)
    factory = TechnicalFeatureFactory()
    df_ind = factory.compute_indicators(df_seed)

    # Label reversals for comparison
    close = df_seed["close"].values
    prominence = float(np.median(close)) * 0.02
    peaks, _ = find_peaks(close, prominence=prominence, distance=12)
    troughs, _ = find_peaks(-close, prominence=prominence, distance=12)
    n_dropped = len(df_seed) - len(df_ind)
    peaks_ind = set((peaks - n_dropped)[(peaks - n_dropped >= 0) & (peaks - n_dropped < len(df_ind))].tolist())
    troughs_ind = set((troughs - n_dropped)[(troughs - n_dropped >= 0) & (troughs - n_dropped < len(df_ind))].tolist())
    all_reversals = peaks_ind | troughs_ind

    log(f"  {len(df_ind):,} candles, {len(troughs_ind)} BUY, {len(peaks_ind)} SELL reversals")

    # ===================================================================
    # STEP 1: Label regimes
    # ===================================================================
    log("\n" + "=" * 70)
    log("STEP 1: Label regimes")
    log("=" * 70)

    regimes = label_regimes(df_ind, window=WINDOW)
    regime_counts = {}
    for r in regimes:
        regime_counts[r] = regime_counts.get(r, 0) + 1

    for r, c in sorted(regime_counts.items(), key=lambda x: -x[1]):
        log(f"  {r:15s}: {c:>7,} ({c/len(df_ind)*100:.1f}%)")

    # What regime are reversals in?
    log("\n  Regime at reversal points:")
    for rev_name, rev_set in [("BUY", troughs_ind), ("SELL", peaks_ind)]:
        rev_regimes = {}
        for idx in rev_set:
            r = regimes[idx]
            rev_regimes[r] = rev_regimes.get(r, 0) + 1
        for r, c in sorted(rev_regimes.items(), key=lambda x: -x[1]):
            log(f"    {rev_name} in {r}: {c} ({c/len(rev_set)*100:.1f}%)")

    # ===================================================================
    # STEP 2: Train regime subspaces
    # ===================================================================
    log("\n" + "=" * 70)
    log("STEP 2: Train regime subspaces (engrams)")
    log("=" * 70)

    client = HolonClient(dimensions=DIM)
    rng = np.random.default_rng(42)

    regime_subspaces = {}
    regime_names = ["TREND_UP", "TREND_DOWN", "CONSOLIDATION", "VOLATILE"]

    for regime in regime_names:
        indices = [i for i in range(WINDOW, len(df_ind)) if regimes[i] == regime]
        if len(indices) < 50:
            log(f"  {regime}: only {len(indices)} samples, skipping")
            continue

        sample = rng.choice(indices, size=min(300, len(indices)), replace=False)
        ss = StripedSubspace(dim=DIM, k=K, n_stripes=N_STRIPES)
        count = 0
        for idx in sample:
            try:
                v = encode_at(client, factory, df_ind, idx)
                if v:
                    ss.update(v)
                    count += 1
            except Exception:
                pass
            if count >= 200:
                break

        regime_subspaces[regime] = ss
        log(f"  {regime}: trained on {count} windows, threshold={ss.threshold:.1f}")

    # ===================================================================
    # STEP 3: Score continuous stream, classify regimes
    # ===================================================================
    log("\n" + "=" * 70)
    log("STEP 3: Score continuous stream — regime classification")
    log("=" * 70)

    # Score a chunk of seed data to validate regime classification
    score_start = len(df_ind) - 30_000
    score_end = len(df_ind)

    log(f"  Scoring {score_end - score_start:,} candles (stride=1)...")
    t0 = time.time()

    records = []
    prev_regime = None
    transitions = []

    for step in range(score_start, score_end):
        if step < WINDOW:
            continue

        try:
            v = encode_at(client, factory, df_ind, step)
            if v is None:
                continue
        except Exception:
            continue

        # Score against all regime subspaces
        residuals = {}
        for regime, ss in regime_subspaces.items():
            residuals[regime] = ss.residual(v)

        # Best match = lowest residual
        best_regime = min(residuals, key=residuals.get)
        best_residual = residuals[best_regime]

        # Regime transition?
        is_transition = (prev_regime is not None and best_regime != prev_regime)
        transition_from = prev_regime if is_transition else None

        is_reversal = step in all_reversals
        is_buy = step in troughs_ind
        is_sell = step in peaks_ind
        true_regime = regimes[step]

        records.append({
            "step": step,
            "classified": best_regime,
            "true_regime": true_regime,
            "is_transition": is_transition,
            "transition_from": transition_from,
            "is_reversal": is_reversal,
            "is_buy": is_buy,
            "is_sell": is_sell,
            **{f"resid_{r}": residuals[r] for r in regime_subspaces},
        })

        if is_transition:
            transitions.append(step)

        prev_regime = best_regime

        if (step - score_start) % 10000 == 0 and step > score_start:
            elapsed = time.time() - t0
            log(f"    {step - score_start:,} done ({elapsed:.0f}s)")

    elapsed = time.time() - t0
    rdf = pd.DataFrame(records)
    log(f"  {len(rdf):,} scored in {elapsed:.0f}s")

    # ===================================================================
    # STEP 4: Classification accuracy
    # ===================================================================
    log("\n" + "=" * 70)
    log("STEP 4: Classification accuracy")
    log("=" * 70)

    correct = (rdf["classified"] == rdf["true_regime"]).mean()
    log(f"  Overall accuracy: {correct*100:.1f}%")

    for regime in regime_names:
        subset = rdf[rdf["true_regime"] == regime]
        if subset.empty:
            continue
        acc = (subset["classified"] == regime).mean()
        log(f"    {regime:15s}: {acc*100:.1f}% ({len(subset):,} samples)")

    # Classified distribution
    log("\n  Classification distribution:")
    for regime in regime_names:
        n = (rdf["classified"] == regime).sum()
        log(f"    {regime:15s}: {n:,} ({n/len(rdf)*100:.1f}%)")

    # ===================================================================
    # STEP 5: Do regime transitions cluster near reversals?
    # ===================================================================
    log("\n" + "=" * 70)
    log("STEP 5: Regime transitions vs reversal proximity")
    log("=" * 70)

    n_transitions = rdf["is_transition"].sum()
    n_reversals = rdf["is_reversal"].sum()
    trans_rate = n_transitions / len(rdf)
    rev_rate = n_reversals / len(rdf)

    log(f"  Transitions: {n_transitions:,} ({trans_rate*100:.1f}%)")
    log(f"  Reversals:   {n_reversals} ({rev_rate*100:.2f}%)")

    # Strict: transition exactly at reversal
    trans_at_rev = (rdf["is_transition"] & rdf["is_reversal"]).sum()
    precision_strict = trans_at_rev / max(n_transitions, 1)
    recall_strict = trans_at_rev / max(n_reversals, 1)
    lift_strict = precision_strict / rev_rate if rev_rate > 0 else 0
    log(f"\n  Strict (transition AT reversal):")
    log(f"    hits={trans_at_rev}  precision={precision_strict*100:.2f}%  "
        f"recall={recall_strict*100:.1f}%  lift={lift_strict:.1f}x")

    # Proximity: transition within +/- N candles of reversal
    for proximity in [1, 3, 6, 12]:
        prox_mask = np.zeros(len(rdf), dtype=bool)
        rev_steps = set(rdf[rdf["is_reversal"]]["step"].values)

        for i, row in rdf.iterrows():
            if row["is_transition"]:
                step = row["step"]
                for delta in range(-proximity, proximity + 1):
                    if step + delta in rev_steps:
                        prox_mask[i] = True
                        break

        hits = prox_mask.sum()
        trans_indices = rdf[rdf["is_transition"]].index
        precision = hits / max(n_transitions, 1)
        # How many reversals have a transition nearby?
        rev_covered = 0
        trans_steps = set(rdf[rdf["is_transition"]]["step"].values)
        for rev_step in rev_steps:
            for delta in range(-proximity, proximity + 1):
                if rev_step + delta in trans_steps:
                    rev_covered += 1
                    break
        recall = rev_covered / max(n_reversals, 1)
        lift = precision / (rev_rate * (2 * proximity + 1)) if rev_rate > 0 else 0
        log(f"  +/-{proximity:2d} candles: transitions_near_rev={hits:,}  "
            f"precision={precision*100:.2f}%  rev_covered={rev_covered} "
            f"({recall*100:.1f}% recall)  lift={lift:.1f}x")

    # ===================================================================
    # STEP 6: Which transitions matter?
    # ===================================================================
    log("\n" + "=" * 70)
    log("STEP 6: Transition type analysis")
    log("=" * 70)

    trans_df = rdf[rdf["is_transition"]].copy()
    trans_df["trans_type"] = trans_df["transition_from"] + " → " + trans_df["classified"]

    trans_types = trans_df["trans_type"].value_counts()
    log(f"\n  Transition types (top 15):")
    for ttype, count in trans_types.head(15).items():
        near_rev = 0
        for _, row in trans_df[trans_df["trans_type"] == ttype].iterrows():
            step = row["step"]
            for delta in range(-6, 7):
                if step + delta in rev_steps:
                    near_rev += 1
                    break
        rev_pct = near_rev / count * 100
        log(f"    {ttype:40s}: {count:5,}  near_rev={near_rev:3d} ({rev_pct:.1f}%)")

    # Which transitions are BUY-adjacent vs SELL-adjacent?
    log(f"\n  Transitions near BUY vs SELL reversals (+/-6):")
    buy_steps = set(rdf[rdf["is_buy"]]["step"].values)
    sell_steps = set(rdf[rdf["is_sell"]]["step"].values)

    for ttype in trans_types.head(10).index:
        near_buy = 0
        near_sell = 0
        subset = trans_df[trans_df["trans_type"] == ttype]
        for _, row in subset.iterrows():
            step = row["step"]
            for delta in range(-6, 7):
                if step + delta in buy_steps:
                    near_buy += 1
                    break
            for delta in range(-6, 7):
                if step + delta in sell_steps:
                    near_sell += 1
                    break
        log(f"    {ttype:40s}: BUY={near_buy:3d}  SELL={near_sell:3d}")

    log("\n" + "=" * 70)
    log("DONE")
    log("=" * 70)


if __name__ == "__main__":
    main()
