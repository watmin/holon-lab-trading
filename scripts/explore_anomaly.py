"""Explore anomaly detection for reversal finding.

Instead of: "does this look like a BUY?"
Ask:        "does this look abnormal? and was price falling?"

Encode raw candle geometry (not indicators) — body/wick ratios, volume
shape, close position — and train a single "normal market" subspace.
Test whether labeled reversals genuinely appear as anomalies.

Usage:
    ./scripts/run_with_venv.sh python holon-lab-trading/scripts/explore_anomaly.py
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
from holon.kernel.walkable import LinearScale, WalkableSpread
from holon.memory import StripedSubspace

DIM = 1024
K = 4
N_STRIPES = 32
WINDOW = 6


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
    peaks_ind = peaks_ind[(peaks_ind >= WINDOW + 1) & (peaks_ind < len(df_ind))]
    troughs_ind = troughs_ind[(troughs_ind >= WINDOW + 1) & (troughs_ind < len(df_ind))]
    log(f"  {len(troughs_ind)} BUY, {len(peaks_ind)} SELL reversals")
    return df_ind, troughs_ind, peaks_ind, df, ts


def candle_geometry(df_ind, idx):
    """Extract raw candle geometry — no indicators, just shape."""
    row = df_ind.iloc[idx]
    o, h, l, c = row["open"], row["high"], row["low"], row["close"]
    v = row["volume"]

    rng = h - l
    if rng < 1e-10:
        rng = 1e-10

    body = c - o
    body_ratio = body / rng                    # body as fraction of range [-1, 1]
    upper_wick = (h - max(o, c)) / rng         # upper wick fraction [0, 1]
    lower_wick = (min(o, c) - l) / rng         # lower wick fraction [0, 1]
    close_position = (c - l) / rng             # where close sits in range [0, 1]

    return {
        "body_ratio": body_ratio,
        "upper_wick": upper_wick,
        "lower_wick": lower_wick,
        "close_pos": close_position,
    }, v


def build_geometry_walkable(df_ind, idx):
    """Build walkable from raw candle geometry across window."""
    start = int(idx) - WINDOW + 1
    if start < 0 or int(idx) >= len(df_ind):
        return None

    body_ratios = []
    upper_wicks = []
    lower_wicks = []
    close_positions = []
    volumes = []
    returns = []
    range_changes = []

    prev_close = None
    prev_range = None

    for i in range(WINDOW):
        row_idx = start + i
        geom, vol = candle_geometry(df_ind, row_idx)
        row = df_ind.iloc[row_idx]

        body_ratios.append(geom["body_ratio"])
        upper_wicks.append(geom["upper_wick"])
        lower_wicks.append(geom["lower_wick"])
        close_positions.append(geom["close_pos"])
        volumes.append(vol)

        if prev_close is not None:
            ret = (row["close"] / prev_close - 1) * 100
            returns.append(ret)
        prev_close = row["close"]

        cur_range = row["high"] - row["low"]
        if prev_range is not None and prev_range > 0:
            range_changes.append(cur_range / prev_range - 1)
        prev_range = cur_range

    # Normalize volume to relative (vs window mean)
    vol_mean = np.mean(volumes) if np.mean(volumes) > 0 else 1
    vol_relative = [v / vol_mean for v in volumes]

    walkable = {
        "body":       WalkableSpread([LinearScale(v) for v in body_ratios]),
        "upper_wick": WalkableSpread([LinearScale(v) for v in upper_wicks]),
        "lower_wick": WalkableSpread([LinearScale(v) for v in lower_wicks]),
        "close_pos":  WalkableSpread([LinearScale(v) for v in close_positions]),
        "vol_rel":    WalkableSpread([LinearScale(v) for v in vol_relative]),
        "ret":        WalkableSpread([LinearScale(v) for v in returns]),
        "range_chg":  WalkableSpread([LinearScale(v) for v in range_changes]),
    }

    # Window-level summary stats
    walkable["summary"] = {
        "up_count":     LinearScale(sum(1 for r in returns if r > 0) / max(len(returns), 1)),
        "vol_trend":    LinearScale(vol_relative[-1] / vol_relative[0] if vol_relative[0] > 0 else 1),
        "body_trend":   LinearScale(body_ratios[-1] - body_ratios[0]),
        "range_trend":  LinearScale(range_changes[-1] if range_changes else 0),
        "min_pos":      LinearScale(np.argmin([df_ind.iloc[start + i]["low"] for i in range(WINDOW)]) / (WINDOW - 1)),
        "max_pos":      LinearScale(np.argmax([df_ind.iloc[start + i]["high"] for i in range(WINDOW)]) / (WINDOW - 1)),
    }

    return walkable


def encode_at(client, df_ind, idx):
    w = build_geometry_walkable(df_ind, idx)
    if w is None:
        return None
    return client.encoder.encode_walkable_striped(w, n_stripes=N_STRIPES)


def encode_batch(client, df_ind, indices, max_n=300):
    vecs = []
    for idx in indices[:max_n + 50]:
        try:
            v = encode_at(client, df_ind, idx)
            if v is not None:
                vecs.append(v)
        except Exception:
            continue
        if len(vecs) >= max_n:
            break
    return vecs


def main():
    df_ind, troughs_ind, peaks_ind, df_full, ts_full = load_data()
    client = HolonClient(dimensions=DIM)
    rng = np.random.default_rng(42)

    rev_set = set(troughs_ind.tolist()) | set(peaks_ind.tolist())
    hold_pool = [i for i in range(WINDOW + 1, len(df_ind)) if i not in rev_set]

    # ===================================================================
    # STEP 1: Train "normal" subspace on random HOLD windows
    # ===================================================================
    log("\n" + "=" * 70)
    log("STEP 1: Train normal-market subspace on HOLD windows")
    log("=" * 70)

    hold_train_idx = rng.choice(hold_pool, size=2000, replace=False)
    hold_vecs = encode_batch(client, df_ind, hold_train_idx, max_n=2000)
    log(f"  Encoded {len(hold_vecs)} HOLD windows")

    ss_normal = StripedSubspace(dim=DIM, k=K, n_stripes=N_STRIPES)
    for v in hold_vecs:
        ss_normal.update(v)
    log(f"  Normal subspace trained: n={ss_normal.n}, threshold={ss_normal.threshold:.1f}")

    # ===================================================================
    # STEP 2: Measure residuals for BUY, SELL, HOLD windows
    # ===================================================================
    log("\n" + "=" * 70)
    log("STEP 2: Residual distributions — do reversals look anomalous?")
    log("=" * 70)

    buy_vecs = encode_batch(client, df_ind, troughs_ind, max_n=400)
    sell_vecs = encode_batch(client, df_ind, peaks_ind, max_n=400)
    hold_test_idx = rng.choice([i for i in hold_pool if i not in set(hold_train_idx)],
                                size=400, replace=False)
    hold_test_vecs = encode_batch(client, df_ind, hold_test_idx, max_n=400)

    buy_residuals = [ss_normal.residual(v) for v in buy_vecs]
    sell_residuals = [ss_normal.residual(v) for v in sell_vecs]
    hold_residuals = [ss_normal.residual(v) for v in hold_test_vecs]

    log(f"  HOLD  residuals: mean={np.mean(hold_residuals):.1f}  "
        f"std={np.std(hold_residuals):.1f}  "
        f"[p5={np.percentile(hold_residuals, 5):.1f}, "
        f"p50={np.percentile(hold_residuals, 50):.1f}, "
        f"p95={np.percentile(hold_residuals, 95):.1f}]")
    log(f"  BUY   residuals: mean={np.mean(buy_residuals):.1f}  "
        f"std={np.std(buy_residuals):.1f}  "
        f"[p5={np.percentile(buy_residuals, 5):.1f}, "
        f"p50={np.percentile(buy_residuals, 50):.1f}, "
        f"p95={np.percentile(buy_residuals, 95):.1f}]")
    log(f"  SELL  residuals: mean={np.mean(sell_residuals):.1f}  "
        f"std={np.std(sell_residuals):.1f}  "
        f"[p5={np.percentile(sell_residuals, 5):.1f}, "
        f"p50={np.percentile(sell_residuals, 50):.1f}, "
        f"p95={np.percentile(sell_residuals, 95):.1f}]")

    # Separation
    buy_above = np.mean([r > ss_normal.threshold for r in buy_residuals]) * 100
    sell_above = np.mean([r > ss_normal.threshold for r in sell_residuals]) * 100
    hold_above = np.mean([r > ss_normal.threshold for r in hold_residuals]) * 100
    log(f"\n  Above threshold ({ss_normal.threshold:.1f}):")
    log(f"    HOLD: {hold_above:.1f}%  BUY: {buy_above:.1f}%  SELL: {sell_above:.1f}%")

    # Separation at various thresholds
    for mult in [1.0, 1.5, 2.0, 2.5, 3.0]:
        thresh = ss_normal.threshold * mult
        ba = np.mean([r > thresh for r in buy_residuals]) * 100
        sa = np.mean([r > thresh for r in sell_residuals]) * 100
        ha = np.mean([r > thresh for r in hold_residuals]) * 100
        log(f"    @{mult:.1f}x ({thresh:.1f}): HOLD={ha:.1f}%  BUY={ba:.1f}%  SELL={sa:.1f}%")

    # ===================================================================
    # STEP 3: Directional anomaly — combine residual with recent trend
    # ===================================================================
    log("\n" + "=" * 70)
    log("STEP 3: Directional anomaly — residual + price direction")
    log("=" * 70)

    def get_recent_direction(df_ind, idx, lookback=6):
        """Was price generally falling or rising leading into this point?"""
        start = max(0, int(idx) - lookback)
        prices = [float(df_ind.iloc[i]["close"]) for i in range(start, int(idx) + 1)]
        if len(prices) < 2:
            return 0
        return (prices[-1] / prices[0] - 1) * 100

    # For each anomalous window, check if direction predicts BUY vs SELL
    log("  Anomalous windows with direction check:")
    for thresh_mult in [1.0, 1.5, 2.0]:
        thresh = ss_normal.threshold * thresh_mult
        buy_anom_falling = 0
        sell_anom_rising = 0
        buy_anom_total = 0
        sell_anom_total = 0

        for v, idx in zip(buy_vecs, troughs_ind[:len(buy_vecs)]):
            r = ss_normal.residual(v)
            if r > thresh:
                buy_anom_total += 1
                d = get_recent_direction(df_ind, idx)
                if d < 0:
                    buy_anom_falling += 1

        for v, idx in zip(sell_vecs, peaks_ind[:len(sell_vecs)]):
            r = ss_normal.residual(v)
            if r > thresh:
                sell_anom_total += 1
                d = get_recent_direction(df_ind, idx)
                if d > 0:
                    sell_anom_rising += 1

        if buy_anom_total > 0 and sell_anom_total > 0:
            log(f"    @{thresh_mult:.1f}x: BUY anomalies={buy_anom_total} "
                f"(falling={buy_anom_falling}, {buy_anom_falling/buy_anom_total*100:.0f}%)  "
                f"SELL anomalies={sell_anom_total} "
                f"(rising={sell_anom_rising}, {sell_anom_rising/sell_anom_total*100:.0f}%)")

    # ===================================================================
    # STEP 4: Forward return analysis on 2021
    # ===================================================================
    log("\n" + "=" * 70)
    log("STEP 4: Forward returns — does geometry anomaly predict moves?")
    log("=" * 70)

    factory = TechnicalFeatureFactory()
    test_mask = (ts_full >= "2021-01-01") & (ts_full <= "2021-12-31")
    df_test = df_full[test_mask].reset_index(drop=True)
    df_test_ind = factory.compute_indicators(df_test)
    log(f"  Test data: {len(df_test_ind):,} candles")

    sample_stride = 5
    total_steps = (len(df_test_ind) - WINDOW) // sample_stride
    log(f"  Scoring every {sample_stride}th candle (~{total_steps:,} samples)...")
    records = []
    t0 = time.time()

    for step in range(WINDOW, len(df_test_ind), sample_stride):
        try:
            v = encode_at(client, df_test_ind, step)
            if v is None:
                continue
        except Exception:
            continue

        r = ss_normal.residual(v)
        price = float(df_test_ind.iloc[step]["close"])
        direction = get_recent_direction(df_test_ind, step)

        fwd = {}
        for h, lbl in [(1, "5m"), (3, "15m"), (6, "30m"), (12, "1h")]:
            if step + h < len(df_test_ind):
                fp = float(df_test_ind.iloc[step + h]["close"])
                fwd[lbl] = (fp / price - 1) * 100

        is_anomaly = r > ss_normal.threshold
        # Directional: anomaly + falling = potential BUY
        signal = "NONE"
        if is_anomaly and direction < -0.3:
            signal = "BUY"
        elif is_anomaly and direction > 0.3:
            signal = "SELL"

        records.append({
            "step": step, "price": price, "residual": r,
            "direction": direction, "signal": signal, "is_anomaly": is_anomaly,
            **{f"fwd_{k}": v for k, v in fwd.items()},
        })

        if (step - WINDOW) % 20000 == 0 and step > WINDOW:
            log(f"    step {step:,} ({(step - WINDOW) / (len(df_test_ind) - WINDOW) * 100:.0f}%)")

    log(f"  Scored {len(records):,} candles in {time.time() - t0:.0f}s")
    rdf = pd.DataFrame(records)

    # Anomaly rate
    n_anom = rdf["is_anomaly"].sum()
    log(f"\n  Anomalies: {n_anom:,} / {len(rdf):,} ({n_anom/len(rdf)*100:.1f}%)")
    n_buy = (rdf["signal"] == "BUY").sum()
    n_sell = (rdf["signal"] == "SELL").sum()
    log(f"  BUY signals: {n_buy:,}  SELL signals: {n_sell:,}")

    # Forward returns by signal type
    for sig in ["BUY", "SELL", "NONE"]:
        subset = rdf[rdf["signal"] == sig]
        if subset.empty or "fwd_1h" not in subset.columns:
            continue
        valid = subset["fwd_1h"].dropna()
        if valid.empty:
            continue
        log(f"\n  {sig} signal ({len(valid):,} candles):")
        log(f"    mean_1h={valid.mean():+.4f}%  med={valid.median():+.4f}%  "
            f"std={valid.std():.4f}%")
        if sig == "BUY":
            log(f"    >+0.2%: {(valid > 0.2).mean()*100:.0f}%  "
                f">+0.5%: {(valid > 0.5).mean()*100:.0f}%  "
                f">+1.0%: {(valid > 1.0).mean()*100:.0f}%")
        elif sig == "SELL":
            log(f"    <-0.2%: {(valid < -0.2).mean()*100:.0f}%  "
                f"<-0.5%: {(valid < -0.5).mean()*100:.0f}%  "
                f"<-1.0%: {(valid < -1.0).mean()*100:.0f}%")

    # Forward returns by residual magnitude (regardless of direction)
    log(f"\n  Forward returns by residual magnitude (BUY signals only):")
    buy_df = rdf[rdf["signal"] == "BUY"]
    if not buy_df.empty and "fwd_1h" in buy_df.columns:
        for lo, hi in [(0, 1.2), (1.2, 1.5), (1.5, 2.0), (2.0, 3.0), (3.0, 100)]:
            thresh_lo = ss_normal.threshold * lo
            thresh_hi = ss_normal.threshold * hi
            band = buy_df[(buy_df["residual"] >= thresh_lo) & (buy_df["residual"] < thresh_hi)]
            if len(band) < 10:
                continue
            m = band["fwd_1h"].mean()
            log(f"    residual [{lo:.1f}x, {hi:.1f}x): n={len(band):,}  mean_1h={m:+.4f}%")

    # Quick simulated trade
    log(f"\n  SIMULATED TRADING:")
    bah_start = float(df_test_ind.iloc[WINDOW]["close"])
    bah_end = float(df_test_ind.iloc[-1]["close"])
    log(f"  Buy & Hold: {(bah_end/bah_start-1)*100:+.1f}%")

    for dir_thresh in [0.3, 0.5, 1.0, 2.0]:
        balance = 10000.0
        btc = 0.0
        entry = 0.0
        wins, losses = 0, 0

        for _, row in rdf.iterrows():
            if btc == 0 and row["is_anomaly"] and row["direction"] < -dir_thresh:
                btc = (balance * 0.999) / row["price"]
                entry = row["price"]
                balance = 0.0
            elif btc > 0 and row["is_anomaly"] and row["direction"] > dir_thresh:
                proceeds = btc * row["price"] * 0.999
                if row["price"] / entry - 1 > 0.002:
                    wins += 1
                else:
                    losses += 1
                balance = proceeds
                btc = 0.0

        equity = balance + btc * rdf.iloc[-1]["price"]
        pnl = (equity / 10000 - 1) * 100
        total = wins + losses
        wr = wins / total * 100 if total > 0 else 0
        log(f"    dir_thresh={dir_thresh}: equity=${equity:>8,.0f} ({pnl:+.1f}%)  "
            f"trades={total}  wr={wr:.0f}%")


if __name__ == "__main__":
    main()
