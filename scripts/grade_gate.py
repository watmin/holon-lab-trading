"""Grade the gate signal against labeled reversals and compute oracle returns.

Three questions:
  1. ORACLE: What's the theoretical max if we trade every labeled reversal perfectly?
  2. PRECISION: When the gate fires, how often is it near a real reversal?
  3. RECALL: Of all real reversals, how many does the gate fire near?

Also computes gate-only equity curve (trading every gate fire) to see if
raw gate signals have any edge at all, before tree filtering.

Usage:
    ./scripts/run_with_venv.sh python holon-lab-trading/scripts/grade_gate.py
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

FEE_PCT = 0.025  # per side
PROXIMITY = 6  # candles — gate fire within ±N of a label counts as "near"
MAX_CANDLES = 10_000


def log(msg: str):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def oracle_return(close: np.ndarray, actions: np.ndarray, fee_pct: float) -> dict:
    """Simulate perfect trading at every labeled reversal."""
    equity = 10_000.0
    position = 0.0
    entry_price = 0.0
    trades = []

    for i in range(len(close)):
        act = actions[i]
        price = float(close[i])

        if act == "BUY" and position == 0:
            cost = equity * (fee_pct / 100)
            position = (equity - cost) / price
            entry_price = price
            equity = 0.0

        elif act == "SELL" and position > 0:
            proceeds = position * price
            cost = proceeds * (fee_pct / 100)
            pnl = (price / entry_price - 1) * 100
            equity = proceeds - cost
            position = 0.0
            trades.append(pnl)

    # Close out
    if position > 0:
        final = position * float(close[-1])
    else:
        final = equity

    return {
        "final_equity": final,
        "return_pct": (final / 10_000 - 1) * 100,
        "n_trades": len(trades),
        "win_rate": np.mean([t > 0 for t in trades]) * 100 if trades else 0,
        "avg_trade": np.mean(trades) if trades else 0,
    }


def gate_equity(close: np.ndarray, gate_dirs: list, fee_pct: float) -> dict:
    """Simulate trading every gate fire (direction from transition type)."""
    equity = 10_000.0
    position = 0.0
    entry_price = 0.0
    trades = []

    for i, (idx, direction) in enumerate(gate_dirs):
        price = float(close[idx])

        if direction == "BUY" and position == 0:
            cost = equity * (fee_pct / 100)
            position = (equity - cost) / price
            entry_price = price
            equity = 0.0

        elif direction == "SELL" and position > 0:
            proceeds = position * price
            cost = proceeds * (fee_pct / 100)
            pnl = (price / entry_price - 1) * 100
            equity = proceeds - cost
            position = 0.0
            trades.append(pnl)

    if position > 0:
        final = position * float(close[-1])
    else:
        final = equity

    return {
        "final_equity": final,
        "return_pct": (final / 10_000 - 1) * 100,
        "n_trades": len(trades),
        "win_rate": np.mean([t > 0 for t in trades]) * 100 if trades else 0,
        "avg_trade": np.mean(trades) if trades else 0,
    }


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


def main():
    log("Loading data...")
    df_labels = pd.read_parquet("holon-lab-trading/data/reversal_labels.parquet")
    df_raw = pd.read_parquet("holon-lab-trading/data/btc_5m_raw.parquet")
    ts = pd.to_datetime(df_raw["ts"])
    factory = TechnicalFeatureFactory()

    # Train gate on 2019-2020
    log("Training gate on 2019-2020...")
    df_seed = df_raw[ts <= "2020-12-31"].reset_index(drop=True)
    df_seed_ind = factory.compute_indicators(df_seed)
    labels = label_regimes(df_seed_ind, window=HolonGate.WINDOW)

    client = HolonClient(dimensions=HolonGate.DIM)
    gate = HolonGate(client)
    gate.train_regimes(df_seed_ind, labels, n_train=200)
    log(f"  Trained {len(gate.regime_subspaces)} regime subspaces")

    periods = [
        ("2021 (bull)", "2021-01-01", "2021-12-31"),
        ("2022 (bear)", "2022-01-01", "2022-12-31"),
        ("2023 (recovery)", "2023-01-01", "2023-12-31"),
        ("2024", "2024-01-01", "2024-12-31"),
    ]

    ts_labels = pd.to_datetime(df_labels["ts"])

    for period_name, start, end in periods:
        log(f"\n{'=' * 70}")
        log(f"PERIOD: {period_name}")
        log(f"{'=' * 70}")

        # Raw data for gate
        mask_raw = (ts >= start) & (ts <= end)
        df_period = df_raw[mask_raw].reset_index(drop=True)

        # Labels for this period
        mask_lbl = (ts_labels >= start) & (ts_labels <= end)
        df_lbl = df_labels[mask_lbl].reset_index(drop=True)

        if len(df_period) < 500:
            continue

        df_ind = factory.compute_indicators(df_period)
        close = df_ind["close"].values
        n = len(df_ind)
        scan_end = min(n, HolonGate.WINDOW + MAX_CANDLES)
        actions = df_lbl["action"].values[:scan_end]

        bah_start = float(close[HolonGate.WINDOW])
        bah_end = float(close[scan_end - 1])
        bah_pct = (bah_end / bah_start - 1) * 100

        # --- 1. ORACLE ---
        orc = oracle_return(close[:scan_end], actions, FEE_PCT)
        log(f"\n  ORACLE (perfect trades at every labeled reversal):")
        log(f"    Return: {orc['return_pct']:+.1f}% | B&H: {bah_pct:+.1f}% | Trades: {orc['n_trades']} | WR: {orc['win_rate']:.0f}% | Avg: {orc['avg_trade']:+.2f}%")

        # Count labels in scan range
        buy_labels = set(i for i in range(HolonGate.WINDOW, scan_end) if actions[i] == "BUY")
        sell_labels = set(i for i in range(HolonGate.WINDOW, scan_end) if actions[i] == "SELL")
        total_labels = len(buy_labels) + len(sell_labels)
        log(f"    Labeled reversals in scan range: {total_labels} ({len(buy_labels)}B / {len(sell_labels)}S)")

        # --- 2. GATE SIGNALS ---
        log(f"\n  Computing gate signals ({scan_end - HolonGate.WINDOW} candles)...")
        features = gate.precompute_features(df_ind)

        gate._tenure = 0
        gate._current_regime = Regime.UNKNOWN

        gate_fires = []  # (idx, direction, transition_type)
        t0 = time.time()
        for step in range(HolonGate.WINDOW, scan_end):
            signal = gate.check_fast(features, step, adaptive=True)
            if signal.fired and signal.transition_type:
                if signal.transition_type in BUY_TRANSITIONS:
                    gate_fires.append((step, "BUY", signal.transition_type))
                elif signal.transition_type in SELL_TRANSITIONS:
                    gate_fires.append((step, "SELL", signal.transition_type))
        elapsed = time.time() - t0

        buy_fires = [(idx, d) for idx, d, _ in gate_fires if d == "BUY"]
        sell_fires = [(idx, d) for idx, d, _ in gate_fires if d == "SELL"]
        log(f"    Gate fires: {len(gate_fires)} ({len(buy_fires)}B / {len(sell_fires)}S) in {elapsed:.0f}s")
        log(f"    Fire rate: {len(gate_fires) / max(1, scan_end - HolonGate.WINDOW) * 100:.1f}%")

        # --- 3. PRECISION & RECALL ---
        # For each gate fire, check if there's a same-direction label within ±PROXIMITY
        def label_set_for_direction(direction):
            return buy_labels if direction == "BUY" else sell_labels

        hits = 0
        for idx, direction, _ in gate_fires:
            labels_for_dir = label_set_for_direction(direction)
            if any(abs(idx - l) <= PROXIMITY for l in labels_for_dir):
                hits += 1

        precision = hits / len(gate_fires) * 100 if gate_fires else 0

        # For each label, check if there's a same-direction gate fire within ±PROXIMITY
        fire_indices_buy = set(idx for idx, d, _ in gate_fires if d == "BUY")
        fire_indices_sell = set(idx for idx, d, _ in gate_fires if d == "SELL")

        recalled_buys = sum(1 for l in buy_labels if any(abs(l - f) <= PROXIMITY for f in fire_indices_buy))
        recalled_sells = sum(1 for l in sell_labels if any(abs(l - f) <= PROXIMITY for f in fire_indices_sell))
        total_recalled = recalled_buys + recalled_sells
        recall = total_recalled / total_labels * 100 if total_labels else 0

        log(f"\n  PRECISION (gate fire near a real reversal, ±{PROXIMITY} candles):")
        log(f"    {hits}/{len(gate_fires)} = {precision:.1f}%")
        log(f"  RECALL (labeled reversals caught by gate, ±{PROXIMITY} candles):")
        log(f"    {total_recalled}/{total_labels} = {recall:.1f}% ({recalled_buys}B / {recalled_sells}S)")

        # --- 4. GATE-ONLY EQUITY ---
        gate_dirs_all = [(idx, d) for idx, d, _ in gate_fires]
        ge = gate_equity(close[:scan_end], gate_dirs_all, FEE_PCT)
        log(f"\n  GATE-ONLY EQUITY (trade every fire, no tree):")
        log(f"    Return: {ge['return_pct']:+.1f}% | Trades: {ge['n_trades']} | WR: {ge['win_rate']:.0f}% | Avg: {ge['avg_trade']:+.2f}%")

        # --- 5. SPACING ANALYSIS ---
        if gate_fires:
            fire_gaps = np.diff([idx for idx, _, _ in gate_fires])
            log(f"\n  FIRE SPACING:")
            log(f"    Median gap: {np.median(fire_gaps):.0f} candles ({np.median(fire_gaps) * 5 / 60:.1f}h)")
            log(f"    Min/Max gap: {fire_gaps.min()}-{fire_gaps.max()} candles")

        if total_labels:
            all_label_indices = sorted(list(buy_labels) + list(sell_labels))
            label_gaps = np.diff(all_label_indices)
            log(f"  LABEL SPACING:")
            log(f"    Median gap: {np.median(label_gaps):.0f} candles ({np.median(label_gaps) * 5 / 60:.1f}h)")
            log(f"    Min/Max gap: {label_gaps.min()}-{label_gaps.max()} candles")

    log(f"\n{'=' * 70}")
    log("DONE")
    log(f"{'=' * 70}")


if __name__ == "__main__":
    main()
