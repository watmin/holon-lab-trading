"""Backtest using prototype scoring (negate-based algebraic signals).

Instead of subspace residual matching, this uses:
  1. Build per-class prototypes from seed data (2019-2020)
  2. Negate the HOLD prototype to isolate reversal-specific signal
  3. Score live windows by cosine similarity to the cleaned signal
  4. Trade when score exceeds threshold

Usage:
    ./scripts/run_with_venv.sh python holon-lab-trading/scripts/backtest_prototype.py
    # In another terminal:
    tail -f holon-lab-trading/data/backtest_proto.log
"""

from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

import numpy as np
import pandas as pd
from scipy.signal import find_peaks

sys.path.insert(0, str(Path(__file__).parent.parent))

from trading.encoder import OHLCVEncoder
from trading.features import TechnicalFeatureFactory
from holon import HolonClient
from holon.kernel.primitives import prototype, negate

DIM = 1024
N_STRIPES = OHLCVEncoder.N_STRIPES
WINDOW = OHLCVEncoder.WINDOW_CANDLES
FEE_RATE = 0.001


def log(f, msg: str):
    line = f"[{time.strftime('%H:%M:%S')}] {msg}"
    print(line, flush=True)
    f.write(line + "\n")
    f.flush()


def cos(a, b):
    na = np.linalg.norm(a)
    nb = np.linalg.norm(b)
    if na < 1e-9 or nb < 1e-9:
        return 0.0
    return float(np.dot(a.astype(float), b.astype(float)) / (na * nb))


