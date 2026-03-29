"""Encode candles on demand and cache hypervectors in the analysis DB.

Reads raw features from the candles table, normalizes using feature_stats,
encodes via Holon, and stores the resulting stripe vectors in the vectors table.

Supports named encoding schemes so different feature subsets can coexist.

Usage:
    # Encode all BUY candles (oracle 0.5%) from 2019-2020 with the flat15 scheme
    ./scripts/run_with_venv.sh python holon-lab-trading/scripts/encode_to_db.py \
        --scheme flat15_norm --label BUY --label-col label_oracle_05 --years 2019 2020

    # Encode a random sample of 1000 QUIET candles
    ./scripts/run_with_venv.sh python holon-lab-trading/scripts/encode_to_db.py \
        --scheme flat15_norm --label QUIET --sample 1000

    # List cached schemes and counts
    ./scripts/run_with_venv.sh python holon-lab-trading/scripts/encode_to_db.py --list
"""

from __future__ import annotations

import argparse
import sqlite3
import sys
import time
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent.parent))

from holon import HolonClient
from holon.kernel.walkable import LinearScale, WalkableSpread
from holon.memory import StripedSubspace

DB_PATH = Path(__file__).parent.parent / "data" / "analysis.db"

DIM = 1024
K = 32
N_STRIPES = 32
WINDOW = 12


SCHEMES = {
    "flat15_norm": [
        "open_r", "high_r", "low_r", "vol_r", "rsi", "ret",
        "sma20_r", "sma50_r", "macd_hist_r", "bb_width", "adx",
        "body", "upper_wick", "lower_wick", "close_pos",
    ],
    "candle": ["body", "upper_wick", "lower_wick", "close_pos"],
    "momentum": ["rsi", "macd_hist_r", "adx", "ret"],
    "volume": ["vol_rel", "range_chg"],
    "structure": ["sma20_r", "sma50_r", "bb_width", "bb_pos"],
    "price": ["open_r", "high_r", "low_r", "close_pos"],
    "full_norm": [
        "open_r", "high_r", "low_r", "vol_r", "rsi", "ret",
        "sma20_r", "sma50_r", "sma200_r",
        "macd_line_r", "macd_signal_r", "macd_hist_r",
        "bb_width", "bb_pos", "atr_r",
        "dmi_plus", "dmi_minus", "adx",
        "body", "upper_wick", "lower_wick", "close_pos",
        "vol_rel", "range_chg",
    ],
}


def log(msg: str):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def load_norm_stats(conn: sqlite3.Connection) -> dict[str, dict]:
    """Load normalization stats from the DB."""
    rows = conn.execute("SELECT * FROM feature_stats").fetchall()
    stats = {}
    for r in rows:
        stats[r[0]] = {"mean": r[1], "std": r[2], "min": r[3], "max": r[4], "p01": r[5], "p99": r[6]}
    return stats


def normalize(value: float, feat_stats: dict) -> float:
    """Z-score normalize a feature value."""
    std = feat_stats["std"]
    if std < 1e-10:
        return 0.0
    return (value - feat_stats["mean"]) / std


def encode_window(client: HolonClient, rows: list[sqlite3.Row],
                  features: list[str], norm_stats: dict[str, dict]) -> list[np.ndarray] | None:
    """Encode a window of rows into striped hypervectors."""
    if len(rows) < WINDOW:
        return None

    walkable = {}
    window_rows = rows[-WINDOW:]

    for feat in features:
        vals = []
        for r in window_rows:
            raw = r[feat]
            if raw is None:
                raw = 0.0
            if feat in norm_stats:
                vals.append(LinearScale(normalize(float(raw), norm_stats[feat])))
            else:
                vals.append(LinearScale(float(raw)))
        walkable[feat] = WalkableSpread(vals)

    return client.encoder.encode_walkable_striped(walkable, n_stripes=N_STRIPES)


def get_candidate_timestamps(conn: sqlite3.Connection, label: str | None,
                             label_col: str, years: tuple[int, int] | None,
                             sample: int | None) -> list[str]:
    """Get timestamps of candles to encode."""
    conditions = []
    if label:
        conditions.append(f"{label_col} = '{label}'")
    if years:
        conditions.append(f"year BETWEEN {years[0]} AND {years[1]}")

    where = "WHERE " + " AND ".join(conditions) if conditions else ""
    order = "ORDER BY RANDOM()" if sample else "ORDER BY ts"
    limit = f"LIMIT {sample}" if sample else ""

    rows = conn.execute(f"SELECT ts FROM candles {where} {order} {limit}").fetchall()
    return [r[0] for r in rows]


def already_cached(conn: sqlite3.Connection, ts: str, scheme: str) -> bool:
    """Check if a timestamp is already encoded for this scheme."""
    r = conn.execute(
        "SELECT 1 FROM vectors WHERE ts = ? AND scheme = ? LIMIT 1",
        (ts, scheme),
    ).fetchone()
    return r is not None


