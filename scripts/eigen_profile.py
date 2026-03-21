#!/usr/bin/env python
"""eigen_profile.py — Find the intrinsic dimensionality of pixel-encoded vectors.

Encodes N vectors, feeds them into OnlineSubspace with high k,
and prints the eigenvalue spectrum to find the plateau.
"""

from __future__ import annotations

import multiprocessing as mp
import sqlite3
import sys
import time
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent.parent))
from holon import DeterministicVectorManager, Encoder
sys.path.insert(0, str(Path(__file__).parent))
from categorical_refine import build_pixel_data, ALL_DB_COLS

DB_PATH = Path(__file__).parent.parent / "data" / "analysis.db"


def sf(v):
    return 0.0 if v is None else float(v)


_g_candles = None
_g_window = None
_g_dim = None
_g_stripes = None
_g_encoder = None


def _worker_init():
    global _g_encoder
    _g_encoder = Encoder(DeterministicVectorManager(dimensions=_g_dim))


def _worker_encode(idx):
    data = build_pixel_data(_g_candles, idx, _g_window)
    stripe_list = _g_encoder.encode_walkable_striped(data, _g_stripes)
    return idx, np.stack(stripe_list)


def main():
    global _g_candles, _g_window, _g_dim, _g_stripes

    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("--window", type=int, default=48)
    parser.add_argument("--dims", type=int, default=4096)
    parser.add_argument("--stripes", type=int, default=64)
    parser.add_argument("--max-k", type=int, default=256,
                        help="Max PCA components to profile")
    parser.add_argument("--n-samples", type=int, default=500)
    parser.add_argument("--workers", type=int, default=4)
    parser.add_argument("--vol-threshold", type=float, default=0.002)
    parser.add_argument("--label", default="label_oracle_10")
    args = parser.parse_args()

    print(f"Eigenvalue profiler: {args.stripes} stripes x {args.dims}D, "
          f"window={args.window}, max_k={args.max_k}", flush=True)

    conn = sqlite3.connect(str(DB_PATH))
    seen = set()
    cols = []
    for c in ALL_DB_COLS + [args.label]:
        if c not in seen:
            cols.append(c)
            seen.add(c)
    rows = conn.execute(
        f"SELECT {', '.join(cols)} FROM candles ORDER BY ts"
    ).fetchall()
    conn.close()
    candles = [{cols[j]: r[j] for j in range(len(cols))} for r in rows]
    print(f"Loaded {len(candles):,} candles", flush=True)

    # Pick volatile labeled candles from 2019-2020
    candidates = []
    for i in range(args.window - 1, len(candles)):
        atr_r = candles[i].get("atr_r") or 0
        year = candles[i].get("year")
        lbl = candles[i].get(args.label)
        if atr_r > args.vol_threshold and year in (2019, 2020) and lbl in ("BUY", "SELL"):
            candidates.append((i, lbl))

    np.random.seed(42)
    if len(candidates) > args.n_samples:
        idx = np.random.choice(len(candidates), args.n_samples, replace=False)
        idx.sort()
        candidates = [candidates[i] for i in idx]
    print(f"Encoding {len(candidates)} samples...", flush=True)

    _g_candles = candles
    _g_window = args.window
    _g_dim = args.dims
    _g_stripes = args.stripes

    t0 = time.time()
    with mp.Pool(args.workers, initializer=_worker_init) as pool:
        results = list(pool.imap_unordered(
            _worker_encode, [i for i, _ in candidates], chunksize=20
        ))
    vec_cache = dict(results)
    print(f"Encoded in {time.time() - t0:.1f}s\n", flush=True)

    # Profile per-stripe eigenvalues using batch SVD (much faster)
    max_k = min(args.max_k, args.dims - 1, len(candidates) - 1)
    print(f"Computing SVD per stripe (max_k={max_k})...", flush=True)

    # Build per-stripe matrices
    n = len(candidates)
    stripe_matrices = [np.empty((n, args.dims), dtype=np.float64)
                       for _ in range(args.stripes)]

    for row_idx, (ci, lbl) in enumerate(candidates):
        arr = vec_cache[ci]
        for s in range(args.stripes):
            stripe_matrices[s][row_idx] = arr[s].astype(np.float64)

    print("  Computing covariance eigenvalues...", flush=True)

    all_eigs = []
    for s in range(args.stripes):
        X = stripe_matrices[s]
        X = X - X.mean(axis=0, keepdims=True)
        # Gram matrix approach (n×n) is faster when n << d
        G = X @ X.T / (n - 1)
        eigs = np.linalg.eigvalsh(G)
        eigs = np.sort(eigs)[::-1][:max_k]
        eigs = np.maximum(eigs, 0)
        all_eigs.append(eigs)
        if (s + 1) % 16 == 0:
            print(f"    stripe {s+1}/{args.stripes} done", flush=True)

    print(f"\n{'='*70}")
    print(f"EIGENVALUE SPECTRUM (averaged across {args.stripes} stripes)")
    print(f"{'='*70}\n")

    avg_eigs = np.mean(all_eigs, axis=0)
    total_var = np.sum(avg_eigs)
    cum_var = np.cumsum(avg_eigs) / total_var * 100

    knee_90 = int(np.searchsorted(cum_var, 90) + 1)
    knee_95 = int(np.searchsorted(cum_var, 95) + 1)
    knee_99 = int(np.searchsorted(cum_var, 99) + 1)

    print(f"  Total variance: {total_var:.2f}")
    print(f"  Knee points:")
    print(f"    90% variance at k={knee_90}")
    print(f"    95% variance at k={knee_95}")
    print(f"    99% variance at k={knee_99}")
    print(f"  Top eigenvalue share: {avg_eigs[0]/total_var*100:.1f}%")
    print(f"  Top-5 share: {np.sum(avg_eigs[:5])/total_var*100:.1f}%")
    print(f"  Top-10 share: {np.sum(avg_eigs[:10])/total_var*100:.1f}%")
    print(f"  Top-32 share: {np.sum(avg_eigs[:32])/total_var*100:.1f}%")
    print(f"  Top-64 share: {np.sum(avg_eigs[:64])/total_var*100:.1f}%")
    if max_k >= 128:
        print(f"  Top-128 share: {np.sum(avg_eigs[:128])/total_var*100:.1f}%")

    print(f"\n  Eigenvalue spectrum (first {min(120, len(avg_eigs))}):")
    print(f"  {'k':>5s} {'eigenval':>10s} {'%var':>7s} {'cum%':>7s} {'bar'}")
    for i in range(min(120, len(avg_eigs))):
        pct = avg_eigs[i] / total_var * 100
        bar = "█" * max(1, int(pct * 2))
        marker = ""
        if i + 1 == knee_90:
            marker = " ← 90%"
        elif i + 1 == knee_95:
            marker = " ← 95%"
        elif i + 1 == knee_99:
            marker = " ← 99%"
        print(f"  {i+1:>5d} {avg_eigs[i]:>10.4f} {pct:>6.2f}% {cum_var[i]:>6.1f}% {bar}{marker}")

    # Per-stripe variation
    print(f"\n  Per-stripe knee points (90% variance):")
    stripe_knees = []
    for s in range(args.stripes):
        eigs = np.sort(all_eigs[s])[::-1]
        cv = np.cumsum(eigs) / np.sum(eigs) * 100
        sk = int(np.searchsorted(cv, 90) + 1)
        stripe_knees.append(sk)
    print(f"    min={min(stripe_knees)}, max={max(stripe_knees)}, "
          f"mean={np.mean(stripe_knees):.1f}, median={np.median(stripe_knees):.0f}")

    # BUY vs SELL comparison
    print(f"\n{'='*70}")
    print(f"BUY vs SELL EIGENVALUE COMPARISON")
    print(f"{'='*70}\n")

    buy_indices = [i for i, (_, lbl) in enumerate(candidates) if lbl == "BUY"]
    sell_indices = [i for i, (_, lbl) in enumerate(candidates) if lbl == "SELL"]
    print(f"  BUY samples: {len(buy_indices)}, SELL samples: {len(sell_indices)}")

    buy_knees_90 = []
    sell_knees_90 = []
    for s in range(args.stripes):
        for indices, knees in [(buy_indices, buy_knees_90),
                               (sell_indices, sell_knees_90)]:
            X = stripe_matrices[s][indices]
            X = X - X.mean(axis=0, keepdims=True)
            G = X @ X.T / (len(indices) - 1)
            eigs = np.linalg.eigvalsh(G)
            eigs = np.sort(np.maximum(eigs, 0))[::-1]
            cv = np.cumsum(eigs) / np.sum(eigs) * 100
            knees.append(int(np.searchsorted(cv, 90) + 1))

    print(f"  BUY 90% knee:  min={min(buy_knees_90)}, max={max(buy_knees_90)}, "
          f"mean={np.mean(buy_knees_90):.1f}")
    print(f"  SELL 90% knee: min={min(sell_knees_90)}, max={max(sell_knees_90)}, "
          f"mean={np.mean(sell_knees_90):.1f}")

    # Also profile the FLAT (concatenated) vector
    print(f"\n{'='*70}")
    print(f"FLAT VECTOR EIGENVALUE SPECTRUM")
    print(f"{'='*70}\n")

    flat_dim = args.stripes * args.dims
    print(f"  Flat dimension: {flat_dim:,}")
    flat_X = np.empty((n, flat_dim), dtype=np.float64)
    for row_idx, (ci, lbl) in enumerate(candidates):
        arr = vec_cache[ci]
        flat_X[row_idx] = arr.flatten().astype(np.float64)

    flat_X = flat_X - flat_X.mean(axis=0, keepdims=True)
    G = flat_X @ flat_X.T / (n - 1)
    flat_eigs = np.linalg.eigvalsh(G)
    flat_eigs = np.sort(np.maximum(flat_eigs, 0))[::-1]
    flat_total = np.sum(flat_eigs)
    flat_cum = np.cumsum(flat_eigs) / flat_total * 100

    fk90 = int(np.searchsorted(flat_cum, 90) + 1)
    fk95 = int(np.searchsorted(flat_cum, 95) + 1)
    fk99 = int(np.searchsorted(flat_cum, 99) + 1)

    print(f"  Flat knee points:")
    print(f"    90% variance at k={fk90}")
    print(f"    95% variance at k={fk95}")
    print(f"    99% variance at k={fk99}")
    print(f"  Top-1 share: {flat_eigs[0]/flat_total*100:.1f}%")
    print(f"  Top-10 share: {np.sum(flat_eigs[:10])/flat_total*100:.1f}%")
    print(f"  Top-32 share: {np.sum(flat_eigs[:32])/flat_total*100:.1f}%")
    print(f"  Top-64 share: {np.sum(flat_eigs[:64])/flat_total*100:.1f}%")
    print(f"  Top-128 share: {np.sum(flat_eigs[:128])/flat_total*100:.1f}%")

    print(f"\n  Recommendation:")
    rec_k = int(np.ceil(np.mean(stripe_knees) * 1.2))
    print(f"    Per-stripe: 90% knee avg={np.mean(stripe_knees):.1f} → recommended k={rec_k}")
    print(f"    Flat: 90% knee={fk90}, 95%={fk95}, 99%={fk99}")
    print(f"    Current k=4/8 is {'UNDER' if rec_k > 8 else 'OK'}")


if __name__ == "__main__":
    main()