def main():
    parser = argparse.ArgumentParser(description="Backtest prototype scoring")
    parser.add_argument("--parquet", default="holon-lab-trading/data/btc_5m_raw.parquet")
    parser.add_argument("--start-year", type=int, default=2021)
    parser.add_argument("--end-year", type=int, default=2021)
    parser.add_argument("--threshold", type=float, default=0.15,
                        help="Prototype score threshold to act")
    parser.add_argument("--seed-end", type=str, default="2020-12-31",
                        help="End of seed period for prototype training")
    parser.add_argument("--max-train", type=int, default=300,
                        help="Max samples per class for prototype")
    parser.add_argument("--log-file", default="holon-lab-trading/data/backtest_proto.log")
    parser.add_argument("--snapshot-interval", type=int, default=2000)
    parser.add_argument("--prominence-pct", type=float, default=0.02)
    args = parser.parse_args()

    logpath = Path(args.log_file)
    logpath.parent.mkdir(parents=True, exist_ok=True)

    with open(logpath, "w") as f:
        log(f, f"=== BACKTEST: prototype scoring on {args.start_year}-{args.end_year} ===")
        log(f, f"  threshold={args.threshold}  max_train={args.max_train}  "
              f"prominence={args.prominence_pct}")

        # Load full dataset
        log(f, "Loading data...")
        df = pd.read_parquet(args.parquet)
        ts = pd.to_datetime(df["ts"])

        # ---- PHASE 1: Build prototypes from seed period ----
        log(f, f"Building prototypes from data up to {args.seed_end}...")
        seed_mask = ts <= args.seed_end
        df_seed = df[seed_mask].reset_index(drop=True)
        log(f, f"  Seed data: {len(df_seed):,} candles")

        close = df_seed["close"].values
        prominence = float(np.median(close)) * args.prominence_pct

        peaks, _ = find_peaks(close, prominence=prominence, distance=12)
        troughs, _ = find_peaks(-close, prominence=prominence, distance=12)
        log(f, f"  Raw labels: {len(troughs)} BUY, {len(peaks)} SELL")

        factory = TechnicalFeatureFactory()
        df_seed_ind = factory.compute_indicators(df_seed)
        n_dropped = len(df_seed) - len(df_seed_ind)
        log(f, f"  Indicators: {len(df_seed_ind):,} rows ({n_dropped} warmup dropped)")

        peaks_ind = peaks - n_dropped
        troughs_ind = troughs - n_dropped
        peaks_ind = peaks_ind[(peaks_ind >= WINDOW) & (peaks_ind < len(df_seed_ind))]
        troughs_ind = troughs_ind[(troughs_ind >= WINDOW) & (troughs_ind < len(df_seed_ind))]

        client = HolonClient(dimensions=DIM)
        encoder = OHLCVEncoder(client, n_stripes=N_STRIPES)
        rng = np.random.default_rng(42)

        # Encode seed windows
        def encode_at(indices, max_n):
            vecs = []
            for idx in indices[:max_n + 50]:
                start = int(idx) - WINDOW + 1
                if start < 0 or int(idx) >= len(df_seed_ind):
                    continue
                w = df_seed_ind.iloc[start:int(idx) + 1]
                if len(w) < WINDOW:
                    continue
                try:
                    v = encoder.encode_from_precomputed(w)
                    vecs.append(v)
                except Exception:
                    continue
                if len(vecs) >= max_n:
                    break
            return vecs

        buy_vecs = encode_at(troughs_ind, args.max_train)
        sell_vecs = encode_at(peaks_ind, args.max_train)

        rev_set = set(troughs_ind.tolist()) | set(peaks_ind.tolist())
        hold_pool = [i for i in range(WINDOW, len(df_seed_ind)) if i not in rev_set]
        hold_sample = rng.choice(hold_pool, size=min(args.max_train, len(hold_pool)),
                                 replace=False)
        hold_vecs = encode_at(hold_sample, args.max_train)

        log(f, f"  Encoded: {len(buy_vecs)} BUY, {len(sell_vecs)} SELL, {len(hold_vecs)} HOLD")

        # Build per-stripe prototypes
        buy_protos = []
        sell_protos = []
        hold_protos = []
        for s in range(N_STRIPES):
            buy_protos.append(prototype([v[s] for v in buy_vecs]))
            sell_protos.append(prototype([v[s] for v in sell_vecs]))
            hold_protos.append(prototype([v[s] for v in hold_vecs]))

        # Negate hold from buy/sell
        buy_signal = [negate(buy_protos[s], hold_protos[s]) for s in range(N_STRIPES)]
        sell_signal = [negate(sell_protos[s], hold_protos[s]) for s in range(N_STRIPES)]

        # Signal diagnostics
        buy_density = np.mean([np.count_nonzero(buy_signal[s]) / DIM
                               for s in range(N_STRIPES)])
        sell_density = np.mean([np.count_nonzero(sell_signal[s]) / DIM
                                for s in range(N_STRIPES)])
        log(f, f"  Signal density: BUY={buy_density:.1%}  SELL={sell_density:.1%}")

        # Validate on seed data
        buy_scores = [np.mean([cos(v[s], buy_signal[s]) for s in range(N_STRIPES)])
                      for v in buy_vecs[-50:]]
        sell_scores = [np.mean([cos(v[s], sell_signal[s]) for s in range(N_STRIPES)])
                       for v in sell_vecs[-50:]]
        hold_buy_scores = [np.mean([cos(v[s], buy_signal[s]) for s in range(N_STRIPES)])
                           for v in hold_vecs[-50:]]
        log(f, f"  Seed validation:")
        log(f, f"    BUY windows → buy_signal:  {np.mean(buy_scores):+.4f} "
              f"(min={np.min(buy_scores):+.4f}, max={np.max(buy_scores):+.4f})")
        log(f, f"    SELL windows → sell_signal: {np.mean(sell_scores):+.4f} "
              f"(min={np.min(sell_scores):+.4f}, max={np.max(sell_scores):+.4f})")
        log(f, f"    HOLD windows → buy_signal:  {np.mean(hold_buy_scores):+.4f}")

        # ---- PHASE 2: Backtest on held-out data ----
        test_mask = (ts >= f"{args.start_year}-01-01") & (ts <= f"{args.end_year}-12-31")
        df_test = df[test_mask].reset_index(drop=True)
        df_test_ind = factory.compute_indicators(df_test)
        log(f, f"\nTest data: {len(df_test_ind):,} candles "
              f"({args.start_year}-{args.end_year})")

        balance = 10000.0
        btc = 0.0
        n_buy = 0
        n_sell = 0
        n_hold = 0
        trades = []
        equity_peak = 10000.0
        max_dd = 0.0
        entry_price = 0.0

        log(f, f"\nStarting replay: threshold={args.threshold}")
        log(f, "-" * 80)
        t0 = time.time()

        for step in range(WINDOW, len(df_test_ind)):
            start = step - WINDOW + 1
            w = df_test_ind.iloc[start:step + 1]
            if len(w) < WINDOW:
                n_hold += 1
                continue

            try:
                v = encoder.encode_from_precomputed(w)
            except Exception:
                n_hold += 1
                continue

            price = float(df_test_ind.iloc[step]["close"])
            candle_ts = df_test_ind.iloc[step].get("ts", "")

            # Score against both signals
            buy_score = np.mean([cos(v[s], buy_signal[s]) for s in range(N_STRIPES)])
            sell_score = np.mean([cos(v[s], sell_signal[s]) for s in range(N_STRIPES)])

            action = "HOLD"
            if buy_score > sell_score and buy_score > args.threshold:
                action = "BUY"
            elif sell_score > buy_score and sell_score > args.threshold:
                action = "SELL"

            # Execute position-aware trade
            if action == "BUY" and btc == 0:
                btc = (balance * (1 - FEE_RATE)) / price
                entry_price = price
                balance = 0.0
                n_buy += 1
                trades.append(("BUY", price, step, str(candle_ts)))
                log(f, f"BUY  ${price:>10,.0f}  step={step:>7,}  ts={candle_ts}  "
                      f"buy={buy_score:+.4f} sell={sell_score:+.4f}")
            elif action == "SELL" and btc > 0:
                proceeds = btc * price * (1 - FEE_RATE)
                rt_pnl = (price / entry_price - 1) * 100 - 0.2
                win = "WIN" if rt_pnl > 0 else "LOSS"
                balance = proceeds
                btc = 0.0
                n_sell += 1
                trades.append(("SELL", price, step, str(candle_ts)))
                log(f, f"SELL ${price:>10,.0f}  step={step:>7,}  ts={candle_ts}  "
                      f"rt={rt_pnl:+.2f}% {win}  buy={buy_score:+.4f} sell={sell_score:+.4f}")
            else:
                n_hold += 1

            # Equity tracking
            equity = balance + btc * price
            if equity > equity_peak:
                equity_peak = equity
            dd = (equity / equity_peak - 1) * 100
            if dd < max_dd:
                max_dd = dd

            candles_done = step - WINDOW + 1
            if candles_done % args.snapshot_interval == 0:
                elapsed = time.time() - t0
                rate = candles_done / elapsed if elapsed > 0 else 0
                log(f, f"--- step {step:>7,} | equity ${equity:>10,.0f} | "
                      f"trades {n_buy}B/{n_sell}S/{n_hold}H | "
                      f"dd {max_dd:.1f}% | {rate:.0f} candles/s ---")

        # Final summary
        final_price = float(df_test_ind.iloc[-1]["close"])
        final_equity = balance + btc * final_price
        pnl_pct = (final_equity / 10000 - 1) * 100
        bah_start = float(df_test_ind.iloc[WINDOW]["close"])
        bah_pct = (final_price / bah_start - 1) * 100
        elapsed = time.time() - t0

        log(f, "")
        log(f, "=" * 80)
        log(f, f"BACKTEST COMPLETE — {elapsed:.0f}s")
        log(f, "=" * 80)
        log(f, f"Period:       {args.start_year}-{args.end_year}")
        log(f, f"Candles:      {len(df_test_ind) - WINDOW:,}")
        log(f, f"Final equity: ${final_equity:,.0f} ({pnl_pct:+.1f}%)")
        log(f, f"Buy & hold:   {bah_pct:+.1f}% (${bah_start:,.0f} -> ${final_price:,.0f})")
        log(f, f"Alpha:        {pnl_pct - bah_pct:+.1f}%")
        log(f, f"Trades:       {n_buy} buys, {n_sell} sells, {n_hold} holds")
        if n_buy > 0:
            log(f, f"Trade freq:   1 trade per ~{(len(df_test_ind) - WINDOW) // max(n_buy, 1)} candles")
        log(f, f"Max drawdown: {max_dd:.1f}%")

        wins = 0
        losses = 0
        win_pnls = []
        loss_pnls = []
        for i in range(len(trades) - 1):
            if trades[i][0] == "BUY" and trades[i + 1][0] == "SELL":
                pnl = (trades[i + 1][1] / trades[i][1] - 1) * 100 - 0.2
                if pnl > 0:
                    wins += 1
                    win_pnls.append(pnl)
                else:
                    losses += 1
                    loss_pnls.append(pnl)
        total_rt = wins + losses
        if total_rt > 0:
            log(f, f"Win rate:     {wins}/{total_rt} = {wins / total_rt * 100:.0f}%")
            avg_win = np.mean(win_pnls) if win_pnls else 0
            avg_loss = np.mean(loss_pnls) if loss_pnls else 0
            log(f, f"Avg win:      {avg_win:+.2f}%")
            log(f, f"Avg loss:     {avg_loss:+.2f}%")
            if avg_loss != 0:
                log(f, f"Win/Loss:     {abs(avg_win / avg_loss):.2f}")
            log(f, f"Expectancy:   {(wins * avg_win + losses * avg_loss) / total_rt:+.2f}% per trade")
        else:
            log(f, f"Win rate:     N/A (no round trips)")

        if btc > 0:
            log(f, f"NOTE: Still holding {btc:.6f} BTC at ${final_price:,.0f}")

        log(f, f"\nLog saved to {logpath}")


if __name__ == "__main__":
    main()
