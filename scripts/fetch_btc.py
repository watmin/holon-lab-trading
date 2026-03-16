"""Fetch historical BTC/USDT 5m OHLCV data from OKX and save to parquet.

Checkpoints to disk every CHECKPOINT_BATCHES batches so a failed run
can be resumed from where it left off. Re-running this script is safe —
it reads the existing file to find the last timestamp and continues from there.

Usage:
    ./scripts/run_with_venv.sh python scripts/fetch_btc.py
    ./scripts/run_with_venv.sh python scripts/fetch_btc.py --from 2019-01-01 --to 2025-03-15
    ./scripts/run_with_venv.sh python scripts/fetch_btc.py --refresh   # ignore existing, refetch all
"""

from __future__ import annotations

import argparse
import time
from pathlib import Path

import ccxt
import pandas as pd

OUTPUT = "holon-lab-trading/data/btc_5m_raw.parquet"
SYMBOL = "BTC/USDT"
TIMEFRAME = "5m"
CANDLE_MS = 5 * 60 * 1000          # milliseconds per candle
BATCH_SIZE = 300                    # OKX limit
CHECKPOINT_BATCHES = 100            # write to disk every ~30k candles
RATE_DELAY = 0.25                   # seconds between requests


def load_existing(path: str) -> tuple[pd.DataFrame, int | None]:
    """Load existing parquet and return (df, last_ts_ms) or (empty_df, None)."""
    p = Path(path)
    if p.exists():
        df = pd.read_parquet(path)
        if len(df) > 0:
            last_ts = int(df["ts"].iloc[-1].timestamp() * 1000)
            print(f"  Resuming from existing {len(df):,} rows, last ts: {df['ts'].iloc[-1]}")
            return df, last_ts
    return pd.DataFrame(columns=["ts", "open", "high", "low", "close", "volume"]), None


def save(df: pd.DataFrame, path: str) -> None:
    """Atomic write: write to .tmp then rename."""
    tmp = path + ".tmp"
    df.to_parquet(tmp, index=False)
    Path(tmp).rename(path)


def fetch(args: argparse.Namespace) -> None:
    ex = ccxt.okx()

    end_ms = ex.parse8601(f"{args.to}T23:59:59Z")

    # Load existing data or start fresh
    if args.refresh:
        existing_df = pd.DataFrame(columns=["ts", "open", "high", "low", "close", "volume"])
        since = ex.parse8601(f"{args.from_date}T00:00:00Z")
    else:
        existing_df, last_ts = load_existing(args.output)
        if last_ts is not None:
            since = last_ts + CANDLE_MS
        else:
            since = ex.parse8601(f"{args.from_date}T00:00:00Z")

    start_ms = ex.parse8601(f"{args.from_date}T00:00:00Z")
    total_ms = end_ms - start_ms

    new_rows: list[list] = []
    batch_num = 0
    last_checkpoint_n = len(existing_df)

    print(f"Fetching {SYMBOL} {TIMEFRAME} from OKX")
    print(f"  from: {args.from_date}  to: {args.to}")
    print(f"  output: {args.output}")
    print(f"  checkpoint every {CHECKPOINT_BATCHES} batches (~{CHECKPOINT_BATCHES * BATCH_SIZE:,} candles)")

    while since < end_ms:
        try:
            batch = ex.fetch_ohlcv(SYMBOL, TIMEFRAME, since=since, limit=BATCH_SIZE)
        except Exception as e:
            print(f"\n  error: {e} — retrying in 5s")
            time.sleep(5)
            continue

        if not batch:
            break

        batch = [c for c in batch if c[0] <= end_ms]
        if not batch:
            break

        new_rows.extend(batch)
        since = batch[-1][0] + CANDLE_MS
        batch_num += 1

        # Progress
        pct = min(100.0, (since - start_ms) / total_ms * 100)
        total_so_far = len(existing_df) + len(new_rows)
        print(f"  {pd.to_datetime(since, unit='ms').strftime('%Y-%m-%d')}  "
              f"n={total_so_far:>8,}  {pct:5.1f}%", end="\r")

        # Checkpoint
        if batch_num % CHECKPOINT_BATCHES == 0 and new_rows:
            df_new = pd.DataFrame(new_rows, columns=["ts", "open", "high", "low", "close", "volume"])
            df_new["ts"] = pd.to_datetime(df_new["ts"], unit="ms")
            combined = pd.concat([existing_df, df_new], ignore_index=True)
            combined = combined.drop_duplicates("ts").sort_values("ts").reset_index(drop=True)
            save(combined, args.output)
            existing_df = combined
            new_rows = []
            n_added = len(existing_df) - last_checkpoint_n
            last_checkpoint_n = len(existing_df)
            print(f"\n  checkpoint: {len(existing_df):,} rows saved (+{n_added:,})")

        time.sleep(RATE_DELAY)

    # Final save
    print()
    if new_rows:
        df_new = pd.DataFrame(new_rows, columns=["ts", "open", "high", "low", "close", "volume"])
        df_new["ts"] = pd.to_datetime(df_new["ts"], unit="ms")
        combined = pd.concat([existing_df, df_new], ignore_index=True)
        combined = combined.drop_duplicates("ts").sort_values("ts").reset_index(drop=True)
    else:
        combined = existing_df

    save(combined, args.output)
    print(f"\nDone. {len(combined):,} rows → {args.output}")
    print(f"  {combined['ts'].iloc[0]}  →  {combined['ts'].iloc[-1]}")
    print(f"  close: ${combined['close'].min():,.0f} – ${combined['close'].max():,.0f}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--from", dest="from_date", default="2019-01-01")
    parser.add_argument("--to", default="2025-03-15")
    parser.add_argument("--output", default=OUTPUT)
    parser.add_argument("--refresh", action="store_true",
                        help="Ignore existing file, re-fetch everything")
    fetch(parser.parse_args())


if __name__ == "__main__":
    main()
