"""Oracle v2 — realistic ceiling + gate quality grading.

1. Labels every candle as a BUY/SELL opportunity if price moves min_move%
   within horizon candles (using future knowledge).
2. Computes realistic oracle returns using FIXED position sizing (10% of
   equity per trade) so returns don't blow up exponentially.
3. Grades the gate: of the opportunities the oracle identifies, how many
   does the gate fire near? (precision + recall)
4. Computes "gate-filtered oracle" — what if we only traded oracle
   opportunities that the gate also fires near?

Usage:
    ./scripts/run_with_venv.sh python holon-lab-trading/scripts/oracle_v2.py
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

FEE_PER_SIDE = 0.025
MAX_CANDLES = 10_000
POSITION_FRAC = 0.25  # risk 25% of equity per trade


def log(msg: str):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def find_opportunities(
    close: np.ndarray, min_move_pct: float, horizon: int,
) -> tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
    """Find BUY/SELL opportunities with future knowledge.

    Returns (buy_mask, sell_mask, buy_exit, sell_exit).
    *_exit arrays contain the index of the first candle hitting the target.
    """
    n = len(close)
    buy_mask = np.zeros(n, dtype=bool)
    sell_mask = np.zeros(n, dtype=bool)
    buy_exit = np.zeros(n, dtype=int)
    sell_exit = np.zeros(n, dtype=int)

    for i in range(n - 1):
        end = min(i + 1 + horizon, n)
        if end <= i + 1:
            continue
        entry = close[i]

        # BUY: find first candle where price >= entry * (1 + min_move/100)
        target_up = entry * (1 + min_move_pct / 100)
        for j in range(i + 1, end):
            if close[j] >= target_up:
                buy_mask[i] = True
                buy_exit[i] = j
                break

        # SELL: find first candle where price <= entry * (1 - min_move/100)
        target_down = entry * (1 - min_move_pct / 100)
        for j in range(i + 1, end):
            if close[j] <= target_down:
                sell_mask[i] = True
                sell_exit[i] = j
                break

    return buy_mask, sell_mask, buy_exit, sell_exit


def oracle_equity_fractional(
    close: np.ndarray,
    buy_mask: np.ndarray,
    sell_mask: np.ndarray,
    buy_exit: np.ndarray,
    sell_exit: np.ndarray,
    fee_pct: float,
    pos_frac: float,
) -> dict:
    """Oracle with fractional position sizing — risk pos_frac of equity per trade."""
    equity = 10_000.0
    trades = []
    in_trade_until = 0

    for i in range(len(close)):
        if i < in_trade_until:
            continue

        if buy_mask[i]:
            entry_price = close[i]
            exit_idx = buy_exit[i]
            exit_price = close[exit_idx]

            trade_equity = equity * pos_frac
            cost_in = trade_equity * (fee_pct / 100)
            shares = (trade_equity - cost_in) / entry_price
            proceeds = shares * exit_price
            cost_out = proceeds * (fee_pct / 100)
            net = proceeds - cost_out
            pnl = net - trade_equity
            equity += pnl
            trades.append({"pnl_pct": (exit_price / entry_price - 1) * 100, "dir": "LONG", "hold": exit_idx - i})
            in_trade_until = exit_idx + 1

        elif sell_mask[i]:
            entry_price = close[i]
            exit_idx = sell_exit[i]
            exit_price = close[exit_idx]

            trade_equity = equity * pos_frac
            cost_in = trade_equity * (fee_pct / 100)
            pnl_pct = (entry_price / exit_price - 1) * 100
            gross = trade_equity * (1 + pnl_pct / 100)
            cost_out = gross * (fee_pct / 100)
            net = gross - cost_out
            pnl = net - trade_equity
            equity += pnl
            trades.append({"pnl_pct": pnl_pct, "dir": "SHORT", "hold": exit_idx - i})
            in_trade_until = exit_idx + 1

    tdf = pd.DataFrame(trades) if trades else pd.DataFrame()
    ret = (equity / 10_000 - 1) * 100
    longs = tdf[tdf["dir"] == "LONG"] if not tdf.empty else pd.DataFrame()
    shorts = tdf[tdf["dir"] == "SHORT"] if not tdf.empty else pd.DataFrame()

    return {
        "return_pct": ret,
        "equity": equity,
        "n_trades": len(trades),
        "n_long": len(longs),
        "n_short": len(shorts),
        "win_rate": (tdf["pnl_pct"] > 0).mean() * 100 if not tdf.empty else 0,
        "avg_trade": tdf["pnl_pct"].mean() if not tdf.empty else 0,
        "avg_hold": tdf["hold"].mean() if not tdf.empty else 0,
    }


BUY_TRANSITIONS = {
    "TREND_DOWN → CONSOLIDATION", "TREND_DOWN → VOLATILE",
    "TREND_DOWN → TREND_UP", "VOLATILE → TREND_UP",
}
SELL_TRANSITIONS = {
    "TREND_UP → CONSOLIDATION", "TREND_UP → VOLATILE",
    "TREND_UP → TREND_DOWN", "VOLATILE → TREND_DOWN",
}


def main():
    log("Loading data...")
    df = pd.read_parquet("holon-lab-trading/data/btc_5m_raw.parquet")
    ts = pd.to_datetime(df["ts"])
    factory = TechnicalFeatureFactory()

    log("Training gate on 2019-2020...")
    df_seed = df[ts <= "2020-12-31"].reset_index(drop=True)
    df_seed_ind = factory.compute_indicators(df_seed)
    regime_labels = label_regimes(df_seed_ind, window=HolonGate.WINDOW)
    client = HolonClient(dimensions=HolonGate.DIM)
    gate = HolonGate(client)
    gate.train_regimes(df_seed_ind, regime_labels, n_train=200)
    log(f"  Trained {len(gate.regime_subspaces)} regime subspaces")

    periods = [
        ("2021 (bull)", "2021-01-01", "2021-12-31"),
        ("2022 (bear)", "2022-01-01", "2022-12-31"),
        ("2023 (recovery)", "2023-01-01", "2023-12-31"),
        ("2024", "2024-01-01", "2024-12-31"),
    ]

    PROXIMITY = 6
    min_moves = [0.2, 0.5, 1.0, 2.0]
    horizon = 36  # 3 hours

    for period_name, start, end in periods:
        mask = (ts >= start) & (ts <= end)
        df_period = df[mask].reset_index(drop=True)
        if len(df_period) < 500:
            continue

        df_ind = factory.compute_indicators(df_period)
        close = df_ind["close"].values
        n = len(df_ind)
        scan_end = min(n, HolonGate.WINDOW + MAX_CANDLES)

        bah_start = float(close[HolonGate.WINDOW])
        bah_end = float(close[scan_end - 1])
        bah_pct = (bah_end / bah_start - 1) * 100

        log(f"\n{'=' * 80}")
        log(f"PERIOD: {period_name}  (scan: {scan_end - HolonGate.WINDOW} candles, B&H: {bah_pct:+.1f}%)")
        log(f"{'=' * 80}")

        # Compute gate signals once
        log("  Computing gate signals...")
        features = gate.precompute_features(df_ind)
        gate._tenure = 0
        gate._current_regime = Regime.UNKNOWN

        gate_buy_indices = set()
        gate_sell_indices = set()
        t0 = time.time()
        for step in range(HolonGate.WINDOW, scan_end):
            signal = gate.check_fast(features, step, adaptive=True)
            if signal.fired and signal.transition_type:
                if signal.transition_type in BUY_TRANSITIONS:
                    gate_buy_indices.add(step)
                elif signal.transition_type in SELL_TRANSITIONS:
                    gate_sell_indices.add(step)
        gate_elapsed = time.time() - t0
        total_fires = len(gate_buy_indices) + len(gate_sell_indices)
        log(f"    {total_fires} fires ({len(gate_buy_indices)}B / {len(gate_sell_indices)}S) in {gate_elapsed:.0f}s")

        close_scan = close[:scan_end]

        for mm in min_moves:
            log(f"\n  --- MinMove: {mm}% / Horizon: {horizon} candles ({horizon * 5 / 60:.0f}h) ---")

            buy_m, sell_m, buy_x, sell_x = find_opportunities(close_scan, mm, horizon)

            # Only count opportunities in the scan range (after WINDOW)
            buy_m[:HolonGate.WINDOW] = False
            sell_m[:HolonGate.WINDOW] = False

            n_buy_opp = buy_m.sum()
            n_sell_opp = sell_m.sum()
            log(f"    Opportunities: {n_buy_opp + n_sell_opp} ({n_buy_opp}B / {n_sell_opp}S)")
            log(f"    Opp density: {(n_buy_opp + n_sell_opp) / max(1, scan_end - HolonGate.WINDOW) * 100:.1f}%")

            # Oracle (fractional sizing)
            buy_m_scan = buy_m.copy()
            sell_m_scan = sell_m.copy()
            orc = oracle_equity_fractional(close_scan, buy_m_scan, sell_m_scan, buy_x, sell_x, FEE_PER_SIDE, POSITION_FRAC)
            log(f"    Oracle ({POSITION_FRAC*100:.0f}% sizing): {orc['return_pct']:+.1f}% | {orc['n_trades']} trades ({orc['n_long']}L/{orc['n_short']}S) | WR: {orc['win_rate']:.0f}% | Avg: {orc['avg_trade']:+.2f}% | AvgHold: {orc['avg_hold']:.0f}c")

            # Gate precision/recall against opportunities
            buy_opp_indices = set(np.where(buy_m)[0])
            sell_opp_indices = set(np.where(sell_m)[0])

            # Precision: gate fires that are near an opportunity
            buy_hits = sum(1 for f in gate_buy_indices if any(abs(f - o) <= PROXIMITY for o in buy_opp_indices))
            sell_hits = sum(1 for f in gate_sell_indices if any(abs(f - o) <= PROXIMITY for o in sell_opp_indices))
            total_hits = buy_hits + sell_hits
            precision = total_hits / total_fires * 100 if total_fires else 0

            # Recall: opportunities that have a gate fire nearby
            buy_recalled = sum(1 for o in buy_opp_indices if any(abs(o - f) <= PROXIMITY for f in gate_buy_indices))
            sell_recalled = sum(1 for o in sell_opp_indices if any(abs(o - f) <= PROXIMITY for f in gate_sell_indices))
            total_recalled = buy_recalled + sell_recalled
            total_opps = n_buy_opp + n_sell_opp
            recall = total_recalled / total_opps * 100 if total_opps else 0

            log(f"    Gate precision: {total_hits}/{total_fires} = {precision:.1f}% (gate fires near an opportunity)")
            log(f"    Gate recall:    {total_recalled}/{total_opps} = {recall:.1f}% (opportunities caught by gate)")

            # Gate-filtered oracle: only trade opportunities that the gate also fires near
            gate_filtered_buy = np.zeros_like(buy_m)
            gate_filtered_sell = np.zeros_like(sell_m)

            for o in buy_opp_indices:
                if any(abs(o - f) <= PROXIMITY for f in gate_buy_indices):
                    gate_filtered_buy[o] = True

            for o in sell_opp_indices:
                if any(abs(o - f) <= PROXIMITY for f in gate_sell_indices):
                    gate_filtered_sell[o] = True

            n_gf_buy = gate_filtered_buy.sum()
            n_gf_sell = gate_filtered_sell.sum()

            if n_gf_buy + n_gf_sell > 0:
                gf_orc = oracle_equity_fractional(close_scan, gate_filtered_buy, gate_filtered_sell, buy_x, sell_x, FEE_PER_SIDE, POSITION_FRAC)
                log(f"    Gate-filtered oracle: {gf_orc['return_pct']:+.1f}% | {gf_orc['n_trades']} trades ({gf_orc['n_long']}L/{gf_orc['n_short']}S) | WR: {gf_orc['win_rate']:.0f}%")
            else:
                log(f"    Gate-filtered oracle: no trades (gate never fires near opportunities)")

    log(f"\n{'=' * 80}")
    log("DONE")
    log(f"{'=' * 80}")


if __name__ == "__main__":
    main()
