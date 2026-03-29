"""Backtest: adaptive gate + TA-confirmed rule tree.

Train regime subspaces on 2019-2020, then replay 2021-2024 with:
  - Adaptive gate (subspaces learn online, score first update second)
  - TA momentum confirmation (buy on RSI>50 + MACD>0, sell on RSI<50)
  - Jupiter fees (0.025% per side)
  - Bidirectional (long + short)

Usage:
    ./scripts/run_with_venv.sh python holon-lab-trading/scripts/backtest_rule_tree.py
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
from trading.rule_tree import RuleTree, TAContext, TradeAction

FEE_PER_SIDE = 0.025  # Jupiter/Solana, percent


def log(msg: str):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def build_ta(df_ind, idx: int) -> TAContext:
    """Extract TA context from indicators at a given index."""
    row = df_ind.iloc[idx]
    price = float(row["close"])
    bb_upper = float(row.get("bb_upper", price))
    bb_lower = float(row.get("bb_lower", price))
    bb_range = max(bb_upper - bb_lower, 1e-10)

    return TAContext(
        rsi=float(row.get("rsi", 50)),
        macd_hist=float(row.get("macd_hist_r", 0)),
        bb_pos=(price - bb_lower) / bb_range,
        adx=float(row.get("adx", 25)),
        vol_r=float(row.get("vol_r", 0)),
    )


def main():
    log("Loading data...")
    df = pd.read_parquet("holon-lab-trading/data/btc_5m_raw.parquet")
    ts = pd.to_datetime(df["ts"])
    factory = TechnicalFeatureFactory()

    log("Training gate on 2019-2020...")
    df_seed = df[ts <= "2020-12-31"].reset_index(drop=True)
    df_seed_ind = factory.compute_indicators(df_seed)
    labels = label_regimes(df_seed_ind, window=HolonGate.WINDOW)

    from holon import HolonClient
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

    tree = RuleTree(
        fee_per_side=FEE_PER_SIDE,
        cooldown_candles=6,
        max_trades_per_window=3,
        rate_window=48,
        streak_suppress=10,
        conviction_fires=2,
        conviction_window=6,
        min_tenure=3,
        max_drawdown=0.20,
        max_loss_streak=5,
        buy_rsi_min=50.0,
        buy_macd_positive=True,
        sell_rsi_max=50.0,
        ta_enabled=True,
    )

    MAX_CANDLES = 10_000  # cap per period for speed

    for name, start, end in periods:
        log(f"\n{'=' * 70}")
        log(f"PERIOD: {name}")
        log(f"{'=' * 70}")

        mask = (ts >= start) & (ts <= end)
        df_period = df[mask].reset_index(drop=True)
        if len(df_period) < 500:
            log(f"  Skipping — only {len(df_period)} rows")
            continue

        df_ind = factory.compute_indicators(df_period)
        features = gate.precompute_features(df_ind)
        close = df_ind["close"].values
        n = len(df_ind)
        scan_end = min(n, HolonGate.WINDOW + MAX_CANDLES)

        bah_start = float(close[HolonGate.WINDOW])
        bah_end = float(close[scan_end - 1])
        bah_pct = (bah_end / bah_start - 1) * 100

        log(f"  {scan_end - HolonGate.WINDOW:,} candles, ${bah_start:,.0f} → ${bah_end:,.0f}")
        log(f"  Buy & Hold: {bah_pct:+.1f}%")

        # Don't reset gate (learning accumulates), but reset tree state
        gate._tenure = 0
        gate._current_regime = Regime.UNKNOWN
        tree.reset()

        equity = 10_000.0
        position = 0.0
        entry_price = 0.0
        trades = []

        t0 = time.time()

        for step in range(HolonGate.WINDOW, scan_end):
            signal = gate.check_fast(features, step, adaptive=True)
            price = float(close[step])
            ta = build_ta(df_ind, step)

            total_equity = equity + max(0, position) * price
            if position < 0:
                total_equity = equity  # simplified short tracking

            result = tree.evaluate(
                signal, equity=total_equity, step=step, ta=ta,
            )

            if result.action == TradeAction.BUY and position == 0:
                cost = equity * (FEE_PER_SIDE / 100)
                position = (equity - cost) / price
                entry_price = price
                equity = 0.0

            elif result.action == TradeAction.SELL and position > 0:
                proceeds = position * price
                cost = proceeds * (FEE_PER_SIDE / 100)
                pnl_pct = (price / entry_price - 1) * 100
                equity = proceeds - cost
                position = 0.0
                tree.record_trade_result(pnl_pct - FEE_PER_SIDE * 2)
                trades.append({
                    "entry": entry_price, "exit": price,
                    "pnl_pct": pnl_pct, "direction": "LONG",
                    "transition": result.transition_type,
                    "rsi": ta.rsi, "macd": ta.macd_hist,
                })

            elif result.action == TradeAction.SELL and position == 0:
                entry_price = price
                position = -1.0
                equity -= equity * (FEE_PER_SIDE / 100)

            elif result.action == TradeAction.BUY and position < 0:
                pnl_pct = (entry_price / price - 1) * 100
                tree.record_trade_result(pnl_pct - FEE_PER_SIDE * 2)
                equity *= (1 + pnl_pct / 100)
                equity -= equity * (FEE_PER_SIDE / 100)
                position = 0.0
                trades.append({
                    "entry": entry_price, "exit": price,
                    "pnl_pct": pnl_pct, "direction": "SHORT",
                    "transition": result.transition_type,
                    "rsi": ta.rsi, "macd": ta.macd_hist,
                })

        # Final equity
        final_price = float(close[scan_end - 1])
        if position > 0:
            final_equity = position * final_price
        elif position < 0:
            pnl = (entry_price / final_price - 1) * 100
            final_equity = equity * (1 + pnl / 100)
        else:
            final_equity = equity

        total_return = (final_equity / 10_000 - 1) * 100
        elapsed = time.time() - t0

        log(f"\n  Results for {name}:")
        log(f"    Equity: $10,000 → ${final_equity:,.0f} ({total_return:+.1f}%)")
        log(f"    Buy & Hold: {bah_pct:+.1f}%")
        log(f"    Trades: {len(trades)}")
        log(f"    Time: {elapsed:.0f}s")

        if trades:
            tdf = pd.DataFrame(trades)
            wins = tdf[tdf["pnl_pct"] > 0]
            losses = tdf[tdf["pnl_pct"] <= 0]
            log(f"    Win rate: {len(wins)/len(tdf)*100:.0f}% "
                f"({len(wins)}W / {len(losses)}L)")
            if len(wins) > 0:
                log(f"    Avg win:  {wins['pnl_pct'].mean():+.2f}%")
            if len(losses) > 0:
                log(f"    Avg loss: {losses['pnl_pct'].mean():+.2f}%")

            for direction in ["LONG", "SHORT"]:
                dsub = tdf[tdf["direction"] == direction]
                if dsub.empty:
                    continue
                dwins = dsub[dsub["pnl_pct"] > 0]
                log(f"    {direction}: {len(dsub)} trades, "
                    f"wr={len(dwins)/len(dsub)*100:.0f}%, "
                    f"mean={dsub['pnl_pct'].mean():+.2f}%")

        # Diagnostics
        diag = tree.diagnostics()
        log(f"\n  Tree diagnostics:")
        log(f"    Actions: {diag['actions']}")
        for reason, count in sorted(diag["rejections"].items(), key=lambda x: -x[1]):
            if count > 0:
                log(f"    {reason}: {count:,}")

    log(f"\n{'=' * 70}")
    log("DONE")
    log(f"{'=' * 70}")


if __name__ == "__main__":
    main()
