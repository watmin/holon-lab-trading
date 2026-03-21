"""Fast gate diagnostic: 10k candle sample per year.

Same analysis as diagnose_gate.py but caps each period at 10k candles
to finish in minutes instead of hours.

Usage:
    ./scripts/run_with_venv.sh python holon-lab-trading/scripts/diagnose_gate_fast.py
"""

from __future__ import annotations

import sys
import time
from pathlib import Path

import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).parent.parent))

from trading.features import TechnicalFeatureFactory
from trading.gate import HolonGate, Regime, label_regimes

from holon import HolonClient

BUY_TRANSITIONS = {
    "TREND_DOWN → CONSOLIDATION",
    "TREND_DOWN → VOLATILE",
    "TREND_DOWN → TREND_UP",
    "VOLATILE → TREND_UP",
}

SELL_TRANSITIONS = {
    "TREND_UP → CONSOLIDATION",
    "TREND_UP → VOLATILE",
    "TREND_UP → TREND_DOWN",
    "VOLATILE → TREND_DOWN",
}

MAX_CANDLES = 10_000  # ~35 days of 5-minute data per period


def log(msg: str):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def main():
    log("Loading data...")
    df = pd.read_parquet("holon-lab-trading/data/btc_5m_raw.parquet")
    ts = pd.to_datetime(df["ts"])
    factory = TechnicalFeatureFactory()

    log("Training gate on 2019-2020...")
    df_seed = df[ts <= "2020-12-31"].reset_index(drop=True)
    df_seed_ind = factory.compute_indicators(df_seed)
    labels = label_regimes(df_seed_ind, window=HolonGate.WINDOW)

    client = HolonClient(dimensions=HolonGate.DIM)
    gate = HolonGate(client)
    gate.train_regimes(df_seed_ind, labels, n_train=200)
    log(f"  Trained {len(gate.regime_subspaces)} regime subspaces")

    periods = [
        ("2021", "2021-01-01", "2021-12-31"),
        ("2022", "2022-01-01", "2022-12-31"),
        ("2023", "2023-01-01", "2023-12-31"),
        ("2024", "2024-01-01", "2024-12-31"),
    ]

    fwd_bars = {"30m": 6, "1h": 12, "2h": 24, "4h": 48}

    all_transitions = []

    for period_name, start, end in periods:
        log(f"\n--- Scanning {period_name} (max {MAX_CANDLES:,} candles) ---")
        mask = (ts >= start) & (ts <= end)
        df_period = df[mask].reset_index(drop=True)
        if len(df_period) < 500:
            log(f"  Skipping — only {len(df_period)} rows")
            continue

        df_ind = factory.compute_indicators(df_period)
        close = df_ind["close"].values
        n = len(df_ind)
        scan_end = min(n, HolonGate.WINDOW + MAX_CANDLES)

        features = gate.precompute_features(df_ind)

        gate.reset()
        t0 = time.time()
        transitions_this_period = 0
        regime_counts = {}

        for idx in range(HolonGate.WINDOW, scan_end):
            signal = gate.check_fast(features, idx)

            # Track regime distribution
            r = signal.current_regime.value
            regime_counts[r] = regime_counts.get(r, 0) + 1

            if not signal.fired or signal.transition_type is None:
                continue

            transitions_this_period += 1
            price = close[idx]

            row = {
                "period": period_name,
                "idx": idx,
                "price": price,
                "transition": signal.transition_type,
                "magnitude": signal.magnitude,
                "tenure": signal.regime_tenure,
            }

            for label, bars in fwd_bars.items():
                if idx + bars < n:
                    fwd_price = close[idx + bars]
                    row[f"fwd_{label}_pct"] = (fwd_price / price - 1) * 100
                else:
                    row[f"fwd_{label}_pct"] = np.nan

            if signal.transition_type in BUY_TRANSITIONS:
                row["direction"] = "BUY"
            elif signal.transition_type in SELL_TRANSITIONS:
                row["direction"] = "SELL"
            else:
                row["direction"] = "NEUTRAL"

            all_transitions.append(row)

        elapsed = time.time() - t0
        total_candles = scan_end - HolonGate.WINDOW
        log(f"  {period_name}: {transitions_this_period} transitions in {total_candles:,} candles "
            f"({transitions_this_period/max(total_candles,1)*100:.1f}% fire rate) | {elapsed:.0f}s")
        log(f"  Regime distribution: {regime_counts}")
        log(f"  Speed: {elapsed/max(total_candles,1)*1000:.1f}ms/candle")

    if not all_transitions:
        log("No transitions found!")
        return

    tdf = pd.DataFrame(all_transitions)
    log(f"\n{'=' * 70}")
    log(f"TOTAL: {len(tdf)} transitions across all periods")
    log(f"{'=' * 70}")

    # --- By direction ---
    for direction in ["BUY", "SELL", "NEUTRAL"]:
        sub = tdf[tdf["direction"] == direction]
        if sub.empty:
            continue
        log(f"\n  {direction} transitions: {len(sub)}")
        for label in fwd_bars:
            col = f"fwd_{label}_pct"
            valid = sub[col].dropna()
            if valid.empty:
                continue
            mean = valid.mean()
            median = valid.median()
            pos_rate = (valid > 0).mean() * 100
            clears_fee = (valid.abs() > 0.05).mean() * 100
            log(f"    {label}: mean={mean:+.3f}% median={median:+.3f}% "
                f"pos={pos_rate:.0f}% clears_fee={clears_fee:.0f}%")

    # --- By specific transition type ---
    log(f"\n{'=' * 70}")
    log("BY TRANSITION TYPE (sorted by 1h mean forward return)")
    log(f"{'=' * 70}")

    type_stats = []
    for tt, group in tdf.groupby("transition"):
        valid_1h = group["fwd_1h_pct"].dropna()
        if len(valid_1h) < 5:
            continue
        type_stats.append({
            "transition": tt,
            "count": len(group),
            "direction": group["direction"].iloc[0],
            "mean_1h": valid_1h.mean(),
            "median_1h": valid_1h.median(),
            "pos_rate_1h": (valid_1h > 0).mean() * 100,
            "mean_tenure": group["tenure"].mean(),
        })

    type_stats.sort(key=lambda x: x["mean_1h"], reverse=True)
    for s in type_stats:
        log(f"  {s['transition']:40s} | n={s['count']:4d} | "
            f"dir={s['direction']:7s} | 1h={s['mean_1h']:+.3f}% | "
            f"pos={s['pos_rate_1h']:.0f}% | tenure={s['mean_tenure']:.1f}")

    # --- By period ---
    log(f"\n{'=' * 70}")
    log("BY PERIOD")
    log(f"{'=' * 70}")

    for period_name in ["2021", "2022", "2023", "2024"]:
        sub = tdf[tdf["period"] == period_name]
        if sub.empty:
            continue
        log(f"\n  {period_name}:")
        for dname in ["BUY", "SELL"]:
            dsub = sub[sub["direction"] == dname]
            if dsub.empty:
                continue
            valid_1h = dsub["fwd_1h_pct"].dropna()
            valid_4h = dsub["fwd_4h_pct"].dropna()
            if valid_1h.empty:
                continue
            log(f"    {dname}: n={len(dsub)}, "
                f"1h mean={valid_1h.mean():+.3f}% pos={( valid_1h > 0).mean()*100:.0f}%, "
                f"4h mean={valid_4h.mean():+.3f}% pos={( valid_4h > 0).mean()*100:.0f}%")

    # --- Tenure analysis ---
    log(f"\n{'=' * 70}")
    log("TENURE ANALYSIS (does longer regime tenure = better signal?)")
    log(f"{'=' * 70}")

    log(f"\n  Tenure distribution:")
    for pct in [25, 50, 75, 90, 95]:
        log(f"    p{pct}: {tdf['tenure'].quantile(pct/100):.0f} candles")

    for direction in ["BUY", "SELL"]:
        sub = tdf[tdf["direction"] == direction]
        if sub.empty:
            continue
        log(f"\n  {direction}:")
        for min_t in [1, 2, 3, 6, 12, 24, 48]:
            filtered = sub[sub["tenure"] >= min_t]
            valid = filtered["fwd_1h_pct"].dropna()
            if len(valid) < 3:
                continue
            log(f"    tenure>={min_t:2d}: n={len(valid):4d}, "
                f"1h mean={valid.mean():+.3f}%, "
                f"median={valid.median():+.3f}%, "
                f"pos={( valid > 0).mean()*100:.0f}%")

    # --- Magnitude analysis ---
    log(f"\n{'=' * 70}")
    log("MAGNITUDE ANALYSIS (does higher margin = better signal?)")
    log(f"{'=' * 70}")

    for direction in ["BUY", "SELL"]:
        sub = tdf[tdf["direction"] == direction]
        if sub.empty:
            continue
        log(f"\n  {direction}:")
        for pct_lo, pct_hi, label in [
            (0, 25, "bottom 25%"),
            (25, 50, "25-50%"),
            (50, 75, "50-75%"),
            (75, 100, "top 25%"),
        ]:
            lo = sub["magnitude"].quantile(pct_lo / 100)
            hi = sub["magnitude"].quantile(pct_hi / 100)
            filtered = sub[(sub["magnitude"] >= lo) & (sub["magnitude"] < hi)]
            valid = filtered["fwd_1h_pct"].dropna()
            if len(valid) < 3:
                continue
            log(f"    mag {label:12s}: n={len(valid):4d}, "
                f"1h mean={valid.mean():+.3f}%, pos={( valid > 0).mean()*100:.0f}%")

    log(f"\n{'=' * 70}")
    log("DONE")
    log(f"{'=' * 70}")


if __name__ == "__main__":
    main()
