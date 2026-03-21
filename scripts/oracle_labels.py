"""Retroactive oracle labeler — find what trades WOULD have been profitable.

For every candle, look forward and determine:
  - BUY opportunity: price rises by at least `min_move_pct` within `horizon` candles
    before dropping by `stop_pct` (i.e., you could have entered and exited profitably)
  - SELL opportunity: price drops by at least `min_move_pct` within `horizon` candles
    before rising by `stop_pct`

This gives us the theoretical ceiling: if we had perfect foresight, which
candles were actually worth trading?

Sweeps multiple min_move thresholds to show the tradeoff between selectivity
and opportunity count. Also computes the oracle equity curve for each.

Usage:
    ./scripts/run_with_venv.sh python holon-lab-trading/scripts/oracle_labels.py
"""

from __future__ import annotations

import sys
import time
from pathlib import Path

import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).parent.parent))

FEE_PER_SIDE = 0.025  # Jupiter/Solana
ROUND_TRIP_FEE = FEE_PER_SIDE * 2


def log(msg: str):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def find_profitable_entries(
    close: np.ndarray,
    min_move_pct: float,
    horizon: int,
    stop_pct: float | None = None,
) -> tuple[np.ndarray, np.ndarray]:
    """For each candle, determine if a profitable BUY or SELL exists in the forward window.

    Returns (buy_mask, sell_mask) boolean arrays.

    A BUY is profitable at index i if:
      max(close[i+1:i+horizon]) / close[i] - 1 >= min_move_pct/100

    A SELL is profitable at index i if:
      1 - min(close[i+1:i+horizon]) / close[i] >= min_move_pct/100

    If stop_pct is set, the favorable move must happen BEFORE the adverse move
    exceeds stop_pct (simulating a stop-loss).
    """
    n = len(close)
    buy_mask = np.zeros(n, dtype=bool)
    sell_mask = np.zeros(n, dtype=bool)

    for i in range(n - 1):
        end = min(i + 1 + horizon, n)
        window = close[i + 1 : end]
        if len(window) == 0:
            continue

        entry = close[i]

        # BUY check
        max_up = (window / entry - 1) * 100
        if stop_pct is not None:
            max_down = (1 - window / entry) * 100
            stop_hit = np.argmax(max_down >= stop_pct)
            if max_down[stop_hit] >= stop_pct:
                # Only look at candles before stop was hit
                max_up_before_stop = max_up[:stop_hit + 1]
                buy_mask[i] = np.any(max_up_before_stop >= min_move_pct)
            else:
                buy_mask[i] = np.any(max_up >= min_move_pct)
        else:
            buy_mask[i] = np.any(max_up >= min_move_pct)

        # SELL check
        max_down_sell = (1 - window / entry) * 100
        if stop_pct is not None:
            max_up_sell = (window / entry - 1) * 100
            stop_hit = np.argmax(max_up_sell >= stop_pct)
            if max_up_sell[stop_hit] >= stop_pct:
                max_down_before_stop = max_down_sell[:stop_hit + 1]
                sell_mask[i] = np.any(max_down_before_stop >= min_move_pct)
            else:
                sell_mask[i] = np.any(max_down_sell >= min_move_pct)
        else:
            sell_mask[i] = np.any(max_down_sell >= min_move_pct)

    return buy_mask, sell_mask


