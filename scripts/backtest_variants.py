"""Compare three strategy variants side by side.

A) Long-only (no shorts)
B) Bear-regime shorts only (SHORT only when entering TREND_DOWN or VOLATILE)
C) Asymmetric thresholds (BUY RSI>60, SELL RSI<30)

All use adaptive gate + TA confirmation, 10k candles/period.

Usage:
    ./scripts/run_with_venv.sh python holon-lab-trading/scripts/backtest_variants.py
"""

from __future__ import annotations

import copy
import sys
import time
from pathlib import Path

import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).parent.parent))

from trading.features import TechnicalFeatureFactory
from trading.gate import HolonGate, Regime, label_regimes
from trading.rule_tree import RuleTree, TAContext, TradeAction

from holon import HolonClient

FEE_PER_SIDE = 0.025
MAX_CANDLES = 10_000

# Regimes where shorting makes sense
BEAR_REGIMES = {Regime.TREND_DOWN, Regime.VOLATILE}


def log(msg: str):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def build_ta(df_ind, idx: int) -> TAContext:
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


def run_backtest(gate, tree, df_ind, features, close, scan_end, variant, allow_short_fn=None):
    """Run a single backtest variant. Returns results dict."""
    gate._tenure = 0
    gate._current_regime = Regime.UNKNOWN
    tree.reset()

    equity = 10_000.0
    position = 0.0
    entry_price = 0.0
    trades = []

    for step in range(HolonGate.WINDOW, scan_end):
        signal = gate.check_fast(features, step, adaptive=True)
        price = float(close[step])
        ta = build_ta(df_ind, step)

        total_equity = equity + max(0, position) * price
        if position < 0:
            total_equity = equity

        result = tree.evaluate(signal, equity=total_equity, step=step, ta=ta)
        action = result.action

        # Variant-specific: suppress shorts that don't pass the filter
        if action == TradeAction.SELL and position <= 0 and allow_short_fn is not None:
            if not allow_short_fn(signal):
                action = TradeAction.HOLD

        if action == TradeAction.BUY and position == 0:
            cost = equity * (FEE_PER_SIDE / 100)
            position = (equity - cost) / price
            entry_price = price
            equity = 0.0

        elif action == TradeAction.SELL and position > 0:
            proceeds = position * price
            cost = proceeds * (FEE_PER_SIDE / 100)
            pnl_pct = (price / entry_price - 1) * 100
            equity = proceeds - cost
            position = 0.0
            tree.record_trade_result(pnl_pct - FEE_PER_SIDE * 2)
            trades.append({"pnl_pct": pnl_pct, "direction": "LONG"})

        elif action == TradeAction.SELL and position == 0:
            entry_price = price
            position = -1.0
            equity -= equity * (FEE_PER_SIDE / 100)

        elif action == TradeAction.BUY and position < 0:
            pnl_pct = (entry_price / price - 1) * 100
            tree.record_trade_result(pnl_pct - FEE_PER_SIDE * 2)
            equity *= (1 + pnl_pct / 100)
            equity -= equity * (FEE_PER_SIDE / 100)
            position = 0.0
            trades.append({"pnl_pct": pnl_pct, "direction": "SHORT"})

    # Close out
    final_price = float(close[scan_end - 1])
    if position > 0:
        final_equity = position * final_price
    elif position < 0:
        pnl = (entry_price / final_price - 1) * 100
        final_equity = equity * (1 + pnl / 100)
    else:
        final_equity = equity

    total_return = (final_equity / 10_000 - 1) * 100
    tdf = pd.DataFrame(trades) if trades else pd.DataFrame()

    long_trades = tdf[tdf["direction"] == "LONG"] if not tdf.empty else pd.DataFrame()
    short_trades = tdf[tdf["direction"] == "SHORT"] if not tdf.empty else pd.DataFrame()

    return {
        "variant": variant,
        "final_equity": final_equity,
        "return_pct": total_return,
        "n_trades": len(trades),
        "n_long": len(long_trades),
        "n_short": len(short_trades),
        "win_rate": (tdf["pnl_pct"] > 0).mean() * 100 if not tdf.empty else 0,
        "long_wr": (long_trades["pnl_pct"] > 0).mean() * 100 if not long_trades.empty else 0,
        "short_wr": (short_trades["pnl_pct"] > 0).mean() * 100 if not short_trades.empty else 0,
        "avg_win": tdf[tdf["pnl_pct"] > 0]["pnl_pct"].mean() if not tdf.empty and (tdf["pnl_pct"] > 0).any() else 0,
        "avg_loss": tdf[tdf["pnl_pct"] <= 0]["pnl_pct"].mean() if not tdf.empty and (tdf["pnl_pct"] <= 0).any() else 0,
    }


