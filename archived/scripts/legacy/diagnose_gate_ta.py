"""Gate + TA diagnostic: does TA at transition points separate winners from losers?

Reuses the adaptive gate but adds TA indicator values at each transition.
Then checks: does filtering by TA improve forward returns?

For each BUY transition, check:
  - RSI < 30 (oversold) vs RSI > 30
  - MACD hist negative (momentum shifting) vs positive
  - Price below lower BB vs above
  - Volume spike vs normal

If TA filtering turns marginal edge into real edge, we have our tree design.

Usage:
    ./scripts/run_with_venv.sh python holon-lab-trading/scripts/diagnose_gate_ta.py
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

MAX_CANDLES = 10_000


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

    fwd_bars = {"1h": 12, "2h": 24, "4h": 48}
    all_transitions = []

    for period_name, start, end in periods:
        log(f"\n--- Scanning {period_name} ---")
        mask = (ts >= start) & (ts <= end)
        df_period = df[mask].reset_index(drop=True)
        if len(df_period) < 500:
            continue

        df_ind = factory.compute_indicators(df_period)
        close = df_ind["close"].values
        n = len(df_ind)
        scan_end = min(n, HolonGate.WINDOW + MAX_CANDLES)

        features = gate.precompute_features(df_ind)

        gate._tenure = 0
        gate._current_regime = Regime.UNKNOWN
        t0 = time.time()

        for idx in range(HolonGate.WINDOW, scan_end):
            signal = gate.check_fast(features, idx, adaptive=True)

            if not signal.fired or signal.transition_type is None:
                continue

            price = close[idx]
            row_data = df_ind.iloc[idx]

            # TA values at transition point
            rsi = float(row_data.get("rsi", 50))
            macd_hist = float(row_data.get("macd_hist_r", 0))
            bb_upper = float(row_data.get("bb_upper", price))
            bb_lower = float(row_data.get("bb_lower", price))
            bb_width = float(row_data.get("bb_width", 0))
            adx = float(row_data.get("adx", 0))
            vol_r = float(row_data.get("vol_r", 0))
            sma20_r = float(row_data.get("sma20_r", 0))
            sma50_r = float(row_data.get("sma50_r", 0))
            ret = float(row_data.get("ret", 0))

            bb_pos = (price - bb_lower) / max(bb_upper - bb_lower, 1e-10)

            row = {
                "period": period_name,
                "idx": idx,
                "price": price,
                "transition": signal.transition_type,
                "tenure": signal.regime_tenure,
                "rsi": rsi,
                "macd_hist": macd_hist,
                "bb_pos": bb_pos,
                "bb_width": bb_width,
                "adx": adx,
                "vol_r": vol_r,
                "sma20_r": sma20_r,
                "sma50_r": sma50_r,
                "ret": ret,
            }

            if signal.transition_type in BUY_TRANSITIONS:
                row["direction"] = "BUY"
            elif signal.transition_type in SELL_TRANSITIONS:
                row["direction"] = "SELL"
            else:
                row["direction"] = "NEUTRAL"

            for label, bars in fwd_bars.items():
                if idx + bars < n:
                    fwd_price = close[idx + bars]
                    row[f"fwd_{label}_pct"] = (fwd_price / price - 1) * 100
                else:
                    row[f"fwd_{label}_pct"] = np.nan

            all_transitions.append(row)

        elapsed = time.time() - t0
        total_candles = scan_end - HolonGate.WINDOW
        transitions_count = sum(1 for t in all_transitions if t["period"] == period_name)
        log(f"  {period_name}: {transitions_count} transitions | {elapsed:.0f}s")

    if not all_transitions:
        log("No transitions!")
        return

    tdf = pd.DataFrame(all_transitions)
    log(f"\n{'=' * 70}")
    log(f"GATE + TA ANALYSIS: {len(tdf)} total transitions")
    log(f"{'=' * 70}")

    # ===================================================================
    # BUY analysis: which TA filters improve forward returns?
    # ===================================================================
    buy = tdf[tdf["direction"] == "BUY"].copy()
    sell = tdf[tdf["direction"] == "SELL"].copy()

    for direction, sub, good_col in [("BUY", buy, "fwd_1h_pct"), ("SELL", sell, "fwd_1h_pct")]:
        if sub.empty:
            continue

        baseline_1h = sub[good_col].dropna()
        if direction == "SELL":
            baseline_1h = -baseline_1h  # flip: for SELL, negative fwd return = good
            sub = sub.copy()
            sub["fwd_1h_flipped"] = -sub["fwd_1h_pct"]
            sub["fwd_4h_flipped"] = -sub["fwd_4h_pct"]
            good_col = "fwd_1h_flipped"

        log(f"\n  --- {direction} TRANSITIONS ({len(sub)}) ---")
        log(f"  Baseline 1h: mean={baseline_1h.mean():+.3f}%, pos={( baseline_1h > 0).mean()*100:.0f}%")

        # RSI filters
        log(f"\n  RSI filters:")
        for label, condition in [
            ("RSI < 30 (oversold)", sub["rsi"] < 30),
            ("RSI < 40", sub["rsi"] < 40),
            ("RSI 40-60 (neutral)", (sub["rsi"] >= 40) & (sub["rsi"] <= 60)),
            ("RSI > 60", sub["rsi"] > 60),
            ("RSI > 70 (overbought)", sub["rsi"] > 70),
        ]:
            filtered = sub[condition][good_col].dropna()
            if len(filtered) < 5:
                continue
            log(f"    {label:25s}: n={len(filtered):4d}, "
                f"mean={filtered.mean():+.3f}%, pos={( filtered > 0).mean()*100:.0f}%")

        # MACD histogram filters
        log(f"\n  MACD histogram filters:")
        for label, condition in [
            ("MACD hist < -0.5%", sub["macd_hist"] < -0.005),
            ("MACD hist < 0", sub["macd_hist"] < 0),
            ("MACD hist > 0", sub["macd_hist"] > 0),
            ("MACD hist > 0.5%", sub["macd_hist"] > 0.005),
        ]:
            filtered = sub[condition][good_col].dropna()
            if len(filtered) < 5:
                continue
            log(f"    {label:25s}: n={len(filtered):4d}, "
                f"mean={filtered.mean():+.3f}%, pos={( filtered > 0).mean()*100:.0f}%")

        # Bollinger Band position
        log(f"\n  BB position filters:")
        for label, condition in [
            ("BB pos < 0.2 (near low)", sub["bb_pos"] < 0.2),
            ("BB pos 0.2-0.5", (sub["bb_pos"] >= 0.2) & (sub["bb_pos"] < 0.5)),
            ("BB pos 0.5-0.8", (sub["bb_pos"] >= 0.5) & (sub["bb_pos"] < 0.8)),
            ("BB pos > 0.8 (near high)", sub["bb_pos"] > 0.8),
        ]:
            filtered = sub[condition][good_col].dropna()
            if len(filtered) < 5:
                continue
            log(f"    {label:25s}: n={len(filtered):4d}, "
                f"mean={filtered.mean():+.3f}%, pos={( filtered > 0).mean()*100:.0f}%")

        # ADX (trend strength)
        log(f"\n  ADX filters:")
        for label, condition in [
            ("ADX < 20 (weak trend)", sub["adx"] < 20),
            ("ADX 20-40 (moderate)", (sub["adx"] >= 20) & (sub["adx"] < 40)),
            ("ADX > 40 (strong trend)", sub["adx"] > 40),
        ]:
            filtered = sub[condition][good_col].dropna()
            if len(filtered) < 5:
                continue
            log(f"    {label:25s}: n={len(filtered):4d}, "
                f"mean={filtered.mean():+.3f}%, pos={( filtered > 0).mean()*100:.0f}%")

        # Volume
        log(f"\n  Volume filters:")
        vol_p50 = sub["vol_r"].median()
        vol_p75 = sub["vol_r"].quantile(0.75)
        for label, condition in [
            ("Vol below median", sub["vol_r"] < vol_p50),
            ("Vol above median", sub["vol_r"] >= vol_p50),
            ("Vol top 25%", sub["vol_r"] >= vol_p75),
        ]:
            filtered = sub[condition][good_col].dropna()
            if len(filtered) < 5:
                continue
            log(f"    {label:25s}: n={len(filtered):4d}, "
                f"mean={filtered.mean():+.3f}%, pos={( filtered > 0).mean()*100:.0f}%")

        # SMA position (price relative to moving averages)
        log(f"\n  SMA filters:")
        for label, condition in [
            ("Price < SMA20", sub["sma20_r"] < 0),
            ("Price > SMA20", sub["sma20_r"] >= 0),
            ("Price < SMA50", sub["sma50_r"] < 0),
            ("Price > SMA50", sub["sma50_r"] >= 0),
        ]:
            filtered = sub[condition][good_col].dropna()
            if len(filtered) < 5:
                continue
            log(f"    {label:25s}: n={len(filtered):4d}, "
                f"mean={filtered.mean():+.3f}%, pos={( filtered > 0).mean()*100:.0f}%")

        # Combined filters (best candidates)
        log(f"\n  Combined filters:")
        combos = [
            ("RSI<40 + MACD<0", (sub["rsi"] < 40) & (sub["macd_hist"] < 0)),
            ("RSI<40 + BB<0.3", (sub["rsi"] < 40) & (sub["bb_pos"] < 0.3)),
            ("RSI<40 + ADX>25", (sub["rsi"] < 40) & (sub["adx"] > 25)),
            ("MACD<0 + BB<0.3", (sub["macd_hist"] < 0) & (sub["bb_pos"] < 0.3)),
            ("RSI<40+MACD<0+BB<0.3", (sub["rsi"] < 40) & (sub["macd_hist"] < 0) & (sub["bb_pos"] < 0.3)),
            ("tenure>=6 + RSI<40", (sub["tenure"] >= 6) & (sub["rsi"] < 40)),
            ("tenure>=6 + MACD<0", (sub["tenure"] >= 6) & (sub["macd_hist"] < 0)),
        ]
        for label, condition in combos:
            filtered = sub[condition][good_col].dropna()
            if len(filtered) < 3:
                continue
            log(f"    {label:25s}: n={len(filtered):4d}, "
                f"mean={filtered.mean():+.3f}%, pos={( filtered > 0).mean()*100:.0f}%")

    log(f"\n{'=' * 70}")
    log("DONE")
    log(f"{'=' * 70}")


if __name__ == "__main__":
    main()