def oracle_equity(
    close: np.ndarray,
    buy_mask: np.ndarray,
    sell_mask: np.ndarray,
    min_move_pct: float,
    horizon: int,
    fee_pct: float,
) -> dict:
    """Simulate oracle trading: enter at every profitable label, exit at first
    moment the target profit is reached (or at horizon end).
    """
    n = len(close)
    equity = 10_000.0
    trades = []
    i = 0

    while i < n:
        if buy_mask[i]:
            entry = close[i]
            cost_in = equity * (fee_pct / 100)
            position = (equity - cost_in) / entry
            equity = 0.0

            # Find exit: first candle where target is hit, or end of horizon
            target = entry * (1 + min_move_pct / 100)
            exit_idx = i + 1
            for j in range(i + 1, min(i + 1 + horizon, n)):
                if close[j] >= target:
                    exit_idx = j
                    break
            else:
                exit_idx = min(i + horizon, n - 1)

            exit_price = close[exit_idx]
            proceeds = position * exit_price
            cost_out = proceeds * (fee_pct / 100)
            equity = proceeds - cost_out
            pnl = (exit_price / entry - 1) * 100
            trades.append({"pnl": pnl, "dir": "LONG", "hold": exit_idx - i})
            i = exit_idx + 1
            continue

        elif sell_mask[i]:
            entry = close[i]
            notional = equity
            cost_in = notional * (fee_pct / 100)
            equity -= cost_in

            target = entry * (1 - min_move_pct / 100)
            exit_idx = i + 1
            for j in range(i + 1, min(i + 1 + horizon, n)):
                if close[j] <= target:
                    exit_idx = j
                    break
            else:
                exit_idx = min(i + horizon, n - 1)

            exit_price = close[exit_idx]
            pnl = (entry / exit_price - 1) * 100
            equity *= (1 + pnl / 100)
            cost_out = equity * (fee_pct / 100)
            equity -= cost_out
            trades.append({"pnl": pnl, "dir": "SHORT", "hold": exit_idx - i})
            i = exit_idx + 1
            continue

        i += 1

    tdf = pd.DataFrame(trades) if trades else pd.DataFrame()
    final = equity
    ret = (final / 10_000 - 1) * 100

    long_trades = tdf[tdf["dir"] == "LONG"] if not tdf.empty else pd.DataFrame()
    short_trades = tdf[tdf["dir"] == "SHORT"] if not tdf.empty else pd.DataFrame()

    return {
        "return_pct": ret,
        "n_trades": len(trades),
        "n_long": len(long_trades),
        "n_short": len(short_trades),
        "win_rate": (tdf["pnl"] > 0).mean() * 100 if not tdf.empty else 0,
        "avg_trade": tdf["pnl"].mean() if not tdf.empty else 0,
        "avg_hold": tdf["hold"].mean() if not tdf.empty else 0,
        "long_wr": (long_trades["pnl"] > 0).mean() * 100 if not long_trades.empty else 0,
        "short_wr": (short_trades["pnl"] > 0).mean() * 100 if not short_trades.empty else 0,
    }


def main():
    log("Loading data...")
    df = pd.read_parquet("holon-lab-trading/data/btc_5m_raw.parquet")
    ts = pd.to_datetime(df["ts"])
    close_all = df["close"].values

    periods = [
        ("2021 (bull)", "2021-01-01", "2021-12-31"),
        ("2022 (bear)", "2022-01-01", "2022-12-31"),
        ("2023 (recovery)", "2023-01-01", "2023-12-31"),
        ("2024", "2024-01-01", "2024-12-31"),
    ]

    # Sweep parameters
    min_moves = [0.1, 0.2, 0.5, 1.0, 2.0, 5.0]
    horizons = [12, 36, 72]  # 1h, 3h, 6h in 5min candles

    for period_name, start, end in periods:
        mask = (ts >= start) & (ts <= end)
        close = close_all[mask]
        n = len(close)
        if n < 500:
            continue

        bah_pct = (close[-1] / close[0] - 1) * 100

        log(f"\n{'=' * 80}")
        log(f"PERIOD: {period_name}  ({n:,} candles, B&H: {bah_pct:+.1f}%)")
        log(f"{'=' * 80}")

        for horizon in horizons:
            horizon_h = horizon * 5 / 60
            log(f"\n  Horizon: {horizon} candles ({horizon_h:.0f}h)")
            log(f"  {'MinMove':>8s} | {'BuyOpp':>8s} | {'SellOpp':>8s} | {'OracleRet':>10s} | {'Trades':>7s} | {'L/S':>7s} | {'WR':>5s} | {'LWR':>5s} | {'SWR':>5s} | {'AvgPnL':>7s} | {'AvgHold':>8s}")
            log(f"  {'-'*8}-+-{'-'*8}-+-{'-'*8}-+-{'-'*10}-+-{'-'*7}-+-{'-'*7}-+-{'-'*5}-+-{'-'*5}-+-{'-'*5}-+-{'-'*7}-+-{'-'*8}")

            for mm in min_moves:
                t0 = time.time()
                buy_m, sell_m = find_profitable_entries(close, mm, horizon)
                n_buy = buy_m.sum()
                n_sell = sell_m.sum()

                orc = oracle_equity(close, buy_m, sell_m, mm, horizon, FEE_PER_SIDE)
                elapsed = time.time() - t0

                log(f"  {mm:7.1f}% | {n_buy:8d} | {n_sell:8d} | {orc['return_pct']:+9.1f}% | {orc['n_trades']:7d} | {orc['n_long']}/{orc['n_short']:<4d} | {orc['win_rate']:4.0f}% | {orc['long_wr']:4.0f}% | {orc['short_wr']:4.0f}% | {orc['avg_trade']:+6.2f}% | {orc['avg_hold']:7.1f}c")

    # Summary: best configs
    log(f"\n{'=' * 80}")
    log("ANALYSIS COMPLETE")
    log("Use the min_move / horizon combo that:")
    log("  1. Beats B&H in most periods")
    log("  2. Has enough opportunities (>50 per period) for the gate to target")
    log("  3. Has high win rate (oracle should be >60%)")
    log(f"{'=' * 80}")


if __name__ == "__main__":
    main()
