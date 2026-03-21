"""Label BTC reversal points in historical data and validate algebraic separability.

Uses scipy.signal.find_peaks with prominence filtering to identify genuine
local maxima (SELL setups) and minima (BUY setups) in the close price series.

Prominence: a peak must rise/fall at least PROMINENCE_PCT% from its surrounding
base before being counted. This filters microstructure noise while preserving
real regime changes.

GEOMETRY GATE — The Correct Holon Approach
==========================================
We do NOT use pairwise cosine similarity between encoded bundle vectors.
That is the "cosine-to-centroid" mistake documented in the Holon learning history
(batch 017): magnitude-only, misses non-radial structure, asks if windows look
similar to *each other* rather than whether they share an algebraic manifold.

The correct test (from the memory primer and residual-profile post):
  1. Split labeled reversals into train/test halves.
  2. Train a StripedSubspace on the train reversals → "reversal manifold".
  3. Train a StripedSubspace on random windows → "noise manifold".
  4. For each test reversal, compute:
       residual_rev  = reversal_subspace.residual(window)
       residual_rand = random_subspace.residual(window)
  5. For each random window (held out), compute the same pair.
  6. Signal: reversal windows should have LOW residual against the reversal
     subspace and HIGH residual against the random subspace (and vice versa
     for random windows). t-test on (residual_rand - residual_rev) vs 0.

If this passes, the reversal windows define a learnable algebraic manifold
that is distinct from general market noise — not just visually clustered,
but geometrically separable by StripedSubspace residual.

Outputs:
  data/reversal_labels.parquet  — full candle DataFrame with action column
  data/seed_engrams.json        — minted seed engrams (if gate passes)

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
from scipy.stats import ttest_1samp, ttest_ind

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
DIM            = 1024
K              = 4      # 208 leaves / 32 stripes ≈ 6.5 per stripe; low k avoids over-deflation


# ---------------------------------------------------------------------------
# Labeling
# ---------------------------------------------------------------------------

def label_reversals(
    df: pd.DataFrame,
    prominence_pct: float = PROMINENCE_PCT,
    min_dist: int = MIN_DIST_BARS,
    offset: int = LABEL_OFFSET,
    price_ref_slice: slice | None = None,
) -> pd.DataFrame:
    """Add an 'action' column to df: BUY at local minima, SELL at local maxima, HOLD elsewhere.

    The label is placed `offset` bars before the actual reversal bar so it
    represents what a trader would see just before the turn.

    Args:
        df: OHLCV DataFrame with a 'close' column.
        prominence_pct: Minimum price move (as fraction of close) for a valid reversal.
        min_dist: Minimum bars between consecutive peaks.
        offset: How many bars before the reversal to place the label (1 = previous bar).
        price_ref_slice: If provided, compute prominence from this slice of close
            prices instead of the full series. Use this to anchor prominence to a
            specific era (e.g. the seed training period) so the threshold is
            appropriate for that price regime.
    """
    close = df["close"].values
    ref_prices = close[price_ref_slice] if price_ref_slice is not None else close
    prominence = float(np.median(ref_prices)) * prominence_pct

    # Local maxima → SELL setups
    peaks, _ = find_peaks(close, prominence=prominence, distance=min_dist)
    # Local minima → BUY setups (invert the series)
    troughs, _ = find_peaks(-close, prominence=prominence, distance=min_dist)

    df = df.copy()
    df["action"] = "HOLD"

    # Vectorized label placement — avoid per-row iloc which is O(n) per assignment
    peak_labels   = np.clip(peaks - offset, 0, len(df) - 1)
    trough_labels = np.clip(troughs - offset, 0, len(df) - 1)
    df.iloc[peak_labels, df.columns.get_loc("action")]   = "SELL"
    df.iloc[trough_labels, df.columns.get_loc("action")] = "BUY"

    return df, peaks, troughs


# ---------------------------------------------------------------------------
# Geometry validation
# ---------------------------------------------------------------------------

def encode_window(encoder: OHLCVEncoder, df_ind: pd.DataFrame, end_idx: int) -> list[np.ndarray] | None:
    """Encode the window ending at end_idx from a pre-indicator DataFrame.

    df_ind must already have all indicator columns computed (via precompute_indicators).
    Uses encode_from_precomputed() to skip re-running compute_indicators.
    end_idx is a positional iloc index into df_ind.
    """
    start = end_idx - WINDOW_CANDLES + 1
    if start < 0 or end_idx >= len(df_ind):
        return None
    window_df = df_ind.iloc[start:end_idx + 1]
    if len(window_df) < WINDOW_CANDLES:
        return None
    try:
        return encoder.encode_from_precomputed(window_df)
    except Exception:
        return None


def train_subspace(
    stripe_vecs_list: list[list[np.ndarray]],
    dim: int,
    k: int,
    n_stripes: int,
) -> StripedSubspace:
    """Train a StripedSubspace on a list of stripe vector observations."""
    ss = StripedSubspace(dim=dim, k=k, n_stripes=n_stripes)
    for stripe_vecs in stripe_vecs_list:
        ss.update(stripe_vecs)
    return ss


def precompute_indicators(df: pd.DataFrame) -> pd.DataFrame:
    """Run indicator computation once across the full dataset.

    Returns a DataFrame with all indicator columns added. This is the expensive
    step — do it once, then all window slices are just iloc[] operations.
    """
    from trading.features import TechnicalFeatureFactory
    factory = TechnicalFeatureFactory()
    return factory.compute_indicators(df)


def geometry_gate(
    df_ind: pd.DataFrame,
    encoder: OHLCVEncoder,
    reversal_indices: np.ndarray,
    label: str,
    n_sample: int = 200,
    rng: np.random.Generator = None,
) -> dict:
    """Test whether reversal windows define a learnable algebraic manifold.

    The correct Holon approach — NOT pairwise cosine between bundle vectors.
    That is the batch-017 mistake (cosine-to-centroid = magnitude only).

    Method:
      1. Split reversal_indices into train/test halves.
      2. Encode all train reversals → train StripedSubspace on them.
      3. Encode n_sample random windows → train a "noise" StripedSubspace.
      4. For each test reversal: compute residual against both subspaces.
      5. Signal: delta = residual_noise - residual_reversal should be > 0.
         t-test against zero (one-sample, alternative="greater").

    If delta is significantly positive, reversal windows fit the reversal
    manifold better than the noise manifold — geometric separability proven.

    Returns dict with: reversal_residual_mean, noise_residual_mean, delta_mean,
                       t_stat, p_value, passed.
    """
    if rng is None:
        rng = np.random.default_rng(0)

    min_idx = WINDOW_CANDLES

    # Shuffle and partition reversal indices into train / test
    valid_rev = [i for i in reversal_indices if i >= min_idx]
    if len(valid_rev) < 20:
        return {"error": f"Too few {label} reversal indices: {len(valid_rev)}"}
    rng.shuffle(valid_rev)
    n_use = min(n_sample, len(valid_rev))
    n_train = n_use // 2
    train_indices = valid_rev[:n_train]
    test_indices  = valid_rev[n_train:n_use]

    # --- Encode training reversals ---
    print(f"    encoding {n_train} {label} train reversals...", flush=True)
    train_vecs = []
    for idx in train_indices:
        v = encode_window(encoder, df_ind, idx)
        if v is not None:
            train_vecs.append(v)

    if len(train_vecs) < 5:
        return {"error": f"Too few encodable {label} train reversals: {len(train_vecs)}"}

    # --- Encode test reversals ---
    print(f"    encoding {len(test_indices)} {label} test reversals...", flush=True)
    test_vecs = []
    for idx in test_indices:
        v = encode_window(encoder, df_ind, idx)
        if v is not None:
            test_vecs.append(v)

    if len(test_vecs) < 5:
        return {"error": f"Too few encodable {label} test reversals: {len(test_vecs)}"}

    # --- Encode random (noise) windows ---
    rev_set = set(reversal_indices.tolist())
    valid_rand = [i for i in range(min_idx, len(df_ind)) if i not in rev_set]
    rand_sample_idx = rng.choice(valid_rand, size=min(n_use, len(valid_rand)), replace=False)
    print(f"    encoding {len(rand_sample_idx)} random (noise) windows...", flush=True)
    rand_vecs = []
    for idx in rand_sample_idx:
        v = encode_window(encoder, df_ind, idx)
        if v is not None:
            rand_vecs.append(v)

    if len(rand_vecs) < 10:
        return {"error": f"Too few random windows: {len(rand_vecs)}"}

    # --- Train subspaces ---
    print(f"    training reversal subspace on {len(train_vecs)} samples...", flush=True)
    ss_reversal = train_subspace(train_vecs, DIM, K, N_STRIPES)

    n_rand_train = len(rand_vecs) // 2
    print(f"    training noise subspace on {n_rand_train} samples...", flush=True)
    ss_noise = train_subspace(rand_vecs[:n_rand_train], DIM, K, N_STRIPES)

    rand_test_vecs = rand_vecs[n_rand_train:]

    # --- Score test reversals against both manifolds ---
    # delta > 0 means the window fits the reversal manifold better than noise
    rev_deltas = []
    for sv in test_vecs:
        r_rev  = ss_reversal.residual(sv)
        r_noise = ss_noise.residual(sv)
        if not (np.isnan(r_rev) or np.isnan(r_noise) or np.isinf(r_rev) or np.isinf(r_noise)):
            rev_deltas.append(float(r_noise - r_rev))

    # --- Score held-out random windows against both manifolds (control) ---
    rand_deltas = []
    for sv in rand_test_vecs:
        r_rev  = ss_reversal.residual(sv)
        r_noise = ss_noise.residual(sv)
        if not (np.isnan(r_rev) or np.isnan(r_noise) or np.isinf(r_rev) or np.isinf(r_noise)):
            rand_deltas.append(float(r_noise - r_rev))

    if len(rev_deltas) < 5:
        return {"error": f"Too few scoreable {label} test windows: {len(rev_deltas)}"}

    delta_mean = float(np.mean(rev_deltas))
    delta_std  = float(np.std(rev_deltas))
    rand_delta_mean = float(np.mean(rand_deltas)) if rand_deltas else 0.0

    # One-sample t-test: is the mean delta significantly > 0?
    t_stat, p_value = ttest_1samp(rev_deltas, popmean=0.0, alternative="greater")

    # Also check reversal deltas are higher than random deltas (two-sample)
    t2, p2 = ttest_ind(rev_deltas, rand_deltas, alternative="greater") if rand_deltas else (0.0, 1.0)

    return {
        "label": label,
        "n_train": len(train_vecs),
        "n_test": len(test_vecs),
        "n_random": len(rand_vecs),
        "reversal_delta_mean": delta_mean,
        "reversal_delta_std": delta_std,
        "random_delta_mean": rand_delta_mean,
        "t_stat_vs_zero": float(t_stat),
        "p_value_vs_zero": float(p_value),
        "t_stat_vs_random": float(t2),
        "p_value_vs_random": float(p2),
        "passed": delta_mean > 0 and p_value < 0.05,
    }


# ---------------------------------------------------------------------------
# Engram minting from labeled reversals
# ---------------------------------------------------------------------------

def mint_reversal_engrams(
    df_ind: pd.DataFrame,
    encoder: OHLCVEncoder,
    peaks_ind: np.ndarray,
    troughs_ind: np.ndarray,
    hold_indices: np.ndarray,
    library: EngramLibrary,
) -> int:
    """Mint 1 thick BUY + 1 thick SELL + 1 thick HOLD engram.

    BUY/SELL engrams are trained on every encodable reversal window.
    HOLD engram is trained on a sample of non-reversal windows — the positive
    model of "normal, unremarkable market." Without it, HOLD is just
    "BUY and SELL both failed," which is a weak negative signal.

    peaks_ind / troughs_ind / hold_indices are positional indices into df_ind.
    """
    minted = 0
    for action, indices in [("BUY", troughs_ind), ("SELL", peaks_ind), ("HOLD", hold_indices)]:
        ss = StripedSubspace(dim=DIM, k=K, n_stripes=N_STRIPES)
        encoded = 0
        for idx in indices:
            v = encode_window(encoder, df_ind, int(idx))
            if v is not None:
                ss.update(v)
                encoded += 1

        if encoded < 10:
            print(f"  WARNING: only {encoded} encodable {action} windows, skipping", flush=True)
            continue

        engram_name = f"seed_{action.lower()}"
        library.add_striped(
            engram_name, ss, None,
            action=action, confidence=0.75,
            score=0.0, origin="labeled_reversal",
            n_training_samples=encoded,
        )
        minted += 1
        print(f"  {engram_name}: trained on {encoded} windows (n={ss.n})", flush=True)

    return minted


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="Label BTC reversals and validate geometry")
    parser.add_argument("--parquet", default="holon-lab-trading/data/btc_5m_raw.parquet")
    parser.add_argument("--prominence", type=float, default=PROMINENCE_PCT,
                        help="Min price move fraction for valid reversal (default 0.02 = 2%%)")
    parser.add_argument("--min-dist", type=int, default=MIN_DIST_BARS,
                        help="Min bars between peaks (default 12 = 1h)")
    parser.add_argument("--offset", type=int, default=LABEL_OFFSET,
                        help="Bars before reversal to place label (default 1)")
    parser.add_argument("--no-mint", action="store_true",
                        help="Skip engram minting (geometry test only)")
    parser.add_argument("--seed-end-year", type=int, default=2020,
                        help="Last year (inclusive) to use for seed engram training (default 2020)")
    args = parser.parse_args()

    # --- Load data ---
    print(f"Loading {args.parquet}...")
    df = pd.read_parquet(args.parquet)
    print(f"  {len(df)} candles | {df['ts'].iloc[0]} → {df['ts'].iloc[-1]}")
    print(f"  close range: ${df['close'].min():,.0f} – ${df['close'].max():,.0f}")

    # --- Determine seed-era slice for prominence anchoring ---
    ts_series = pd.to_datetime(df["ts"])
    seed_end = pd.Timestamp(f"{args.seed_end_year}-12-31 23:59:59")
    seed_mask = ts_series.values <= np.datetime64(seed_end)
    seed_slice = slice(0, int(np.sum(seed_mask)))
    seed_median_price = float(np.median(df["close"].values[seed_slice]))
    full_median_price = float(np.median(df["close"].values))
    print(f"Prominence anchor: seed-era median ${seed_median_price:,.0f} "
          f"(full-dataset median ${full_median_price:,.0f})")

    # --- Label reversals ---
    print("Labeling reversals...", flush=True)
    labeled_df, peaks, troughs = label_reversals(
        df,
        prominence_pct=args.prominence,
        min_dist=args.min_dist,
        offset=args.offset,
        price_ref_slice=seed_slice,
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

    # --- Precompute indicators once across the full dataset ---
    print("Precomputing indicators across full dataset (once)...", flush=True)
    df_ind = precompute_indicators(df)
    n_dropped = len(df) - len(df_ind)
    print(f"  {len(df_ind):,} rows with indicators ready ({n_dropped} NaN warmup rows dropped)")

    # Map raw df indices → df_ind positional indices (NaN warmup rows were dropped from the front)
    def to_ind_idx(raw_idx: np.ndarray) -> np.ndarray:
        shifted = raw_idx - n_dropped
        return shifted[shifted >= 0]

    peaks_ind = to_ind_idx(peaks)
    troughs_ind = to_ind_idx(troughs)

    # --- Geometry gate ---
    rng = np.random.default_rng(42)
    print("\n" + "=" * 60)
    print("  Geometry Gate: Are reversals algebraically separable?")
    print("=" * 60)

    results = {}
    for label, indices in [("BUY", troughs_ind), ("SELL", peaks_ind)]:
        print(f"\n[{label}] Testing {len(indices)} reversal windows...")
        r = geometry_gate(df_ind, encoder, indices, label, n_sample=150, rng=rng)
        results[label] = r
        if "error" in r:
            print(f"  ERROR: {r['error']}")
            continue
        status = "✓ PASS" if r["passed"] else "✗ FAIL"
        print(f"  [{status}] reversal_delta={r['reversal_delta_mean']:+.4f}±{r['reversal_delta_std']:.4f}  "
              f"random_delta={r['random_delta_mean']:+.4f}")
        print(f"           t(vs 0)={r['t_stat_vs_zero']:.2f}  p={r['p_value_vs_zero']:.4f}  "
              f"t(vs rand)={r['t_stat_vs_random']:.2f}  p={r['p_value_vs_random']:.4f}")
        print(f"           n_train={r['n_train']}  n_test={r['n_test']}  n_random={r['n_random']}")

    print("\n" + "=" * 60)
    all_passed = all(r.get("passed", False) for r in results.values() if "error" not in r)
    if all_passed:
        print("  ✓ GEOMETRY GATE PASSED — reversal windows are separable")
    else:
        print("  ✗ GEOMETRY GATE FAILED — reversal windows are NOT separable")
        print("    Consider: wider timeframe, larger prominence, longer window")
    print("=" * 60)

    # --- Mint seed engrams from labeled reversals (seed years only) ---
    if not args.no_mint and all_passed:
        # peaks/troughs are raw df indices; filter to seed range
        seed_peaks = peaks[ts_series.iloc[peaks].values <= np.datetime64(seed_end)]
        seed_troughs = troughs[ts_series.iloc[troughs].values <= np.datetime64(seed_end)]

        # Map to df_ind space
        seed_peaks_ind = to_ind_idx(seed_peaks)
        seed_troughs_ind = to_ind_idx(seed_troughs)

        seed_start_year = ts_series.iloc[0].year

        # Sample HOLD windows: non-reversal candles from the seed period
        reversal_set = set(seed_peaks_ind.tolist() + seed_troughs_ind.tolist())
        seed_end_idx_ind = int(np.searchsorted(
            ts_series.iloc[n_dropped:].values, np.datetime64(seed_end)
        ))
        all_seed_indices = [
            i for i in range(WINDOW_CANDLES, min(seed_end_idx_ind, len(df_ind)))
            if i not in reversal_set
        ]
        # Sample ~300 HOLD windows — enough for a thick manifold, proportional
        # to the reversal counts but representing the much larger normal class
        n_hold_samples = min(300, len(all_seed_indices))
        hold_indices = np.array(
            rng.choice(all_seed_indices, size=n_hold_samples, replace=False)
        )

        print(f"\nMinting seed engrams from {seed_start_year}-{args.seed_end_year}:")
        print(f"  {len(seed_troughs_ind)} BUY reversals, {len(seed_peaks_ind)} SELL reversals, {n_hold_samples} HOLD samples")

        library = EngramLibrary(dim=DIM)
        n_minted = mint_reversal_engrams(
            df_ind, encoder, seed_peaks_ind, seed_troughs_ind, hold_indices, library,
        )
        engram_path = "holon-lab-trading/data/seed_engrams.json"
        library.save(engram_path)
        print(f"\n  Minted {n_minted} engrams → {engram_path}")
        for name in library.names(kind="striped"):
            eng = library.get(name)
            n = eng._snapshot["stripes"][0].get("n", 0)
            print(f"    {name}: n={n} action={eng.metadata.get('action')}")

    elif not all_passed:
        print("\nSkipping engram minting — geometry gate failed.")
        print("The encoding does not show algebraic separation at this timescale/prominence.")


if __name__ == "__main__":
    main()
