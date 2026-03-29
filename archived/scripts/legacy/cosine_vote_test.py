"""Cosine-vote classifier: per-stripe "which mean am I closer to?"

Instead of discriminant projection, classify by comparing cosine similarity
to BUY mean vs SELL mean independently per stripe, then vote.

This tests whether the 85% accuracy seen on 20 samples holds up at scale.
"""

from __future__ import annotations

import argparse
import multiprocessing as mp
import sqlite3
import sys
import time
from pathlib import Path
from typing import Dict, List

import numpy as np

sys.path.insert(0, str(Path(__file__).parent.parent))

from holon import (
    DeterministicVectorManager,
    Encoder,
    StripedSubspace,
    cosine_similarity,
)

sys.path.insert(0, str(Path(__file__).parent))
from categorical_refine import (
    build_categorical_data,
    compute_actual,
    ALL_DB_COLS,
)

DB_PATH = Path(__file__).parent.parent / "data" / "analysis.db"
SUPERVISED_YEARS = {2019, 2020}


def log(msg: str):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


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
    data = build_categorical_data(_g_candles, idx, _g_window)
    stripe_list = _g_encoder.encode_walkable_striped(data, _g_stripes)
    return idx, np.stack(stripe_list)


def classify_cosine_vote(stripe_vecs, buy_means, sell_means, n_stripes):
    """Per-stripe cosine vote: which class mean is this sample closer to?"""
    buy_score = 0.0
    sell_score = 0.0
    for s in range(n_stripes):
        vec = stripe_vecs[s].astype(np.float64)
        cb = cosine_similarity(vec, buy_means[s])
        cs = cosine_similarity(vec, sell_means[s])
        if cb > cs:
            buy_score += (cb - cs)
        else:
            sell_score += (cs - cb)
    return "BUY" if buy_score > sell_score else "SELL"


def classify_cosine_sum(stripe_vecs, buy_means, sell_means, n_stripes):
    """Sum of cosine differences across stripes."""
    total = 0.0
    for s in range(n_stripes):
        vec = stripe_vecs[s].astype(np.float64)
        cb = cosine_similarity(vec, buy_means[s])
        cs = cosine_similarity(vec, sell_means[s])
        total += (cb - cs)
    return "BUY" if total > 0 else "SELL"


def classify_cosine_majority(stripe_vecs, buy_means, sell_means, n_stripes):
    """Majority vote: each stripe votes BUY or SELL independently."""
    buy_votes = 0
    sell_votes = 0
    for s in range(n_stripes):
        vec = stripe_vecs[s].astype(np.float64)
        cb = cosine_similarity(vec, buy_means[s])
        cs = cosine_similarity(vec, sell_means[s])
        if cb > cs:
            buy_votes += 1
        else:
            sell_votes += 1
    return "BUY" if buy_votes > sell_votes else "SELL"


CLASSIFIERS = {
    "cosine_sum": classify_cosine_sum,
    "cosine_weighted_vote": classify_cosine_vote,
    "cosine_majority": classify_cosine_majority,
}


