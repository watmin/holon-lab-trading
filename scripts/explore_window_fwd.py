"""Test whether longer windows produce better forward return prediction.

Quick sweep: train normal subspace per window size, score 2021 test data
(sampled), check if BUY/SELL signals have meaningful forward returns.

Uses SPREAD geometry encoding. Tests windows 6, 12, 24, 48, 96 (8 hours).

Usage:
    ./scripts/run_with_venv.sh python holon-lab-trading/scripts/explore_window_fwd.py
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


def log(msg: str):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def load_data():
    log("Loading data...")
    df = pd.read_parquet("holon-lab-trading/data/btc_5m_raw.parquet")
    ts = pd.to_datetime(df["ts"])

    df_seed = df[ts <= "2020-12-31"].reset_index(drop=True)
    close_seed = df_seed["close"].values
    prominence = float(np.median(close_seed)) * 0.02
    peaks, _ = find_peaks(close_seed, prominence=prominence, distance=12)
    troughs, _ = find_peaks(-close_seed, prominence=prominence, distance=12)

    factory = TechnicalFeatureFactory()
    df_seed_ind = factory.compute_indicators(df_seed)
    n_dropped = len(df_seed) - len(df_seed_ind)
    peaks_ind = peaks - n_dropped
    troughs_ind = troughs - n_dropped

    test_mask = (ts >= "2021-01-01") & (ts <= "2021-12-31")
    df_test = df[test_mask].reset_index(drop=True)
    df_test_ind = factory.compute_indicators(df_test)

    log(f"  Seed: {len(df_seed_ind):,} rows, {len(troughs)} BUY, {len(peaks)} SELL")
    log(f"  Test: {len(df_test_ind):,} rows")
    return df_seed_ind, troughs_ind, peaks_ind, df_test_ind, factory


def build_spread_walkable(factory, df_ind, idx, window):
    """SPREAD field-series encoding with candle geometry + indicators."""
    start = int(idx) - window + 1
    if start < 0 or int(idx) >= len(df_ind):
        return None

    candles = []
    for i in range(window):
        raw = factory.compute_candle_row(df_ind, start + i)
        candles.append(raw)

    # Also compute candle geometry
    geom_body = []
    geom_upper = []
    geom_lower = []
    geom_close_pos = []
    for i in range(window):
        row = df_ind.iloc[start + i]
        o, h, l, c = row["open"], row["high"], row["low"], row["close"]
        rng = max(h - l, 1e-10)
        geom_body.append((c - o) / rng)
        geom_upper.append((h - max(o, c)) / rng)
        geom_lower.append((min(o, c) - l) / rng)
        geom_close_pos.append((c - l) / rng)

    walkable = {}

    # Indicator fields as SPREAD
    for name, extractor in [
        ("ohlcv_open_r",  lambda c: c["ohlcv"]["open_r"]),
        ("ohlcv_high_r",  lambda c: c["ohlcv"]["high_r"]),
        ("ohlcv_low_r",   lambda c: c["ohlcv"]["low_r"]),
        ("vol_r",         lambda c: c["vol_r"]),
        ("rsi",           lambda c: c["rsi"]),
        ("ret",           lambda c: c["ret"]),
        ("sma_s20_r",     lambda c: c["sma"]["s20_r"]),
        ("sma_s50_r",     lambda c: c["sma"]["s50_r"]),
        ("macd_hist_r",   lambda c: c["macd"]["hist_r"]),
        ("bb_width",      lambda c: c["bb"]["width"]),
        ("adx",           lambda c: c["dmi"]["adx"]),
    ]:
        walkable[name] = WalkableSpread([LinearScale(extractor(c)) for c in candles])

    # Geometry fields
    walkable["body"] = WalkableSpread([LinearScale(v) for v in geom_body])
    walkable["upper_wick"] = WalkableSpread([LinearScale(v) for v in geom_upper])
    walkable["lower_wick"] = WalkableSpread([LinearScale(v) for v in geom_lower])
    walkable["close_pos"] = WalkableSpread([LinearScale(v) for v in geom_close_pos])

    return walkable


def encode_at(client, factory, df_ind, idx, window):
    w = build_spread_walkable(factory, df_ind, idx, window)
    if w is None:
        return None
    return client.encoder.encode_walkable_striped(w, n_stripes=N_STRIPES)


def main():
    df_seed_ind, troughs_ind, peaks_ind, df_test_ind, factory = load_data()
    rng = np.random.default_rng(42)

    bah_start = float(df_test_ind.iloc[100]["close"])
    bah_end = float(df_test_ind.iloc[-1]["close"])
    log(f"  Buy & Hold 2021: {(bah_end/bah_start-1)*100:+.1f}%")

    for window in [6, 12, 24, 48, 96]:
        log(f"\n{'=' * 70}")
        log(f"WINDOW = {window} ({window * 5} min)")
        log(f"{'=' * 70}")

        client = HolonClient(dimensions=DIM)

        # Filter valid indices
        valid_buy = troughs_ind[troughs_ind >= window + 1]
        valid_sell = peaks_ind[peaks_ind >= window + 1]
        valid_buy = valid_buy[valid_buy < len(df_seed_ind)]
        valid_sell = valid_sell[valid_sell < len(df_seed_ind)]
        rev_set = set(valid_buy.tolist()) | set(valid_sell.tolist())
        hold_pool = [i for i in range(window + 1, len(df_seed_ind)) if i not in rev_set]

        # Train BUY, SELL, HOLD subspaces
        n_train = 200
        ss_b = StripedSubspace(dim=DIM, k=K, n_stripes=N_STRIPES)
        ss_s = StripedSubspace(dim=DIM, k=K, n_stripes=N_STRIPES)
        ss_h = StripedSubspace(dim=DIM, k=K, n_stripes=N_STRIPES)

        trained = {"BUY": 0, "SELL": 0, "HOLD": 0}
        for idx in valid_buy[:n_train + 50]:
            try:
                v = encode_at(client, factory, df_seed_ind, idx, window)
                if v:
                    ss_b.update(v)
                    trained["BUY"] += 1
            except Exception:
                pass
            if trained["BUY"] >= n_train:
                break

        for idx in valid_sell[:n_train + 50]:
            try:
                v = encode_at(client, factory, df_seed_ind, idx, window)
                if v:
                    ss_s.update(v)
                    trained["SELL"] += 1
            except Exception:
                pass
            if trained["SELL"] >= n_train:
                break

        hold_sample = rng.choice(hold_pool, size=min(n_train + 50, len(hold_pool)), replace=False)
        for idx in hold_sample:
            try:
                v = encode_at(client, factory, df_seed_ind, idx, window)
                if v:
                    ss_h.update(v)
                    trained["HOLD"] += 1
            except Exception:
                pass
            if trained["HOLD"] >= n_train:
                break

        log(f"  Trained: {trained}")

        # Score 2021 test data (sampled)
        sample_stride = 10
        log(f"  Scoring test data (stride={sample_stride})...")
        records = []
        t0 = time.time()

        for step in range(window, len(df_test_ind), sample_stride):
            try:
                v = encode_at(client, factory, df_test_ind, step, window)
                if v is None:
                    continue
            except Exception:
                continue

            rb = ss_b.residual(v)
            rs = ss_s.residual(v)
            rh = ss_h.residual(v)
            price = float(df_test_ind.iloc[step]["close"])

            best = min(rb, rs, rh)
            if best == rb:
                pred = "BUY"
            elif best == rs:
                pred = "SELL"
            else:
                pred = "HOLD"

            buy_margin = rh - rb
            sell_margin = rh - rs

            fwd = {}
            for h, lbl in [(6, "30m"), (12, "1h"), (24, "2h"), (48, "4h"), (96, "8h")]:
                if step + h < len(df_test_ind):
                    fp = float(df_test_ind.iloc[step + h]["close"])
                    fwd[lbl] = (fp / price - 1) * 100

            records.append({
                "pred": pred, "buy_margin": buy_margin, "sell_margin": sell_margin,
                **{f"fwd_{k}": v for k, v in fwd.items()},
            })

        elapsed = time.time() - t0
        rdf = pd.DataFrame(records)
        log(f"  {len(rdf):,} samples in {elapsed:.0f}s")

        # Signal distribution
        for sig in ["BUY", "SELL", "HOLD"]:
            n = (rdf["pred"] == sig).sum()
            log(f"    {sig}: {n:,} ({n/len(rdf)*100:.0f}%)")

        # Forward returns for BUY signals at various horizons
        buy_df = rdf[rdf["pred"] == "BUY"]
        hold_df = rdf[rdf["pred"] == "HOLD"]

        log(f"\n  BUY signal forward returns ({len(buy_df):,} signals):")
        for horizon in ["30m", "1h", "2h", "4h", "8h"]:
            col = f"fwd_{horizon}"
            if col in buy_df.columns:
                valid = buy_df[col].dropna()
                if len(valid) > 10:
                    log(f"    {horizon:>3s}: mean={valid.mean():+.4f}%  "
                        f"med={valid.median():+.4f}%  >0.2%={((valid > 0.2).mean()*100):.0f}%")

        # Compare with HOLD baseline
        log(f"  HOLD baseline forward returns ({len(hold_df):,}):")
        for horizon in ["30m", "1h", "2h", "4h", "8h"]:
            col = f"fwd_{horizon}"
            if col in hold_df.columns:
                valid = hold_df[col].dropna()
                if len(valid) > 10:
                    log(f"    {horizon:>3s}: mean={valid.mean():+.4f}%  "
                        f"med={valid.median():+.4f}%")

        # High-confidence BUY: margin > 5
        hc_buy = buy_df[buy_df["buy_margin"] > 5]
        if len(hc_buy) > 10:
            log(f"  High-confidence BUY (margin>5, n={len(hc_buy):,}):")
            for horizon in ["30m", "1h", "2h", "4h", "8h"]:
                col = f"fwd_{horizon}"
                if col in hc_buy.columns:
                    valid = hc_buy[col].dropna()
                    if len(valid) > 5:
                        log(f"    {horizon:>3s}: mean={valid.mean():+.4f}%  "
                            f"med={valid.median():+.4f}%  >0.2%={((valid > 0.2).mean()*100):.0f}%")


if __name__ == "__main__":
    main()
