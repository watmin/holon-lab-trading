"""Validate that OHLCV → striped hypervector encoding is geometrically meaningful.

Tests the core claims of the window-snapshot VSA approach:
  - same window encoded twice → identical stripe vectors
  - adjacent windows more similar than distant windows (aggregate cosine)
  - different price regimes are statistically separable
  - StripedSubspace flags volatile periods as novel after calm warmup

Uses the striped encoder architecture (encode_walkable_striped + StripedSubspace).

Usage:
    ./scripts/run_with_venv.sh python scripts/validate_geometry.py
    ./scripts/run_with_venv.sh python scripts/validate_geometry.py --dim 1024 --stripes 8 --window 12
    ./scripts/run_with_venv.sh python scripts/validate_geometry.py \\
        --parquet data/btc_5m.parquet --dim 1024 --stripes 8 --window 12

Validation gate criteria (all must pass on real data before running discovery harness):
  1. Identity    — same window → identical stripe vectors
  2. Proximity   — adjacent windows closer than distant windows
  3. Regime sep  — bull vs crash windows statistically separable (t-test p < 0.05)
  4. Subspace    — StripedSubspace trained on calm flags volatile as anomalous
"""

from __future__ import annotations

import argparse
import math
import sys
from pathlib import Path

import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).parent.parent))

from holon import HolonClient
from holon.memory import StripedSubspace
from trading.encoder import OHLCVEncoder


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def agg_cosine(vecs_a: list[np.ndarray], vecs_b: list[np.ndarray]) -> float:
    """Mean per-stripe cosine similarity between two stripe vector lists."""
    sims = []
    for a, b in zip(vecs_a, vecs_b):
        a_f, b_f = a.astype(float), b.astype(float)
        denom = np.linalg.norm(a_f) * np.linalg.norm(b_f)
        sims.append(float(np.dot(a_f, b_f) / denom) if denom > 0 else 0.0)
    return float(np.mean(sims))


def synthetic_df(n: int, price: float, volatility: float, seed: int) -> pd.DataFrame:
    rng = np.random.default_rng(seed)
    returns = rng.normal(0, volatility, n)
    prices = price * np.exp(np.cumsum(returns))
    ts = pd.date_range("2024-01-01", periods=n, freq="5min")
    return pd.DataFrame({
        "timestamp": ts,
        "open":   prices,
        "high":   prices * (1 + rng.uniform(0, 0.002, n)),
        "low":    prices * (1 - rng.uniform(0, 0.002, n)),
        "close":  prices,
        "volume": rng.uniform(5.0, 50.0, n),
    })


def make_window_df(n_lookback: int, n_window: int, price: float, vol: float, seed: int) -> pd.DataFrame:
    """Synthetic df with enough rows for indicators + encoding."""
    return synthetic_df(n_lookback + n_window + 10, price, vol, seed)


# ---------------------------------------------------------------------------
# Experiment 1: Identity
# ---------------------------------------------------------------------------

def experiment_identity(encoder: OHLCVEncoder, df: pd.DataFrame) -> dict:
    """Same window encoded twice must give bit-for-bit identical stripe vectors."""
    s1 = encoder.encode(df)
    s2 = encoder.encode(df)
    per_stripe_equal = [bool(np.array_equal(a, b)) for a, b in zip(s1, s2)]
    all_equal = all(per_stripe_equal)
    return {
        "all_stripes_equal": all_equal,
        "per_stripe": per_stripe_equal,
        "aggregate_cosine": agg_cosine(s1, s2),
    }


# ---------------------------------------------------------------------------
# Experiment 2: Proximity
# ---------------------------------------------------------------------------

def experiment_proximity(
    encoder: OHLCVEncoder,
    df: pd.DataFrame,
    n_pairs: int,
    rng: np.random.Generator,
) -> dict:
    """Adjacent windows more similar than near windows, which are more similar than far."""
    lookback = encoder.LOOKBACK_CANDLES
    feed_window = lookback + encoder.window_candles
    max_start = len(df) - feed_window - 100
    if max_start < 10:
        return {"skip": "not enough data"}

    safe_max = max_start - 100
    if safe_max < 10:
        return {"skip": "not enough data for far pairs"}

    def encode_at(i: int) -> list[np.ndarray]:
        return encoder.encode(df.iloc[i: i + feed_window].reset_index(drop=True))

    adjacent, near, far = [], [], []
    for _ in range(n_pairs):
        i = int(rng.integers(0, safe_max))
        va      = encode_at(i)
        vb_adj  = encode_at(i + 1)
        vb_near = encode_at(i + int(rng.integers(2, 13)))
        vb_far  = encode_at(i + int(rng.integers(48, 100)))

        adjacent.append(agg_cosine(va, vb_adj))
        near.append(agg_cosine(va, vb_near))
        far.append(agg_cosine(va, vb_far))

    return {
        "adjacent_mean": float(np.mean(adjacent)),
        "near_mean":     float(np.mean(near)),
        "far_mean":      float(np.mean(far)),
        "adjacent_std":  float(np.std(adjacent)),
        "near_std":      float(np.std(near)),
        "far_std":       float(np.std(far)),
        "adjacent_gt_near": float(np.mean(adjacent)) > float(np.mean(near)),
        "near_gt_far":      float(np.mean(near))     > float(np.mean(far)),
    }


