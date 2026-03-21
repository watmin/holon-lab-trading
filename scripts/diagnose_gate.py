"""Gate-only diagnostic: does the regime transition signal have raw edge?

No tree, no guards, no trading sim. Just:
1. Train gate on 2019-2020
2. Scan 2021-2024 candle by candle
3. Log every transition: type, price, forward returns (1h/2h/4h)
4. Answer: do BUY-biased transitions precede price increases?

Fail fast — if the gate signal has no edge, the tree can't save it.

Usage:
    ./scripts/run_with_venv.sh python holon-lab-trading/scripts/diagnose_gate.py
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


def log(msg: str):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def main():
    log("Loading data...")
    df = pd.read_parquet("holon-lab-trading/data/btc_5m_raw.parquet")
    ts = pd.to_datetime(df["ts"])
    factory = TechnicalFeatureFactory()

    # ===================================================================
    # Train gate on 2019-2020
    # ===================================================================
    log("Training gate on 2019-2020...")
    df_seed = df[ts <= "2020-12-31"].reset_index(drop=True)
    df_seed_ind = factory.compute_indicators(df_seed)
    labels = label_regimes(df_seed_ind, window=HolonGate.WINDOW)

    client = HolonClient(dimensions=HolonGate.DIM)
    gate = HolonGate(client)
    gate.train_regimes(df_seed_ind, labels, n_train=200)
    log(f"  Trained {len(gate.regime_subspaces)} regime subspaces")

    # ===================================================================
    # Scan test periods
    # ===================================================================
    periods = [
        ("2021", "2021-01-01", "2021-12-31"),
        ("2022", "2022-01-01", "2022-12-31"),
        ("2023", "2023-01-01", "2023-12-31"),
        ("2024", "2024-01-01", "2024-12-31"),
    ]

    fwd_bars = {"30m": 6, "1h": 12, "2h": 24, "4h": 48}

    all_transitions = []

    for period_name, start, end in periods:
        log(f"\n--- Scanning {period_name} ---")
        mask = (ts >= start) & (ts <= end)
        df_period = df[mask].reset_index(drop=True)
        if len(df_period) < 500:
            log(f"  Skipping — only {len(df_period)} rows")
            continue

        df_ind = factory.compute_indicators(df_period)
        close = df_ind["close"].values
        n = len(df_ind)

        features = gate.precompute_features(df_ind)

        gate.reset()
        t0 = time.time()
        transitions_this_period = 0

        for idx in range(HolonGate.WINDOW, n):
            signal = gate.check_fast(features, idx)

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

            if transitions_this_period % 500 == 0:
                elapsed = time.time() - t0
                log(f"  {idx:,}/{n:,} | {transitions_this_period} transitions | {elapsed:.0f}s")

        elapsed = time.time() - t0
        log(f"  {period_name}: {transitions_this_period} transitions in {n:,} candles "
            f"({transitions_this_period/n*100:.1f}% fire rate) | {elapsed:.0f}s")

    # ===================================================================
    # Analysis
    # ===================================================================
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
            clears_fee = (valid.abs() > 0.05).mean() * 100  # 0.05% round trip
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
            f"pos={s['pos_rate_1h']:.0f}% | tenure={s['mean_tenure']:.0f}")

    # --- By period ---
    log(f"\n{'=' * 70}")
    log("BY PERIOD")
    log(f"{'=' * 70}")

    for period_name in ["2021", "2022", "2023", "2024"]:
        sub = tdf[tdf["period"] == period_name]
        if sub.empty:
            continue
        buy_sub = sub[sub["direction"] == "BUY"]
        sell_sub = sub[sub["direction"] == "SELL"]
        log(f"\n  {period_name}:")
        for label, dsub, dname in [("BUY", buy_sub, "BUY"), ("SELL", sell_sub, "SELL")]:
            if dsub.empty:
                continue
            valid_1h = dsub["fwd_1h_pct"].dropna()
            if valid_1h.empty:
                continue
            log(f"    {dname}: n={len(dsub)}, 1h mean={valid_1h.mean():+.3f}%, "
                f"pos={( valid_1h > 0).mean()*100:.0f}%")

    # --- Tenure analysis ---
    log(f"\n{'=' * 70}")
    log("TENURE ANALYSIS (does longer regime tenure = better signal?)")
    log(f"{'=' * 70}")

    for direction in ["BUY", "SELL"]:
        sub = tdf[tdf["direction"] == direction]
        if sub.empty:
            continue
        for min_t in [1, 3, 6, 12, 24]:
            filtered = sub[sub["tenure"] >= min_t]
            valid = filtered["fwd_1h_pct"].dropna()
            if len(valid) < 5:
                continue
            log(f"  {direction} tenure>={min_t:2d}: n={len(valid):4d}, "
                f"1h={valid.mean():+.3f}%, pos={( valid > 0).mean()*100:.0f}%")

    log(f"\n{'=' * 70}")
    log("DONE")
    log(f"{'=' * 70}")


if __name__ == "__main__":
    main()
