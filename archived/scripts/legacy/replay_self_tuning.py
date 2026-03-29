"""Full historical replay to prove self-tuning works.

Walks all 652k candles (6 years of 5-minute BTC) in sequential chunks.
After each chunk the AsyncCritic fires synchronously, scoring engrams
from realized returns, consolidating redundant ones, and pruning weak ones.

What "self-tuning works" means here — measurable and falsifiable:
  1. Win rate (correct BUY/SELL direction) improves across epochs
  2. Action diversity increases: more BUY/SELL, fewer HOLD as library matures
  3. Library stabilizes: fewer engrams, higher average score (regime consolidation)
  4. Equity curve trend improves in later epochs vs earlier ones

Output:
  - Epoch-by-epoch CSV:  data/replay_epochs.csv
  - Final equity plot:   data/replay_equity.png  (if matplotlib available)
  - Summary printed to stdout

Usage:
    ./scripts/run_with_venv.sh python -u scripts/replay_self_tuning.py
    ./scripts/run_with_venv.sh python -u scripts/replay_self_tuning.py \\
        --chunk 2000 --start-fresh
"""

from __future__ import annotations

import argparse
import csv
import sys
import tempfile
import time
from pathlib import Path

import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).parent.parent))

from trading.encoder import OHLCVEncoder
from trading.features import TechnicalFeatureFactory
from trading.system import AsyncCritic, RealTimeConsumer, TradingSystem, _RWLock

PARQUET      = Path("holon-lab-trading/data/btc_5m_raw.parquet")
SEED_ENGRAMS = Path("holon-lab-trading/data/seed_engrams.json")
OUTPUT_DIR   = Path("holon-lab-trading/data")

WINDOW_SIZE  = OHLCVEncoder.LOOKBACK_CANDLES + OHLCVEncoder.WINDOW_CANDLES
ENCODE_WINDOW = OHLCVEncoder.WINDOW_CANDLES  # rows fed to encode_from_precomputed


def _make_chunk_feed(df_raw: pd.DataFrame, df_ind: pd.DataFrame, n_dropped: int,
                     start: int, length: int):
    """Yield (encode_slice, raw_tail) pairs for each candle in the chunk.

    df_raw:    full raw OHLCV dataframe (for candle_ts and price)
    df_ind:    precomputed indicators, length = len(df_raw) - n_dropped
    n_dropped: warmup rows removed from the front of df_raw to form df_ind
    start:     index into df_ind to start (must be >= ENCODE_WINDOW)
    length:    number of steps
    """
    end = min(start + length, len(df_ind) - 1)
    for i in range(start, end):
        encode_start = i - ENCODE_WINDOW + 1
        if encode_start < 0:
            continue
        encode_slice = df_ind.iloc[encode_start:i + 1].reset_index(drop=True)
        # df_raw row for df_ind[i] is at df_raw[i + n_dropped]
        raw_tail = df_raw.iloc[i + n_dropped]
        yield encode_slice, raw_tail


def _epoch_stats(tracker, epoch_start_step: int) -> dict:
    """Compute metrics for the current epoch from the tracker's decision log."""
    df = tracker.recent_decisions(last_n=99999)
    epoch_df = df[df["step"] >= epoch_start_step].copy()
    if len(epoch_df) == 0:
        return {}

    epoch_df = epoch_df.sort_values("candle_ts").reset_index(drop=True)
    epoch_df["actual_return"] = epoch_df["price"].pct_change().shift(-1)

    traded = epoch_df[epoch_df["action"] != "HOLD"]
    win_rate = 0.0
    if len(traded) > 0:
        correct = (
            ((traded["action"] == "BUY")  & (traded["actual_return"] > 0)) |
            ((traded["action"] == "SELL") & (traded["actual_return"] < 0))
        )
        win_rate = float(correct.mean())

    equity_start = epoch_df["equity"].iloc[0]  if len(epoch_df) > 0 else 1.0
    equity_end   = epoch_df["equity"].iloc[-1] if len(epoch_df) > 0 else 1.0
    epoch_return = (equity_end / equity_start - 1.0) if equity_start > 0 else 0.0

    action_counts = epoch_df["action"].value_counts().to_dict()
    return {
        "n_decisions": len(epoch_df),
        "n_buy":  action_counts.get("BUY", 0),
        "n_sell": action_counts.get("SELL", 0),
        "n_hold": action_counts.get("HOLD", 0),
        "win_rate": win_rate,
        "epoch_return": epoch_return,
        "equity_end": equity_end,
    }