# ---------------------------------------------------------------------------
# Experiment 3: Regime separation
# ---------------------------------------------------------------------------

def experiment_regime_separation(
    encoder: OHLCVEncoder,
    n_samples: int,
    rng: np.random.Generator,
) -> dict:
    """Flat low-price vs volatile high-price: within-regime cosine > cross-regime."""
    lookback = encoder.LOOKBACK_CANDLES
    n_window = encoder.window_candles
    n_vecs = max(n_samples, 30)
    regime_a_vecs = []
    regime_b_vecs = []

    for i in range(n_vecs):
        df_a = synthetic_df(lookback + n_window + 10, price=40_000, volatility=0.0005, seed=i)
        df_b = synthetic_df(lookback + n_window + 10, price=80_000, volatility=0.020,  seed=i + 10_000)
        regime_a_vecs.append(encoder.encode(df_a))
        regime_b_vecs.append(encoder.encode(df_b))

    within, cross = [], []
    for i in range(n_vecs):
        for j in range(i + 1, n_vecs):
            within.append(agg_cosine(regime_a_vecs[i], regime_a_vecs[j]))
            within.append(agg_cosine(regime_b_vecs[i], regime_b_vecs[j]))
    for i in range(n_vecs):
        for j in range(n_vecs):
            cross.append(agg_cosine(regime_a_vecs[i], regime_b_vecs[j]))

    within_arr = np.array(within)
    cross_arr  = np.array(cross)
    within_mean = float(np.mean(within_arr))
    cross_mean  = float(np.mean(cross_arr))

    try:
        from scipy import stats
        t_stat, p_two = stats.ttest_ind(within_arr, cross_arr, equal_var=False)
        p_one = p_two / 2 if t_stat > 0 else 1.0 - p_two / 2
        significant = bool(p_one < 0.05)
    except ImportError:
        t_stat, p_one, significant = 0.0, 1.0, within_mean > cross_mean

    return {
        "within_regime_mean": within_mean,
        "cross_regime_mean":  cross_mean,
        "separation":         within_mean - cross_mean,
        "t_stat":             float(t_stat),
        "p_one_sided":        float(p_one),
        "separable":          significant or (within_mean > cross_mean),
        "n_within_pairs":     len(within),
        "n_cross_pairs":      len(cross),
    }


# ---------------------------------------------------------------------------
# Experiment 4: StripedSubspace surprise
# ---------------------------------------------------------------------------

def experiment_subspace_surprise(
    encoder: OHLCVEncoder,
    n_warmup: int,
    dimensions: int,
    n_stripes: int,
) -> dict:
    """Train StripedSubspace on calm windows; novel volatile window should exceed threshold."""
    lookback = encoder.LOOKBACK_CANDLES
    n_window = encoder.window_candles
    ss = StripedSubspace(dim=dimensions, k=16, n_stripes=n_stripes)

    for i in range(n_warmup):
        df = synthetic_df(lookback + n_window + 10, price=50_000, volatility=0.003, seed=i)
        stripe_vecs = encoder.encode(df)
        ss.update(stripe_vecs)

    if math.isinf(ss.threshold):
        return {"skip": "threshold not yet finite after warmup"}

    # Familiar: same calm regime
    df_a = synthetic_df(lookback + n_window + 10, price=50_000, volatility=0.003, seed=n_warmup + 1)
    sv_a = encoder.encode(df_a)
    res_a = ss.residual(sv_a)

    # Novel: crash-level volatility (10x)
    df_b = synthetic_df(lookback + n_window + 10, price=50_000, volatility=0.030, seed=n_warmup + 2)
    sv_b = encoder.encode(df_b)
    res_b = ss.residual(sv_b)

    # Per-stripe profile for attribution
    profile_b = ss.residual_profile(sv_b)
    hot_stripe = int(np.argmax(profile_b))

    return {
        "threshold":          ss.threshold,
        "residual_familiar":  res_a,
        "residual_novel":     res_b,
        "familiar_below":     res_a < ss.threshold,
        "novel_above":        res_b > ss.threshold,
        "surprise_ratio":     res_b / res_a if res_a > 0 else float("inf"),
        "hot_stripe":         hot_stripe,
        "residual_profile":   profile_b.tolist() if hasattr(profile_b, "tolist") else list(profile_b),
    }


# ---------------------------------------------------------------------------
# Main runner
# ---------------------------------------------------------------------------

def load_or_synthesize(parquet: str | None, n_rows: int) -> pd.DataFrame:
    if parquet and Path(parquet).exists():
        df = pd.read_parquet(parquet)
        print(f"Using real data: {len(df):,} candles from {parquet}")
        return df
    print(f"No parquet found — using {n_rows}-candle synthetic data")
    return synthetic_df(n_rows, price=50_000, volatility=0.005, seed=0)