def store_vectors(conn: sqlite3.Connection, ts: str, scheme: str,
                  stripe_vecs: list[np.ndarray]):
    """Store stripe vectors in the DB."""
    for i, vec in enumerate(stripe_vecs):
        conn.execute(
            "INSERT OR REPLACE INTO vectors (ts, scheme, stripe_idx, vec) VALUES (?, ?, ?, ?)",
            (ts, scheme, i, vec.tobytes()),
        )


def load_vectors(conn: sqlite3.Connection, ts: str, scheme: str) -> list[np.ndarray] | None:
    """Load cached stripe vectors from the DB."""
    rows = conn.execute(
        "SELECT stripe_idx, vec FROM vectors WHERE ts = ? AND scheme = ? ORDER BY stripe_idx",
        (ts, scheme),
    ).fetchall()
    if not rows:
        return None
    return [np.frombuffer(r[1], dtype=np.int8).copy() for r in rows]


def list_cached(conn: sqlite3.Connection):
    """List all cached encoding schemes and their counts."""
    rows = conn.execute("""
        SELECT scheme, COUNT(DISTINCT ts) as n_candles,
               COUNT(*) / COUNT(DISTINCT ts) as stripes_per
        FROM vectors GROUP BY scheme ORDER BY scheme
    """).fetchall()
    if not rows:
        print("No cached vectors yet.")
        return
    print(f"{'Scheme':<20s} | {'Candles':>10s} | {'Stripes/candle':>14s}")
    print(f"{'-'*20}-+-{'-'*10}-+-{'-'*14}")
    for r in rows:
        print(f"{r[0]:<20s} | {r[1]:>10,} | {r[2]:>14}")


def main():
    parser = argparse.ArgumentParser(description="Encode candles and cache in analysis DB")
    parser.add_argument("--scheme", type=str, help="Encoding scheme name")
    parser.add_argument("--label", type=str, help="Filter by label value (BUY/SELL/QUIET)")
    parser.add_argument("--label-col", type=str, default="label_oracle_05", help="Label column")
    parser.add_argument("--years", type=int, nargs=2, help="Year range (e.g., 2019 2020)")
    parser.add_argument("--sample", type=int, help="Random sample size")
    parser.add_argument("--list", action="store_true", help="List cached schemes")
    parser.add_argument("--batch-size", type=int, default=500, help="Commit every N candles")
    args = parser.parse_args()

    conn = sqlite3.connect(str(DB_PATH))
    conn.row_factory = sqlite3.Row

    if args.list:
        list_cached(conn)
        conn.close()
        return

    if not args.scheme:
        print("Available schemes:")
        for name, feats in SCHEMES.items():
            print(f"  {name}: {', '.join(feats)}")
        print("\nUse --scheme <name> to encode.")
        conn.close()
        return

    if args.scheme not in SCHEMES:
        print(f"Unknown scheme: {args.scheme}")
        print(f"Available: {', '.join(SCHEMES.keys())}")
        conn.close()
        return

    features = SCHEMES[args.scheme]
    norm_stats = load_norm_stats(conn)
    years = tuple(args.years) if args.years else None

    log(f"Scheme: {args.scheme} ({len(features)} features)")
    log(f"Features: {', '.join(features)}")
    log(f"Normalization: z-score from 2019-2020 stats")

    # Get candidate timestamps
    timestamps = get_candidate_timestamps(conn, args.label, args.label_col, years, args.sample)
    log(f"Candidates: {len(timestamps):,} candles")

    # Filter out already cached
    uncached = [ts for ts in timestamps if not already_cached(conn, ts, args.scheme)]
    log(f"Uncached: {len(uncached):,} (skipping {len(timestamps) - len(uncached):,} cached)")

    if not uncached:
        log("Nothing to encode.")
        conn.close()
        return

    client = HolonClient(dimensions=DIM)

    # For each candle, we need to load a window of WINDOW rows ending at that timestamp
    encoded = 0
    skipped = 0
    t0 = time.time()

    for i, ts in enumerate(uncached):
        # Load window of rows ending at this timestamp
        window_rows = conn.execute(f"""
            SELECT * FROM candles WHERE ts <= ? ORDER BY ts DESC LIMIT {WINDOW}
        """, (ts,)).fetchall()

        if len(window_rows) < WINDOW:
            skipped += 1
            continue

        # Reverse to chronological order
        window_rows = list(reversed(window_rows))

        stripe_vecs = encode_window(client, window_rows, features, norm_stats)
        if stripe_vecs is None:
            skipped += 1
            continue

        store_vectors(conn, ts, args.scheme, stripe_vecs)
        encoded += 1

        if encoded % args.batch_size == 0:
            conn.commit()
            elapsed = time.time() - t0
            rate = encoded / elapsed if elapsed > 0 else 0
            log(f"  {encoded:,} / {len(uncached):,} encoded ({rate:.0f}/s)")

    conn.commit()
    elapsed = time.time() - t0
    log(f"Done: {encoded:,} encoded, {skipped:,} skipped, {elapsed:.1f}s")
    list_cached(conn)
    conn.close()


if __name__ == "__main__":
    main()
