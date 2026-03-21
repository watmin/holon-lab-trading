"""Backtest seed engrams on held-out data with streaming log output.

Loads seed engrams (trained on 2019-2020), replays held-out data (2021+),
and makes magnitude-only trading decisions. Logs every trade and periodic
equity snapshots to a file for real-time monitoring.

Usage:
    ./scripts/run_with_venv.sh python holon-lab-trading/scripts/backtest_seeds.py
    # In another terminal:
    tail -f holon-lab-trading/data/backtest.log
"""

from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).parent.parent))

from trading.encoder import OHLCVEncoder
from trading.features import TechnicalFeatureFactory
from holon import HolonClient
from holon.memory import StripedSubspace, EngramLibrary

DIM = 1024
K = 4
N_STRIPES = OHLCVEncoder.N_STRIPES
WINDOW = OHLCVEncoder.WINDOW_CANDLES
FEE_RATE = 0.001


def log(f, msg: str):
    line = f"[{time.strftime('%H:%M:%S')}] {msg}"
    print(line, flush=True)
    f.write(line + "\n")
    f.flush()


def main():
    parser = argparse.ArgumentParser(description="Backtest seed engrams")
    parser.add_argument("--parquet", default="holon-lab-trading/data/btc_5m_raw.parquet")
    parser.add_argument("--engrams", default="holon-lab-trading/data/seed_engrams.json")
    parser.add_argument("--start-year", type=int, default=2021)
    parser.add_argument("--end-year", type=int, default=2021)
    parser.add_argument("--log-file", default="holon-lab-trading/data/backtest.log")
    parser.add_argument("--snapshot-interval", type=int, default=2000,
                        help="Log equity snapshot every N candles")
    args = parser.parse_args()

    logpath = Path(args.log_file)
    logpath.parent.mkdir(parents=True, exist_ok=True)

    with open(logpath, "w") as f:
        log(f, f"=== BACKTEST: seed engrams on {args.start_year}-{args.end_year} ===")

        # Load engrams
        library = EngramLibrary.load(args.engrams)
        engram_names = library.names(kind="striped")
        log(f, f"Loaded {len(engram_names)} engrams: {engram_names}")

        engrams = {}
        for name in engram_names:
            eng = library.get(name)
            action = eng.metadata.get("action", "HOLD")
            ss = eng.subspace
            engrams[name] = {"action": action, "subspace": ss}
            log(f, f"  {name}: action={action} n={ss.n} threshold={ss.threshold:.1f}")

        # Load data
        log(f, f"Loading {args.parquet}...")
        df = pd.read_parquet(args.parquet)
        ts = pd.to_datetime(df["ts"])

        mask = (ts >= f"{args.start_year}-01-01") & (ts <= f"{args.end_year}-12-31")
        df_test = df[mask].reset_index(drop=True)
        log(f, f"Test data: {len(df_test):,} candles "
              f"({df_test['ts'].iloc[0]} to {df_test['ts'].iloc[-1]})")

        # Compute indicators
        log(f, "Computing indicators...")
        factory = TechnicalFeatureFactory()
        df_ind = factory.compute_indicators(df_test)
        log(f, f"  {len(df_ind):,} rows ready ({len(df_test) - len(df_ind)} warmup dropped)")

        # Set up encoder
        client = HolonClient(dimensions=DIM)
        encoder = OHLCVEncoder(client)

        # Trading state
        balance = 10000.0
        btc = 0.0
        n_buy = 0
        n_sell = 0
        n_hold = 0
        trades = []
        equity_peak = 10000.0
        max_dd = 0.0

        log(f, f"\nStarting replay: {len(df_ind) - WINDOW:,} steps")
        log(f, "-" * 80)
        t0 = time.time()

        for step in range(WINDOW, len(df_ind)):
            start = step - WINDOW + 1
            w = df_ind.iloc[start:step + 1]
            if len(w) < WINDOW:
                n_hold += 1
                continue

            try:
                v = encoder.encode_from_precomputed(w)
            except Exception:
                n_hold += 1
                continue

            price = float(df_ind.iloc[step]["close"])
            candle_ts = df_ind.iloc[step].get("ts", "")

            # Magnitude-only: lowest residual wins
            best_action = "HOLD"
            best_residual = float("inf")
            residuals = {}
            for name, info in engrams.items():
                r = info["subspace"].residual(v)
                residuals[name] = r
                if r < best_residual:
                    best_residual = r
                    best_action = info["action"]

            # Execute position-aware trade
            executed = False
            if best_action == "BUY" and btc == 0:
                btc = (balance * (1 - FEE_RATE)) / price
                balance = 0.0
                n_buy += 1
                executed = True
                trades.append(("BUY", price, step, str(candle_ts)))
                r_str = "  ".join(f"{n}={r:.1f}" for n, r in residuals.items())
                log(f, f"BUY  ${price:>10,.0f}  step={step:>7,}  ts={candle_ts}  [{r_str}]")
            elif best_action == "SELL" and btc > 0:
                proceeds = btc * price * (1 - FEE_RATE)
                pnl_trade = proceeds - 10000 * (btc * price / (btc * price + balance) if balance == 0 else 0)
                balance = proceeds
                btc = 0.0
                n_sell += 1
                executed = True
                trades.append(("SELL", price, step, str(candle_ts)))

                # Compute round-trip PnL
                if len(trades) >= 2 and trades[-2][0] == "BUY":
                    buy_price = trades[-2][1]
                    rt_pnl = (price / buy_price - 1) * 100 - 0.2  # approx fees
                    win = "WIN" if rt_pnl > 0 else "LOSS"
                    r_str = "  ".join(f"{n}={r:.1f}" for n, r in residuals.items())
                    log(f, f"SELL ${price:>10,.0f}  step={step:>7,}  ts={candle_ts}  "
                          f"rt={rt_pnl:+.2f}% {win}  [{r_str}]")
                else:
                    r_str = "  ".join(f"{n}={r:.1f}" for n, r in residuals.items())
                    log(f, f"SELL ${price:>10,.0f}  step={step:>7,}  ts={candle_ts}  [{r_str}]")
            else:
                n_hold += 1

            # Equity tracking
            equity = balance + btc * price
            if equity > equity_peak:
                equity_peak = equity
            dd = (equity / equity_peak - 1) * 100
            if dd < max_dd:
                max_dd = dd

            # Periodic snapshot
            candles_done = step - WINDOW + 1
            if candles_done % args.snapshot_interval == 0:
                elapsed = time.time() - t0
                rate = candles_done / elapsed if elapsed > 0 else 0
                log(f, f"--- step {step:>7,} | equity ${equity:>10,.0f} | "
                      f"trades {n_buy}B/{n_sell}S/{n_hold}H | "
                      f"dd {max_dd:.1f}% | {rate:.0f} candles/s ---")

        # Final summary
        final_price = float(df_ind.iloc[-1]["close"])
        final_equity = balance + btc * final_price
        pnl_pct = (final_equity / 10000 - 1) * 100
        bah_start = float(df_ind.iloc[WINDOW]["close"])
        bah_pct = (final_price / bah_start - 1) * 100
        elapsed = time.time() - t0

        log(f, "")
        log(f, "=" * 80)
        log(f, f"BACKTEST COMPLETE — {elapsed:.0f}s")
        log(f, "=" * 80)
        log(f, f"Period:       {args.start_year}-{args.end_year}")
        log(f, f"Candles:      {len(df_ind) - WINDOW:,}")
        log(f, f"Final equity: ${final_equity:,.0f} ({pnl_pct:+.1f}%)")
        log(f, f"Buy & hold:   {bah_pct:+.1f}% (${bah_start:,.0f} -> ${final_price:,.0f})")
        log(f, f"Alpha:        {pnl_pct - bah_pct:+.1f}%")
        log(f, f"Trades:       {n_buy} buys, {n_sell} sells, {n_hold} holds")
        log(f, f"Max drawdown: {max_dd:.1f}%")

        # Win rate
        wins = 0
        losses = 0
        for i in range(len(trades) - 1):
            if trades[i][0] == "BUY" and trades[i + 1][0] == "SELL":
                if trades[i + 1][1] > trades[i][1] * (1 + 2 * FEE_RATE):
                    wins += 1
                else:
                    losses += 1
        total_rt = wins + losses
        if total_rt > 0:
            log(f, f"Win rate:     {wins}/{total_rt} = {wins / total_rt * 100:.0f}%")
        else:
            log(f, f"Win rate:     N/A (no round trips)")

        if btc > 0:
            log(f, f"NOTE: Still holding {btc:.6f} BTC at ${final_price:,.0f}")

        log(f, f"\nLog saved to {logpath}")


if __name__ == "__main__":
    main()
