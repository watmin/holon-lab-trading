"""Bidirectional edge analysis across multiple market regimes.

Tests whether signals have positive expected value AFTER FEES in both
directions and across different years (bull, bear, sideways).

Uses SPREAD w=48 encoding (best high-confidence forward returns).
Measures per-trade edge, not just accuracy.

Usage:
    ./scripts/run_with_venv.sh python holon-lab-trading/scripts/explore_edge.py
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
WINDOW = 48
FEE_PCT = 0.1  # 0.1% per trade (0.2% round trip)


def log(msg: str):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def build_spread_walkable(factory, df_ind, idx):
    start = int(idx) - WINDOW + 1
    if start < 0 or int(idx) >= len(df_ind):
        return None

    candles = []
    for i in range(WINDOW):
        raw = factory.compute_candle_row(df_ind, start + i)
        candles.append(raw)

    # Geometry
    geom = {"body": [], "upper": [], "lower": [], "cpos": []}
    for i in range(WINDOW):
        row = df_ind.iloc[start + i]
        o, h, l, c = row["open"], row["high"], row["low"], row["close"]
        rng = max(h - l, 1e-10)
        geom["body"].append((c - o) / rng)
        geom["upper"].append((h - max(o, c)) / rng)
        geom["lower"].append((min(o, c) - l) / rng)
        geom["cpos"].append((c - l) / rng)

    walkable = {}
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

    for gname, gvals in geom.items():
        walkable[f"geom_{gname}"] = WalkableSpread([LinearScale(v) for v in gvals])

    return walkable


def encode_at(client, factory, df_ind, idx):
    w = build_spread_walkable(factory, df_ind, idx)
    if w is None:
        return None
    return client.encoder.encode_walkable_striped(w, n_stripes=N_STRIPES)


def train_subspaces(client, factory, df_ind, troughs, peaks, rng, n_train=200):
    rev_set = set(troughs.tolist()) | set(peaks.tolist())
    hold_pool = [i for i in range(WINDOW + 1, len(df_ind)) if i not in rev_set]

    ss_b = StripedSubspace(dim=DIM, k=K, n_stripes=N_STRIPES)
    ss_s = StripedSubspace(dim=DIM, k=K, n_stripes=N_STRIPES)
    ss_h = StripedSubspace(dim=DIM, k=K, n_stripes=N_STRIPES)

    for label, ss, indices in [("BUY", ss_b, troughs), ("SELL", ss_s, peaks)]:
        valid = indices[(indices >= WINDOW + 1) & (indices < len(df_ind))]
        count = 0
        for idx in valid[:n_train + 50]:
            try:
                v = encode_at(client, factory, df_ind, idx)
                if v:
                    ss.update(v)
                    count += 1
            except Exception:
                pass
            if count >= n_train:
                break
        log(f"    {label}: {count} trained")

    hold_sample = rng.choice(hold_pool, size=min(n_train + 50, len(hold_pool)), replace=False)
    count = 0
    for idx in hold_sample:
        try:
            v = encode_at(client, factory, df_ind, idx)
            if v:
                ss_h.update(v)
                count += 1
        except Exception:
            pass
        if count >= n_train:
            break
    log(f"    HOLD: {count} trained")
    return ss_b, ss_s, ss_h


def score_period(client, factory, df_ind, ss_b, ss_s, ss_h, stride=10):
    records = []
    for step in range(WINDOW, len(df_ind), stride):
        try:
            v = encode_at(client, factory, df_ind, step)
            if v is None:
                continue
        except Exception:
            continue

        rb = ss_b.residual(v)
        rs = ss_s.residual(v)
        rh = ss_h.residual(v)
        price = float(df_ind.iloc[step]["close"])

        best = min(rb, rs, rh)
        pred = "BUY" if best == rb else ("SELL" if best == rs else "HOLD")
        buy_margin = rh - rb
        sell_margin = rh - rs

        fwd = {}
        for h, lbl in [(6, "30m"), (12, "1h"), (24, "2h"), (48, "4h")]:
            if step + h < len(df_ind):
                fp = float(df_ind.iloc[step + h]["close"])
                fwd[lbl] = (fp / price - 1) * 100

        records.append({
            "step": step, "price": price, "pred": pred,
            "buy_margin": buy_margin, "sell_margin": sell_margin,
            **{f"fwd_{k}": v for k, v in fwd.items()},
        })

    return pd.DataFrame(records)


def analyze_edge(rdf, period_name, bah_pct):
    log(f"\n  --- {period_name} (B&H: {bah_pct:+.1f}%) ---")

    for sig in ["BUY", "SELL"]:
        subset = rdf[rdf["pred"] == sig]
        if subset.empty:
            continue

        margin_col = "buy_margin" if sig == "BUY" else "sell_margin"

        log(f"\n  {sig} signals: {len(subset):,} ({len(subset)/len(rdf)*100:.0f}%)")

        for horizon in ["30m", "1h", "2h", "4h"]:
            col = f"fwd_{horizon}"
            if col not in subset.columns:
                continue
            valid = subset[col].dropna()
            if len(valid) < 10:
                continue

            if sig == "BUY":
                raw_edge = valid.mean()
                edge_after_fee = raw_edge - FEE_PCT
                pct_profitable = (valid > FEE_PCT).mean() * 100
            else:
                raw_edge = -valid.mean()  # SELL profits from price drops
                edge_after_fee = raw_edge - FEE_PCT
                pct_profitable = (valid < -FEE_PCT).mean() * 100

            log(f"    {horizon:>3s}: raw_edge={raw_edge:+.4f}%  "
                f"after_fee={edge_after_fee:+.4f}%  "
                f"profitable={pct_profitable:.0f}%  n={len(valid):,}")

        # High-confidence subset
        hc = subset[subset[margin_col] > 5]
        if len(hc) > 10:
            log(f"    HIGH-CONF (margin>5, n={len(hc):,}):")
            for horizon in ["30m", "1h", "2h", "4h"]:
                col = f"fwd_{horizon}"
                if col not in hc.columns:
                    continue
                valid = hc[col].dropna()
                if len(valid) < 5:
                    continue
                if sig == "BUY":
                    raw_edge = valid.mean()
                    edge_after_fee = raw_edge - FEE_PCT
                    pct_profitable = (valid > FEE_PCT).mean() * 100
                else:
                    raw_edge = -valid.mean()
                    edge_after_fee = raw_edge - FEE_PCT
                    pct_profitable = (valid < -FEE_PCT).mean() * 100
                log(f"      {horizon:>3s}: raw_edge={raw_edge:+.4f}%  "
                    f"after_fee={edge_after_fee:+.4f}%  "
                    f"profitable={pct_profitable:.0f}%")

    # HOLD baseline
    hold = rdf[rdf["pred"] == "HOLD"]
    if not hold.empty and "fwd_1h" in hold.columns:
        log(f"\n  HOLD baseline ({len(hold):,}):")
        for horizon in ["30m", "1h", "2h", "4h"]:
            col = f"fwd_{horizon}"
            if col in hold.columns:
                valid = hold[col].dropna()
                if len(valid) > 10:
                    log(f"    {horizon:>3s}: mean={valid.mean():+.4f}%")


def main():
    log("Loading data...")
    df = pd.read_parquet("holon-lab-trading/data/btc_5m_raw.parquet")
    ts = pd.to_datetime(df["ts"])
    factory = TechnicalFeatureFactory()
    rng = np.random.default_rng(42)

    # Train on 2019-2020
    df_seed = df[ts <= "2020-12-31"].reset_index(drop=True)
    close_seed = df_seed["close"].values
    prominence = float(np.median(close_seed)) * 0.02
    peaks, _ = find_peaks(close_seed, prominence=prominence, distance=12)
    troughs, _ = find_peaks(-close_seed, prominence=prominence, distance=12)

    df_seed_ind = factory.compute_indicators(df_seed)
    n_dropped = len(df_seed) - len(df_seed_ind)
    peaks_ind = peaks - n_dropped
    troughs_ind = troughs - n_dropped

    client = HolonClient(dimensions=DIM)

    log("Training subspaces on 2019-2020...")
    ss_b, ss_s, ss_h = train_subspaces(
        client, factory, df_seed_ind, troughs_ind, peaks_ind, rng
    )

    # Test across multiple years/periods
    periods = [
        ("2021 (bull)", "2021-01-01", "2021-12-31"),
        ("2022 (bear)", "2022-01-01", "2022-12-31"),
        ("2023 (recovery)", "2023-01-01", "2023-12-31"),
        ("2024-H1 (your selloff)", "2024-01-01", "2024-06-30"),
        ("2024-H2", "2024-07-01", "2024-12-31"),
    ]

    for name, start, end in periods:
        log(f"\n{'=' * 70}")
        log(f"PERIOD: {name}")
        log(f"{'=' * 70}")

        mask = (ts >= start) & (ts <= end)
        df_period = df[mask].reset_index(drop=True)
        if len(df_period) < WINDOW + 100:
            log(f"  Skipping — only {len(df_period)} rows")
            continue

        df_period_ind = factory.compute_indicators(df_period)
        bah_start = float(df_period_ind.iloc[WINDOW]["close"])
        bah_end = float(df_period_ind.iloc[-1]["close"])
        bah_pct = (bah_end / bah_start - 1) * 100

        log(f"  {len(df_period_ind):,} candles, ${bah_start:,.0f} → ${bah_end:,.0f}")
        log(f"  Scoring (stride=10)...")
        t0 = time.time()
        rdf = score_period(client, factory, df_period_ind, ss_b, ss_s, ss_h, stride=10)
        log(f"  {len(rdf):,} samples in {time.time()-t0:.0f}s")

        analyze_edge(rdf, name, bah_pct)


if __name__ == "__main__":
    main()