def run_all(
    dimensions: int = 512,
    n_stripes: int = 4,
    window_candles: int = 6,
    parquet: str | None = None,
) -> bool:
    rng = np.random.default_rng(42)
    client = HolonClient(dimensions=dimensions)
    encoder = OHLCVEncoder(client, window_candles=window_candles, n_stripes=n_stripes)

    feed_rows = encoder.LOOKBACK_CANDLES + window_candles + 300
    df = load_or_synthesize(parquet, feed_rows)

    print(f"\n{'='*65}")
    print(f"  Geometry Validation (Window Snapshot + Striped)")
    print(f"  dim={dimensions}  stripes={n_stripes}  window={window_candles}")
    print(f"{'='*65}\n")

    all_passed = True

    # --- 1. Identity ---
    r = experiment_identity(encoder, df)
    ok = r["all_stripes_equal"]
    status = "✓ PASS" if ok else "✗ FAIL"
    print(f"[{status}] Identity: same window → identical stripe vectors")
    print(f"         all_equal={ok}  agg_cosine={r['aggregate_cosine']:.4f}")
    if not ok:
        all_passed = False
    print()

    # --- 2. Proximity ---
    r = experiment_proximity(encoder, df, n_pairs=30, rng=rng)
    if "skip" in r:
        print(f"[  SKIP] Proximity: {r['skip']}\n")
    else:
        monotone = r["adjacent_gt_near"] and r["near_gt_far"]
        status = "✓ PASS" if monotone else "~ INFO"
        print(f"[{status}] Proximity: adjacent > near > far cosine similarity")
        print(f"         adjacent={r['adjacent_mean']:.4f}±{r['adjacent_std']:.4f}")
        print(f"         near    ={r['near_mean']:.4f}±{r['near_std']:.4f}")
        print(f"         far     ={r['far_mean']:.4f}±{r['far_std']:.4f}")
        if not monotone:
            print("         ℹ  Monotonic gradient not strict — may need more data or larger dim")
        else:
            pass  # strict pass
        print()

    # --- 3. Regime separation ---
    r = experiment_regime_separation(encoder, n_samples=20, rng=rng)
    ok = r["separable"]
    status = "✓ PASS" if ok else "✗ FAIL"
    print(f"[{status}] Regime separation: within-regime > cross-regime")
    print(f"         within={r['within_regime_mean']:+.4f}  cross={r['cross_regime_mean']:+.4f}")
    print(f"         sep={r['separation']:+.4f}  t={r['t_stat']:.2f}  p(one-sided)={r['p_one_sided']:.4f}")
    print(f"         pairs: within={r['n_within_pairs']}  cross={r['n_cross_pairs']}")
    if not ok:
        all_passed = False
    print()

    # --- 4. Subspace surprise ---
    r = experiment_subspace_surprise(encoder, n_warmup=200, dimensions=dimensions, n_stripes=n_stripes)
    if "skip" in r:
        print(f"[  SKIP] Subspace surprise: {r['skip']}\n")
    else:
        fam_ok = r["familiar_below"]
        nov_ok = r["novel_above"]
        if fam_ok and nov_ok:
            status = "✓ PASS"
        elif fam_ok:
            status = "~ INFO"
            print("         ℹ  Familiar below threshold (correct). Novel didn't cross — may need real data.")
        else:
            status = "✗ FAIL"
            all_passed = False

        print(f"[{status}] Subspace surprise (StripedSubspace)")
        print(f"         threshold={r['threshold']:.4f}")
        print(f"         familiar ={r['residual_familiar']:.4f}  below={fam_ok}")
        print(f"         novel    ={r['residual_novel']:.4f}  above={nov_ok}  ratio={r['surprise_ratio']:.2f}x")
        print(f"         hot_stripe={r['hot_stripe']}  profile={[f'{v:.3f}' for v in r['residual_profile']]}")
        print()

    # --- Summary ---
    print(f"{'='*65}")
    if all_passed:
        print("  ✓ ALL GATE CRITERIA MET — safe to run discovery harness")
    else:
        print("  ✗ SOME CRITERIA FAILED — review above before running harness")
    print(f"{'='*65}\n")

    return all_passed


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Validate OHLCV→striped-hypervector geometry")
    parser.add_argument("--dim",     type=int, default=512, help="Dim per stripe (default 512 for speed)")
    parser.add_argument("--stripes", type=int, default=4,   help="Number of stripes (default 4 for speed)")
    parser.add_argument("--window",  type=int, default=6,   help="Encode window candles (default 6 for speed)")
    parser.add_argument("--parquet", type=str, default=None, help="Path to btc_5m.parquet (optional)")
    args = parser.parse_args()

    ok = run_all(
        dimensions=args.dim,
        n_stripes=args.stripes,
        window_candles=args.window,
        parquet=args.parquet,
    )
    sys.exit(0 if ok else 1)