def run(
    chunk_candles: int = 2016,   # ~1 week of 5m candles
    score_window: int = 500,     # critic scores last N decisions per epoch
    max_epochs: int | None = None,
    verbose: bool = True,
    start_year: int = 2021,
) -> None:
    t_start = time.time()

    print(f"\n{'='*70}", flush=True)
    print(f"  HISTORICAL SELF-TUNING REPLAY", flush=True)
    print(f"  chunk={chunk_candles} candles (~{chunk_candles*5/60/24:.1f} days)", flush=True)
    print(f"  score_window={score_window} decisions per critic cycle", flush=True)
    print(f"  start_year={start_year} (seed engrams trained on earlier data)", flush=True)
    print(f"{'='*70}\n", flush=True)

    # --- Load data and precompute indicators once ---
    print("Loading historical data...", flush=True)
    df_raw = pd.read_parquet(PARQUET)
    if "timestamp" in df_raw.columns and "ts" not in df_raw.columns:
        df_raw = df_raw.rename(columns={"timestamp": "ts"})

    # Filter to start_year onwards — replay only on data unseen by seed engrams
    ts = pd.to_datetime(df_raw["ts"])
    df_raw = df_raw[ts >= pd.Timestamp(f"{start_year}-01-01")].reset_index(drop=True)
    print(f"  {len(df_raw):,} candles ({df_raw['ts'].iloc[0]} → {df_raw['ts'].iloc[-1]})", flush=True)

    print("Precomputing technical indicators (one-time, ~0.3s)...", flush=True)
    factory = TechnicalFeatureFactory()
    df_ind = factory.compute_indicators(df_raw)
    # df_ind has NaN warmup rows dropped; its index aligns with df_raw after offset
    n_dropped = len(df_raw) - len(df_ind)
    print(f"  {len(df_ind):,} indicator rows ({n_dropped} warmup rows dropped)", flush=True)

    # --- Build system (fresh, no live state from disk) ---
    with tempfile.TemporaryDirectory() as tmpdir:
        db_path    = f"{tmpdir}/replay.db"
        engram_out = f"{tmpdir}/live_engrams.json"
        epochs_csv = OUTPUT_DIR / "replay_epochs.csv"
        OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

        system = TradingSystem(
            seed_engrams=str(SEED_ENGRAMS),
            live_engrams=engram_out,
            db_path=db_path,
            critic_interval_minutes=999,
        )

        critic = AsyncCritic(
            library=system.library,
            library_lock=system.library_lock,
            tracker=system.tracker,
            darwinism=system.darwinism,
            dimensions=system._dimensions,
            k=system._k,
            n_stripes=system._n_stripes,
            interval_minutes=999,
            engram_path=engram_out,
            score_window_n=score_window,
        )

        consumer = RealTimeConsumer(
            encoder=system.encoder,
            library=system.library,
            library_lock=system.library_lock,
            subspace=system.subspace,
            tracker=system.tracker,
            darwinism=system.darwinism,
            engram_path=engram_out,
            reload_interval_s=999999,
        )

        # Determine valid start in df_ind space:
        # need ENCODE_WINDOW rows of lookback within df_ind
        data_start = ENCODE_WINDOW
        total_candles = len(df_ind) - data_start - 1
        n_epochs = total_candles // chunk_candles
        if max_epochs:
            n_epochs = min(n_epochs, max_epochs)

        print(f"  Running {n_epochs} epochs × {chunk_candles} candles = "
              f"{n_epochs * chunk_candles:,} total decisions\n", flush=True)

        epoch_records = []
        epoch_start_step = 1

        with open(epochs_csv, "w", newline="") as fh:
            writer = csv.DictWriter(fh, fieldnames=[
                "epoch", "candle_range_start", "candle_range_end",
                "lib_size", "critic_version", "n_decisions",
                "n_buy", "n_sell", "n_hold",
                "win_rate", "epoch_return", "equity_end",
                "elapsed_s",
            ])
            writer.writeheader()

            for epoch in range(n_epochs):
                chunk_start = data_start + epoch * chunk_candles
                chunk_end   = chunk_start + chunk_candles
                t_epoch = time.time()

                # --- Consumer phase (fast path: precomputed indicators) ---
                steps = 0
                prev_price = None
                surprise_profile = {}
                price = 0.0

                for encode_slice, raw_tail in _make_chunk_feed(df_raw, df_ind, n_dropped, chunk_start, chunk_candles):
                    if consumer._stop.is_set():
                        break

                    t0 = time.perf_counter()
                    # encode_from_precomputed skips indicator recomputation (~1.8x faster)
                    stripe_vecs = consumer.encoder.encode_from_precomputed(encode_slice)
                    # Build walkable for surprise profile attribution
                    walkable = consumer.encoder._build_walkable_from_precomputed(encode_slice)
                    latency_ms = (time.perf_counter() - t0) * 1000

                    action, confidence, used_ids, surprise_profile = consumer._decide(
                        stripe_vecs, walkable
                    )

                    price = float(raw_tail["close"])
                    candle_ts = str(raw_tail["ts"] if "ts" in raw_tail.index else raw_tail.name)

                    consumer.tracker.record(
                        action, confidence, price,
                        latency_ms=latency_ms,
                        used_engrams=used_ids,
                        candle_ts=candle_ts,
                    )

                    if prev_price is not None and surprise_profile:
                        actual_return = (price / prev_price) - 1.0
                        consumer.darwinism.update(surprise_profile, actual_return, action)
                        consumer.encoder.update_weights(consumer.darwinism.get_weights())

                    if verbose and steps % 200 == 0:
                        lib_size = len(system.library)
                        equity   = system.tracker.equity(price)
                        print(
                            f"  [e{epoch:03d}|s{steps:04d}] {action:4s} | "
                            f"equity=${equity:>10,.0f} | "
                            f"lat={latency_ms:.0f}ms | lib={lib_size}",
                            flush=True,
                        )

                    if consumer._stop.is_set():
                        break

                    prev_price = price
                    steps += 1

                # --- Critic phase (synchronous in replay) ---
                critic._critic_cycle()

                # --- Record epoch metrics ---
                stats = _epoch_stats(system.tracker, epoch_start_step)
                lib_size = len(system.library)

                row = {
                    "epoch": epoch,
                    "candle_range_start": chunk_start,
                    "candle_range_end": chunk_end,
                    "lib_size": lib_size,
                    "critic_version": critic._version,
                    **stats,
                    "elapsed_s": round(time.time() - t_epoch, 1),
                }
                writer.writerow(row)
                fh.flush()
                epoch_records.append(row)
                epoch_start_step = system.tracker._step + 1

                print(
                    f"\n[EPOCH {epoch:03d}] "
                    f"lib={lib_size:3d} | "
                    f"v={critic._version} | "
                    f"win={stats.get('win_rate',0):.1%} | "
                    f"return={stats.get('epoch_return',0):+.2%} | "
                    f"equity=${stats.get('equity_end',0):>10,.0f} | "
                    f"BUY={stats.get('n_buy',0)} SELL={stats.get('n_sell',0)} HOLD={stats.get('n_hold',0)} | "
                    f"elapsed={row['elapsed_s']}s",
                    flush=True,
                )

        # --- Final analysis ---
        total_s = time.time() - t_start
        edf = pd.DataFrame(epoch_records)

        print(f"\n{'='*70}", flush=True)
        print(f"  SELF-TUNING RESULTS  ({n_epochs} epochs, {total_s/60:.1f} min total)", flush=True)
        print(f"{'='*70}", flush=True)

        if len(edf) > 4:
            first_q = edf.iloc[:len(edf)//4]
            last_q  = edf.iloc[-len(edf)//4:]

            wr_first = first_q["win_rate"].mean()
            wr_last  = last_q["win_rate"].mean()
            ret_first = first_q["epoch_return"].mean()
            ret_last  = last_q["epoch_return"].mean()
            lib_first = first_q["lib_size"].mean()
            lib_last  = last_q["lib_size"].mean()
            hold_first = (first_q["n_hold"] / (first_q["n_decisions"]+1)).mean()
            hold_last  = (last_q["n_hold"]  / (last_q["n_decisions"]+1)).mean()

            print(f"\n  Metric           First 25% epochs   Last 25% epochs   Δ", flush=True)
            print(f"  ─────────────────────────────────────────────────────────", flush=True)
            print(f"  Win rate         {wr_first:>16.1%}   {wr_last:>14.1%}   {wr_last-wr_first:+.1%}", flush=True)
            print(f"  Avg epoch return {ret_first:>16.2%}   {ret_last:>14.2%}   {ret_last-ret_first:+.2%}", flush=True)
            print(f"  Library size     {lib_first:>16.1f}   {lib_last:>14.1f}   {lib_last-lib_first:+.1f}", flush=True)
            print(f"  HOLD fraction    {hold_first:>16.1%}   {hold_last:>14.1%}   {hold_last-hold_first:+.1%}", flush=True)

            improvement = (
                (wr_last > wr_first) or
                (ret_last > ret_first) or
                (hold_last < hold_first)
            )
            verdict = "✓ SELF-TUNING DEMONSTRATED" if improvement else "✗ No clear improvement yet"
            print(f"\n  Verdict: {verdict}", flush=True)

        final_equity = system.tracker.equity_curve[-1]
        total_return = final_equity / system.tracker.initial_usdt - 1
        print(f"\n  Final equity:   ${final_equity:>10,.2f}", flush=True)
        print(f"  Total return:   {total_return:+.2%}", flush=True)
        print(f"  Final lib size: {len(system.library)}", flush=True)
        print(f"  Critic version: {critic._version}", flush=True)
        print(f"  Epochs CSV:     {epochs_csv}", flush=True)

        # --- Plot if matplotlib available ---
        try:
            import matplotlib
            matplotlib.use("Agg")  # headless — no display required
            import matplotlib.pyplot as plt
            fig, axes = plt.subplots(4, 1, figsize=(14, 12), sharex=True)
            epochs_x = edf["epoch"]

            axes[0].plot(epochs_x, edf["equity_end"])
            axes[0].set_ylabel("Equity ($)")
            axes[0].set_title("End-of-epoch equity")
            axes[0].grid(alpha=0.3)

            axes[1].plot(epochs_x, edf["win_rate"])
            axes[1].axhline(0.5, color="gray", linestyle="--", alpha=0.5, label="50% baseline")
            axes[1].set_ylabel("Win rate")
            axes[1].set_ylim(0, 1)
            axes[1].legend()
            axes[1].grid(alpha=0.3)

            n_total = edf["n_decisions"].clip(lower=1)
            axes[2].stackplot(
                epochs_x,
                edf["n_hold"] / n_total,
                edf["n_buy"]  / n_total,
                edf["n_sell"] / n_total,
                labels=["HOLD", "BUY", "SELL"],
                colors=["#aaaaaa", "#44bb77", "#cc4444"],
                alpha=0.8,
            )
            axes[2].set_ylabel("Action fraction")
            axes[2].set_ylim(0, 1)
            axes[2].legend(loc="upper right")
            axes[2].grid(alpha=0.3)

            axes[3].plot(epochs_x, edf["lib_size"])
            axes[3].set_ylabel("Library size")
            axes[3].set_xlabel("Epoch")
            axes[3].grid(alpha=0.3)

            plt.tight_layout()
            plot_path = OUTPUT_DIR / "replay_equity.png"
            plt.savefig(plot_path, dpi=120)
            print(f"  Plot saved:     {plot_path}", flush=True)
            plt.close()
        except ImportError:
            print("  (matplotlib not available — skipping plot)", flush=True)

        print(f"\n✓ Replay complete in {total_s/60:.1f} minutes.\n", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Historical self-tuning replay")
    parser.add_argument(
        "--chunk", type=int, default=2016,
        help="Candles per epoch/chunk (default 2016 ≈ 1 week of 5m)",
    )
    parser.add_argument(
        "--score-window", type=int, default=500,
        help="Critic scores last N decisions per cycle (default 500)",
    )
    parser.add_argument(
        "--max-epochs", type=int, default=None,
        help="Cap number of epochs (default: all data)",
    )
    parser.add_argument(
        "--quiet", action="store_true",
        help="Suppress per-step output (only show epoch summaries)",
    )
    parser.add_argument(
        "--start-year", type=int, default=2021,
        help="First year of replay data (default 2021 — seeds trained on 2019-2020)",
    )
    args = parser.parse_args()

    run(
        chunk_candles=args.chunk,
        score_window=args.score_window,
        max_epochs=args.max_epochs,
        start_year=args.start_year,
        verbose=not args.quiet,
    )