def main():
    global _g_candles, _g_window, _g_dim, _g_stripes

    parser = argparse.ArgumentParser()
    parser.add_argument("--n", type=int, default=5000)
    parser.add_argument("--label", default="label_oracle_10")
    parser.add_argument("--vol-threshold", type=float, default=0.002)
    parser.add_argument("--window", type=int, default=48)
    parser.add_argument("--dims", type=int, default=1024)
    parser.add_argument("--stripes", type=int, default=16)
    parser.add_argument("--k", type=int, default=20)
    parser.add_argument("--workers", type=int, default=6)
    args = parser.parse_args()

    log("=" * 80)
    log("COSINE VOTE CLASSIFIER TEST")
    log(f"  Categorical encoding, {args.stripes} stripes × {args.dims}D")
    log("=" * 80)

    conn = sqlite3.connect(str(DB_PATH))
    seen = set()
    cols = []
    for c in ALL_DB_COLS + [args.label]:
        if c not in seen:
            cols.append(c)
            seen.add(c)
    all_rows = conn.execute(
        f"SELECT {', '.join(cols)} FROM candles ORDER BY ts"
    ).fetchall()
    conn.close()
    candles = [{cols[j]: r[j] for j in range(len(cols))} for r in all_rows]
    log(f"Loaded {len(candles):,} candles")

    sup_all, adp_all = [], []
    for i in range(args.window - 1, len(candles)):
        atr_r = candles[i].get("atr_r") or 0
        if atr_r <= args.vol_threshold:
            continue
        year = candles[i].get("year")
        if year in SUPERVISED_YEARS:
            sup_all.append(i)
        else:
            adp_all.append(i)

    np.random.seed(42)
    n = args.n
    sup_sample = sorted(np.random.choice(
        sup_all, size=min(n, len(sup_all)), replace=False
    ).tolist())
    adp_sample = sorted(np.random.choice(
        adp_all, size=min(n, len(adp_all)), replace=False
    ).tolist())
    all_to_encode = sup_sample + adp_sample
    log(f"Sample: {len(sup_sample):,} supervised + "
        f"{len(adp_sample):,} adaptive = {len(all_to_encode):,}")

    _g_candles = candles
    _g_window = args.window
    _g_dim = args.dims
    _g_stripes = args.stripes

    log(f"Encoding ({args.workers} workers) ...")
    t_enc = time.time()
    with mp.Pool(args.workers, initializer=_worker_init) as pool:
        results = []
        done = 0
        for result in pool.imap_unordered(
            _worker_encode, all_to_encode, chunksize=50
        ):
            results.append(result)
            done += 1
            if done % 2000 == 0:
                elapsed = time.time() - t_enc
                rate = done / elapsed
                remaining = len(all_to_encode) - done
                log(f"  {done:,}/{len(all_to_encode):,} ({rate:.0f}/s)")

    vec_cache = dict(results)
    log(f"Encoded {len(vec_cache):,} in {time.time() - t_enc:.1f}s")

    # Build labels
    labels: Dict[int, str] = {}
    for idx in sorted(vec_cache.keys()):
        atr_r = candles[idx].get("atr_r") or 0
        if atr_r <= args.vol_threshold:
            continue
        year = candles[idx].get("year")
        if year in SUPERVISED_YEARS:
            oracle = candles[idx].get(args.label)
            if oracle in ("BUY", "SELL"):
                labels[idx] = oracle
            else:
                labels[idx] = compute_actual(candles, idx)
        else:
            labels[idx] = compute_actual(candles, idx)

    # Train: use subspace means from supervised BUY/SELL
    n_stripes = args.stripes
    dim = args.dims

    # Simple mean accumulation (no subspace needed for cosine voting)
    buy_sums = [np.zeros(dim, dtype=np.float64) for _ in range(n_stripes)]
    sell_sums = [np.zeros(dim, dtype=np.float64) for _ in range(n_stripes)]
    buy_count = sell_count = 0

    for idx in sup_sample:
        lbl = labels.get(idx)
        if lbl not in ("BUY", "SELL"):
            continue
        arr = vec_cache[idx].astype(np.float64)
        if lbl == "BUY":
            for s in range(n_stripes):
                buy_sums[s] += arr[s]
            buy_count += 1
        else:
            for s in range(n_stripes):
                sell_sums[s] += arr[s]
            sell_count += 1

    buy_means = [buy_sums[s] / buy_count for s in range(n_stripes)]
    sell_means = [sell_sums[s] / sell_count for s in range(n_stripes)]

    log(f"\nTrained on {buy_count} BUY + {sell_count} SELL supervised")

    mean_cos = np.mean([
        cosine_similarity(buy_means[s], sell_means[s])
        for s in range(n_stripes)
    ])
    log(f"Mean cosine(buy_mean, sell_mean): {mean_cos:.4f}")

    # Test all classifiers
    for clf_name, clf_fn in CLASSIFIERS.items():
        log(f"\n{'='*60}")
        log(f"Classifier: {clf_name}")
        log(f"{'='*60}")

        for split_name, indices in [("IN-SAMPLE (2019-2020)", sup_sample),
                                     ("OOS (2021+)", adp_sample)]:
            correct = wrong = bc = sc = 0
            by_year: Dict[int, List[bool]] = {}

            for idx in indices:
                actual = labels.get(idx)
                if actual not in ("BUY", "SELL"):
                    continue
                arr = vec_cache[idx]
                svecs = [arr[s] for s in range(n_stripes)]
                pred = clf_fn(svecs, buy_means, sell_means, n_stripes)

                year = candles[idx].get("year")
                by_year.setdefault(year, []).append(pred == actual)

                if pred == actual:
                    correct += 1
                    if actual == "BUY":
                        bc += 1
                    else:
                        sc += 1
                else:
                    wrong += 1

            total = correct + wrong
            acc = correct / total * 100 if total > 0 else 0
            log(f"\n  {split_name}: {acc:.1f}% ({correct}/{total})")
            log(f"    BUY correct: {bc}, SELL correct: {sc}")

            for year in sorted(by_year.keys()):
                yr_results = by_year[year]
                yr_acc = sum(yr_results) / len(yr_results) * 100
                marker = " *" if year in SUPERVISED_YEARS else ""
                log(f"    {year}: {yr_acc:5.1f}% ({len(yr_results):,}){marker}")

    # Also test with subspace-trained means for comparison
    log(f"\n{'='*60}")
    log("SUBSPACE MEANS (CCIPCA K=20) vs SIMPLE MEANS")
    log(f"{'='*60}")

    buy_sub = StripedSubspace(dim=dim, k=args.k, n_stripes=n_stripes)
    sell_sub = StripedSubspace(dim=dim, k=args.k, n_stripes=n_stripes)

    for idx in sup_sample:
        lbl = labels.get(idx)
        if lbl not in ("BUY", "SELL"):
            continue
        arr = vec_cache[idx]
        svecs = [arr[s] for s in range(n_stripes)]
        if lbl == "BUY":
            buy_sub.update(svecs)
        else:
            sell_sub.update(svecs)

    sub_buy_means = [buy_sub._stripes[s].mean.copy() for s in range(n_stripes)]
    sub_sell_means = [sell_sub._stripes[s].mean.copy() for s in range(n_stripes)]

    sub_cos = np.mean([
        cosine_similarity(sub_buy_means[s], sub_sell_means[s])
        for s in range(n_stripes)
    ])
    log(f"Subspace mean cosine(buy, sell): {sub_cos:.4f}")

    clf_fn = classify_cosine_sum
    for split_name, indices in [("IN-SAMPLE", sup_sample),
                                 ("OOS", adp_sample)]:
        correct = wrong = 0
        for idx in indices:
            actual = labels.get(idx)
            if actual not in ("BUY", "SELL"):
                continue
            arr = vec_cache[idx]
            svecs = [arr[s] for s in range(n_stripes)]
            pred = clf_fn(svecs, sub_buy_means, sub_sell_means, n_stripes)
            if pred == actual:
                correct += 1
            else:
                wrong += 1
        total = correct + wrong
        acc = correct / total * 100 if total > 0 else 0
        log(f"  {split_name} (subspace means + cosine_sum): {acc:.1f}% ({correct}/{total})")


if __name__ == "__main__":
    main()