def main():
    log("Loading data...")
    df = pd.read_parquet("holon-lab-trading/data/btc_5m_raw.parquet")
    ts = pd.to_datetime(df["ts"])
    factory = TechnicalFeatureFactory()

    log("Training gate on 2019-2020...")
    df_seed = df[ts <= "2020-12-31"].reset_index(drop=True)
    df_seed_ind = factory.compute_indicators(df_seed)
    labels = label_regimes(df_seed_ind, window=HolonGate.WINDOW)

    def make_gate():
        client = HolonClient(dimensions=HolonGate.DIM)
        g = HolonGate(client)
        g.train_regimes(df_seed_ind, labels, n_train=200)
        return g

    gate_a = make_gate()
    gate_b = make_gate()
    gate_c = make_gate()
    log(f"  Trained 3 independent gates ({len(gate_a.regime_subspaces)} regime subspaces each)")

    common_tree_kw = dict(
        fee_per_side=FEE_PER_SIDE, cooldown_candles=6, max_trades_per_window=3,
        rate_window=48, streak_suppress=10, conviction_fires=2, conviction_window=6,
        min_tenure=3,
    )
    tree_a = RuleTree(**common_tree_kw, buy_rsi_min=50.0, buy_macd_positive=True, sell_rsi_max=50.0)
    tree_b = RuleTree(**common_tree_kw, buy_rsi_min=50.0, buy_macd_positive=True, sell_rsi_max=50.0)
    tree_c = RuleTree(**common_tree_kw, buy_rsi_min=60.0, buy_macd_positive=True, sell_rsi_max=30.0)

    periods = [
        ("2021 (bull)", "2021-01-01", "2021-12-31"),
        ("2022 (bear)", "2022-01-01", "2022-12-31"),
        ("2023 (recovery)", "2023-01-01", "2023-12-31"),
        ("2024", "2024-01-01", "2024-12-31"),
    ]

    all_results = []

    for period_name, start, end in periods:
        log(f"\n{'=' * 70}")
        log(f"PERIOD: {period_name}")
        log(f"{'=' * 70}")

        mask = (ts >= start) & (ts <= end)
        df_period = df[mask].reset_index(drop=True)
        if len(df_period) < 500:
            continue

        df_ind = factory.compute_indicators(df_period)
        features = gate_a.precompute_features(df_ind)
        close = df_ind["close"].values
        n = len(df_ind)
        scan_end = min(n, HolonGate.WINDOW + MAX_CANDLES)

        bah_start = float(close[HolonGate.WINDOW])
        bah_end = float(close[scan_end - 1])
        bah_pct = (bah_end / bah_start - 1) * 100
        log(f"  Buy & Hold: {bah_pct:+.1f}%")

        t0 = time.time()

        # A) Long-only — same TA thresholds but shorts suppressed
        r_a = run_backtest(
            gate_a, tree_a, df_ind, features, close, scan_end,
            variant="A) Long-only",
            allow_short_fn=lambda s: False,
        )

        # B) Bear-regime shorts — only SHORT when entering TREND_DOWN or VOLATILE
        r_b = run_backtest(
            gate_b, tree_b, df_ind, features, close, scan_end,
            variant="B) Bear-shorts",
            allow_short_fn=lambda s: s.current_regime in BEAR_REGIMES,
        )

        # C) Asymmetric thresholds — tighter BUY (RSI>60), extreme SELL (RSI<30)
        r_c = run_backtest(
            gate_c, tree_c, df_ind, features, close, scan_end,
            variant="C) Asymmetric",
            allow_short_fn=None,
        )

        elapsed = time.time() - t0

        r_a["period"] = period_name
        r_a["bah"] = bah_pct
        r_b["period"] = period_name
        r_b["bah"] = bah_pct
        r_c["period"] = period_name
        r_c["bah"] = bah_pct
        all_results.extend([r_a, r_b, r_c])

        log(f"\n  {'Variant':20s} | {'Return':>8s} | {'B&H':>6s} | {'Trades':>6s} | {'L/S':>5s} | {'WR':>5s} | {'LWR':>5s} | {'SWR':>5s} | {'AvgW':>7s} | {'AvgL':>7s}")
        log(f"  {'-'*20}-+-{'-'*8}-+-{'-'*6}-+-{'-'*6}-+-{'-'*5}-+-{'-'*5}-+-{'-'*5}-+-{'-'*5}-+-{'-'*7}-+-{'-'*7}")
        for r in [r_a, r_b, r_c]:
            log(f"  {r['variant']:20s} | {r['return_pct']:+7.1f}% | {bah_pct:+5.1f}% | {r['n_trades']:6d} | {r['n_long']}/{r['n_short']:d} | {r['win_rate']:4.0f}% | {r['long_wr']:4.0f}% | {r['short_wr']:4.0f}% | {r['avg_win']:+6.2f}% | {r['avg_loss']:+6.2f}%")

        log(f"  ({elapsed:.0f}s)")

    # Summary table
    log(f"\n{'=' * 70}")
    log("SUMMARY ACROSS ALL PERIODS")
    log(f"{'=' * 70}")

    rdf = pd.DataFrame(all_results)
    for variant in ["A) Long-only", "B) Bear-shorts", "C) Asymmetric"]:
        sub = rdf[rdf["variant"] == variant]
        total_return = 1.0
        for _, row in sub.iterrows():
            total_return *= (1 + row["return_pct"] / 100)
        compound = (total_return - 1) * 100
        total_trades = sub["n_trades"].sum()
        total_long = sub["n_long"].sum()
        total_short = sub["n_short"].sum()
        log(f"\n  {variant}:")
        log(f"    Compound return: {compound:+.1f}%")
        log(f"    Total trades: {total_trades} ({total_long}L / {total_short}S)")
        for _, row in sub.iterrows():
            log(f"      {row['period']:20s}: {row['return_pct']:+.1f}% (B&H {row['bah']:+.1f}%)")

    # Buy & Hold compound
    bah_compound = 1.0
    for _, row in rdf[rdf["variant"] == "A) Long-only"].iterrows():
        bah_compound *= (1 + row["bah"] / 100)
    log(f"\n  Buy & Hold compound: {(bah_compound - 1) * 100:+.1f}%")

    log(f"\n{'=' * 70}")
    log("DONE")
    log(f"{'=' * 70}")


if __name__ == "__main__":
    main()
