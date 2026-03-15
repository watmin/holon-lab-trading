"""Label BTC reversal points in historical data and validate algebraic separability.

Uses scipy.signal.find_peaks with prominence filtering to identify genuine
local maxima (SELL setups) and minima (BUY setups) in the close price series.

Prominence: a peak must rise/fall at least PROMINENCE_PCT% from its surrounding
base before being counted. This filters microstructure noise while preserving
real regime changes.

Outputs:
  data/reversal_labels.parquet  — full candle DataFrame with action column
  data/reversal_report.txt      — summary statistics and geometry validation

Then runs a geometry gate:
  - Encode windows ending at each labeled reversal
  - Encode equal number of random (unlabeled) windows
  - Test whether the two groups are algebraically separable (t-test on cosine sim)
  - If separable: mint seed engrams from labeled reversals

Usage:
    ./scripts/run_with_venv.sh python scripts/label_reversals.py
    ./scripts/run_with_venv.sh python scripts/label_reversals.py --prominence 0.03 --min-dist 24
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np
import pandas as pd
from scipy.signal import find_peaks
from scipy.stats import ttest_ind

# Make trading package importable
sys.path.insert(0, str(Path(__file__).parent.parent))

from trading.encoder import OHLCVEncoder
from trading.features import TechnicalFeatureFactory
from holon import HolonClient
from holon.memory import StripedSubspace, EngramLibrary


# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------

PROMINENCE_PCT = 0.02   # peak must move ≥2% from its base to count
MIN_DIST_BARS  = 12     # minimum 12 bars (1 hour) between peaks
LABEL_OFFSET   = 1      # label this many bars BEFORE the reversal (what a trader sees)
N_STRIPES      = OHLCVEncoder.N_STRIPES
WINDOW_CANDLES = OHLCVEncoder.WINDOW_CANDLES
LOOKBACK       = OHLCVEncoder.LOOKBACK_CANDLES
DIM            = 512    # smaller for speed in the geometry test
K              = 16


# ---------------------------------------------------------------------------
# Labeling
# ---------------------------------------------------------------------------

def label_reversals(
    df: pd.DataFrame,
    prominence_pct: float = PROMINENCE_PCT,
    min_dist: int = MIN_DIST_BARS,
    offset: int = LABEL_OFFSET,
) -> pd.DataFrame:
    """Add an 'action' column to df: BUY at local minima, SELL at local maxima, HOLD elsewhere.

    The label is placed `offset` bars before the actual reversal bar so it
    represents what a trader would see just before the turn.

    Args:
        df: OHLCV DataFrame with a 'close' column.
        prominence_pct: Minimum price move (as fraction of close) for a valid reversal.
        min_dist: Minimum bars between consecutive peaks.
        offset: How many bars before the reversal to place the label (1 = previous bar).
    """
    close = df["close"].values
    prominence = float(np.median(close)) * prominence_pct

    # Local maxima → SELL setups
    peaks, _ = find_peaks(close, prominence=prominence, distance=min_dist)
    # Local minima → BUY setups (invert the series)
    troughs, _ = find_peaks(-close, prominence=prominence, distance=min_dist)

    df = df.copy()
    df["action"] = "HOLD"

    # Place labels `offset` bars before the reversal
    for idx in peaks:
        label_idx = max(0, idx - offset)
        df.iloc[label_idx, df.columns.get_loc("action")] = "SELL"

    for idx in troughs:
        label_idx = max(0, idx - offset)
        df.iloc[label_idx, df.columns.get_loc("action")] = "BUY"

    return df, peaks, troughs


# ---------------------------------------------------------------------------
# Geometry validation
# ---------------------------------------------------------------------------

def encode_window(encoder: OHLCVEncoder, df: pd.DataFrame, end_idx: int) -> list[np.ndarray] | None:
    """Encode the window ending at end_idx. Returns None if insufficient data."""
    needed = LOOKBACK + WINDOW_CANDLES
    start = end_idx - needed + 1
    if start < 0:
        return None
    window_df = df.iloc[start:end_idx + 1].copy()
    if len(window_df) < needed:
        return None
    try:
        return encoder.encode(window_df)
    except Exception:
        return None


def agg_cosine(vecs_a: list[np.ndarray], vecs_b: list[np.ndarray]) -> float:
    """Mean per-stripe cosine similarity between two stripe vector lists."""
    sims = []
    for a, b in zip(vecs_a, vecs_b):
        a_f, b_f = a.astype(float), b.astype(float)
        na, nb = np.linalg.norm(a_f), np.linalg.norm(b_f)
        if na > 1e-10 and nb > 1e-10:
            sims.append(float(np.dot(a_f, b_f) / (na * nb)))
    return float(np.mean(sims)) if sims else 0.0


def geometry_gate(
    df: pd.DataFrame,
    encoder: OHLCVEncoder,
    reversal_indices: np.ndarray,
    label: str,
    n_sample: int = 200,
    rng: np.random.Generator = None,
) -> dict:
    """Test whether reversal windows are geometrically separable from random windows.

    Returns a dict with keys: within_mean, random_mean, separation, t_stat, p_value, passed.
    """
    if rng is None:
        rng = np.random.default_rng(0)

    # Encode reversal windows
    rev_vecs = []
    for idx in reversal_indices:
        v = encode_window(encoder, df, idx)
        if v is not None:
            rev_vecs.append(v)
        if len(rev_vecs) >= n_sample:
            break

    if len(rev_vecs) < 10:
        return {"error": f"Too few encodable {label} reversals: {len(rev_vecs)}"}

    # Encode random windows (same count, avoid reversal indices)
    rev_set = set(reversal_indices.tolist())
    valid_random = [i for i in range(LOOKBACK + WINDOW_CANDLES, len(df))
                    if i not in rev_set]
    random_sample = rng.choice(valid_random, size=min(len(rev_vecs), len(valid_random)),
                               replace=False)
    rand_vecs = []
    for idx in random_sample:
        v = encode_window(encoder, df, idx)
        if v is not None:
            rand_vecs.append(v)
        if len(rand_vecs) >= len(rev_vecs):
            break

    # Within-reversal pairwise cosine (sample pairs)
    n_pairs = min(500, len(rev_vecs) * (len(rev_vecs) - 1) // 2)
    within_scores = []
    indices = rng.choice(len(rev_vecs), size=(n_pairs, 2), replace=True)
    for i, j in indices:
        if i != j:
            within_scores.append(agg_cosine(rev_vecs[i], rev_vecs[j]))

    # Random pairwise cosine
    random_scores = []
    indices_r = rng.choice(len(rand_vecs), size=(n_pairs, 2), replace=True)
    for i, j in indices_r:
        if i != j:
            random_scores.append(agg_cosine(rand_vecs[i], rand_vecs[j]))

    within_mean = float(np.mean(within_scores))
    random_mean = float(np.mean(random_scores))
    sep = within_mean - random_mean
    t_stat, p_value = ttest_ind(within_scores, random_scores, alternative="greater")

    return {
        "label": label,
        "n_reversals": len(rev_vecs),
        "n_random": len(rand_vecs),
        "within_mean": within_mean,
        "within_std": float(np.std(within_scores)),
        "random_mean": random_mean,
        "random_std": float(np.std(random_scores)),
        "separation": sep,
        "t_stat": float(t_stat),
        "p_value": float(p_value),
        "passed": sep > 0 and p_value < 0.05,
    }


# ---------------------------------------------------------------------------
# Engram minting from labeled reversals
# ---------------------------------------------------------------------------

def mint_reversal_engrams(
    df: pd.DataFrame,
    encoder: OHLCVEncoder,
    labeled_df: pd.DataFrame,
    library: EngramLibrary,
    rng: np.random.Generator,
    max_engrams: int = 50,
) -> int:
    """Train a StripedSubspace on each reversal cluster and mint an engram.

    Groups reversals into temporal clusters (within 48h of each other),
    trains a subspace on each cluster's windows, and mints one engram per cluster.
    """
    buy_rows  = labeled_df[labeled_df["action"] == "BUY"].index.tolist()
    sell_rows = labeled_df[labeled_df["action"] == "SELL"].index.tolist()

    minted = 0
    for action, indices in [("BUY", buy_rows), ("SELL", sell_rows)]:
        # Shuffle and take up to max_engrams // 2 individual reversal engrams
        rng.shuffle(indices)
        for idx in indices[:max_engrams // 2]:
            v = encode_window(encoder, df, idx)
            if v is None:
                continue
            ss = StripedSubspace(dim=DIM, k=K, n_stripes=N_STRIPES)
            # Seed with the reversal window + its neighbors for a richer manifold
            for offset in range(-3, 4):
                neighbor = encode_window(encoder, df, idx + offset)
                if neighbor is not None:
                    ss.update(neighbor)
            if ss.n < 3:
                continue
            engram_name = f"reversal_{action.lower()}_{idx}"
            library.add_striped(
                engram_name, ss, None,
                action=action, confidence=0.75,
                score=0.0, origin="labeled_reversal",
                bar_idx=int(idx),
            )
            minted += 1

    return minted


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="Label BTC reversals and validate geometry")
    parser.add_argument("--parquet", default="holon-lab-trading/data/btc_5m.parquet")
    parser.add_argument("--prominence", type=float, default=PROMINENCE_PCT,
                        help="Min price move fraction for valid reversal (default 0.02 = 2%%)")
    parser.add_argument("--min-dist", type=int, default=MIN_DIST_BARS,
                        help="Min bars between peaks (default 12 = 1h)")
    parser.add_argument("--offset", type=int, default=LABEL_OFFSET,
                        help="Bars before reversal to place label (default 1)")
    parser.add_argument("--no-mint", action="store_true",
                        help="Skip engram minting (geometry test only)")
    args = parser.parse_args()

    # --- Load data ---
    print(f"Loading {args.parquet}...")
    df = pd.read_parquet(args.parquet)
    print(f"  {len(df)} candles | {df['ts'].iloc[0]} → {df['ts'].iloc[-1]}")
    print(f"  close range: ${df['close'].min():,.0f} – ${df['close'].max():,.0f}")

    # --- Label reversals ---
    labeled_df, peaks, troughs = label_reversals(
        df,
        prominence_pct=args.prominence,
        min_dist=args.min_dist,
        offset=args.offset,
    )

    n_buy  = (labeled_df["action"] == "BUY").sum()
    n_sell = (labeled_df["action"] == "SELL").sum()
    print(f"\nLabeling (prominence={args.prominence:.1%}, min_dist={args.min_dist} bars):")
    print(f"  BUY  labels (local minima):  {n_buy:>5}")
    print(f"  SELL labels (local maxima):  {n_sell:>5}")
    print(f"  HOLD (unlabeled):            {(labeled_df['action']=='HOLD').sum():>5}")

    # Sample a few to sanity-check
    print("\nSample BUY labels:")
    buy_sample = labeled_df[labeled_df["action"] == "BUY"][["ts", "close", "action"]].head(5)
    print(buy_sample.to_string(index=False))
    print("\nSample SELL labels:")
    sell_sample = labeled_df[labeled_df["action"] == "SELL"][["ts", "close", "action"]].head(5)
    print(sell_sample.to_string(index=False))

    # Save labeled dataset
    out_path = "holon-lab-trading/data/reversal_labels.parquet"
    labeled_df.to_parquet(out_path, index=False)
    print(f"\nSaved labeled data → {out_path}")

    # --- Set up encoder ---
    print("\nInitializing encoder (dim={})...".format(DIM))
    client = HolonClient(dimensions=DIM)
    encoder = OHLCVEncoder(client)

    # --- Geometry gate ---
    rng = np.random.default_rng(42)
    print("\n" + "=" * 60)
    print("  Geometry Gate: Are reversals algebraically separable?")
    print("=" * 60)

    results = {}
    for label, indices in [("BUY", troughs), ("SELL", peaks)]:
        print(f"\n[{label}] Testing {len(indices)} reversal windows...")
        r = geometry_gate(df, encoder, indices, label, n_sample=300, rng=rng)
        results[label] = r
        if "error" in r:
            print(f"  ERROR: {r['error']}")
            continue
        status = "✓ PASS" if r["passed"] else "✗ FAIL"
        print(f"  [{status}] within={r['within_mean']:.4f}±{r['within_std']:.4f}  "
              f"random={r['random_mean']:.4f}±{r['random_std']:.4f}")
        print(f"           sep={r['separation']:+.4f}  t={r['t_stat']:.2f}  p={r['p_value']:.4f}")
        print(f"           n_reversals={r['n_reversals']}  n_random={r['n_random']}")

    print("\n" + "=" * 60)
    all_passed = all(r.get("passed", False) for r in results.values() if "error" not in r)
    if all_passed:
        print("  ✓ GEOMETRY GATE PASSED — reversal windows are separable")
    else:
        print("  ✗ GEOMETRY GATE FAILED — reversal windows are NOT separable")
        print("    Consider: wider timeframe, larger prominence, longer window")
    print("=" * 60)

    # --- Mint seed engrams from labeled reversals ---
    if not args.no_mint and all_passed:
        print("\nMinting reversal engrams...")
        library = EngramLibrary(dim=DIM)
        n_minted = mint_reversal_engrams(df, encoder, labeled_df, library, rng)
        engram_path = "holon-lab-trading/data/seed_engrams.json"
        library.save(engram_path)
        print(f"  Minted {n_minted} engrams → {engram_path}")
        print(f"  BUY:  {len(library.names(kind='striped'))} total striped engrams")

    elif not all_passed:
        print("\nSkipping engram minting — geometry gate failed.")
        print("The encoding does not show algebraic separation at this timescale/prominence.")


if __name__ == "__main__":
    main()
