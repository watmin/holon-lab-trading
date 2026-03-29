#!/usr/bin/env python
"""engram_knn.py — Does local vector similarity predict BUY/SELL?

Tests the "massive library" hypothesis: instead of smoothing all examples
into prototypes or subspaces, store individual vectors and find nearest
neighbors. If local neighborhoods in Holon's vector space have label
coherence, k-NN will outperform prototype matching (~52%).

Supports two encoding modes:
  - categorical: per-candle facts (RSI="oversold", price above SMA20, etc.)
  - visual: spatial grid positions on a virtual monitor + shape descriptors

Three classifiers tested:
  1. Prototype baseline: cosine similarity to BUY vs SELL class means
  2. k-NN voting: find k nearest training vectors, majority vote
  3. Engram library: group training vectors into micro-subspaces, vote

Usage:
    ./scripts/run_with_venv.sh python holon-lab-trading/scripts/engram_knn.py \\
        --encoding visual --n-train 10000 --n-test 5000 --workers 6
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
from holon.memory.engram import EngramLibrary

sys.path.insert(0, str(Path(__file__).parent))
from categorical_refine import (
    build_categorical_data,
    build_monitor_data,
    build_pixel_data,
    compute_actual,
    ALL_DB_COLS,
)

DB_PATH = Path(__file__).parent.parent / "data" / "analysis.db"
SUPERVISED_YEARS = {2019, 2020}
PANEL_NAMES = ["price", "vol", "rsi", "macd"]
DEFAULT_PANEL_STRIPES = {"price": 16, "vol": 16, "rsi": 8, "macd": 16}


def log(msg: str):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def sf(v):
    return 0.0 if v is None else float(v)


_g_candles = None
_g_window = None
_g_dim = None
_g_stripes = None
_g_encoder = None
_g_encoding = None
_g_panel_stripes = None


def _worker_init():
    global _g_encoder
    _g_encoder = Encoder(DeterministicVectorManager(dimensions=_g_dim))


def _worker_encode(idx):
    if _g_encoding == "pixel":
        data = build_pixel_data(_g_candles, idx, _g_window)
    elif _g_encoding == "visual":
        data = build_monitor_data(_g_candles, idx, _g_window)
    else:
        data = build_categorical_data(_g_candles, idx, _g_window)
    stripe_list = _g_encoder.encode_walkable_striped(data, _g_stripes)
    return idx, np.stack(stripe_list)


def _worker_encode_panels(idx):
    panels = build_pixel_data(_g_candles, idx, _g_window)
    result = {}
    for pname in PANEL_NAMES:
        ns = _g_panel_stripes[pname]
        stripe_list = _g_encoder.encode_walkable_striped(panels[pname], ns)
        result[pname] = np.stack(stripe_list)
    return idx, result


def knn_classify_batch(test_flat, train_flat, train_labels, k_values):
    """Batch k-NN via matrix cosine similarity."""
    test_norms = np.linalg.norm(test_flat, axis=1, keepdims=True)
    train_norms = np.linalg.norm(train_flat, axis=1, keepdims=True)
    test_norms[test_norms == 0] = 1.0
    train_norms[train_norms == 0] = 1.0
    test_normed = test_flat / test_norms
    train_normed = train_flat / train_norms

    max_k = max(k_values)
    results = {k: [] for k in k_values}

    chunk_size = 500
    n_test = test_normed.shape[0]
    n_chunks = (n_test + chunk_size - 1) // chunk_size

    for ci, start in enumerate(range(0, n_test, chunk_size)):
        end = min(start + chunk_size, n_test)
        chunk = test_normed[start:end]

        sim_matrix = chunk @ train_normed.T

        top_k_indices = np.argpartition(sim_matrix, -max_k, axis=1)[:, -max_k:]

        for i in range(end - start):
            top_k_sims = sim_matrix[i, top_k_indices[i]]
            sorted_order = np.argsort(-top_k_sims)
            sorted_indices = top_k_indices[i][sorted_order]

            for k in k_values:
                neighbors = sorted_indices[:k]
                buy_votes = sum(1 for ni in neighbors if train_labels[ni] == "BUY")
                results[k].append("BUY" if buy_votes > k // 2 else "SELL")

        if (ci + 1) % 5 == 0 or ci == n_chunks - 1:
            log(f"    chunk {ci+1}/{n_chunks}")

    return results


def knn_classify_with_scores(test_flat, train_flat, train_labels, k_values):
    """Batch k-NN returning predictions AND per-label similarity scores."""
    test_norms = np.linalg.norm(test_flat, axis=1, keepdims=True)
    train_norms = np.linalg.norm(train_flat, axis=1, keepdims=True)
    test_norms[test_norms == 0] = 1.0
    train_norms[train_norms == 0] = 1.0
    test_normed = test_flat / test_norms
    train_normed = train_flat / train_norms

    max_k = max(k_values)
    preds = {k: [] for k in k_values}
    buy_scores = {k: [] for k in k_values}
    sell_scores = {k: [] for k in k_values}

    chunk_size = 500
    n_test = test_normed.shape[0]

    for start in range(0, n_test, chunk_size):
        end = min(start + chunk_size, n_test)
        chunk = test_normed[start:end]
        sim_matrix = chunk @ train_normed.T
        top_k_indices = np.argpartition(sim_matrix, -max_k, axis=1)[:, -max_k:]

        for i in range(end - start):
            top_k_sims = sim_matrix[i, top_k_indices[i]]
            sorted_order = np.argsort(-top_k_sims)
            sorted_indices = top_k_indices[i][sorted_order]
            sorted_sims = top_k_sims[sorted_order]

            for k in k_values:
                nb = sorted_indices[:k]
                sm = sorted_sims[:k]
                b_s = 0.0
                s_s = 0.0
                b_c = 0
                for j in range(k):
                    if train_labels[nb[j]] == "BUY":
                        b_s += sm[j]
                        b_c += 1
                    else:
                        s_s += sm[j]
                preds[k].append("BUY" if b_c > k // 2 else "SELL")
                buy_scores[k].append(float(b_s))
                sell_scores[k].append(float(s_s))

    for k in k_values:
        buy_scores[k] = np.array(buy_scores[k], dtype=np.float32)
        sell_scores[k] = np.array(sell_scores[k], dtype=np.float32)

    return preds, buy_scores, sell_scores


def _run_panel_knn(args, candles, train_sample, test_sample):
    """Per-panel pixel k-NN: encode each panel independently, classify, combine."""
    global _g_candles, _g_window, _g_dim, _g_panel_stripes, _g_encoding

    _g_candles = candles
    _g_window = args.window
    _g_dim = args.dims
    _g_panel_stripes = DEFAULT_PANEL_STRIPES
    _g_encoding = "pixel-panel"

    panel_stripes_str = ", ".join(
        f"{p}={s}" for p, s in DEFAULT_PANEL_STRIPES.items()
    )
    log(f"Per-panel stripes: {panel_stripes_str}")

    all_to_encode = train_sample + test_sample
    log(f"Encoding {len(all_to_encode):,} vectors "
        f"(pixel-panel, {args.workers} workers)...")
    t_enc = time.time()
    with mp.Pool(args.workers, initializer=_worker_init) as pool:
        results = []
        done = 0
        for result in pool.imap_unordered(
            _worker_encode_panels, all_to_encode, chunksize=50
        ):
            results.append(result)
            done += 1
            if done % 2000 == 0:
                elapsed = time.time() - t_enc
                rate = done / elapsed
                eta = (len(all_to_encode) - done) / rate
                log(f"  {done:,}/{len(all_to_encode):,} "
                    f"({rate:.0f}/s) ETA {eta:.0f}s")
    vec_cache = dict(results)
    log(f"Encoded in {time.time() - t_enc:.1f}s")

    # ---- Labels ----
    labels: Dict[int, str] = {}
    for idx in vec_cache:
        oracle = candles[idx].get(args.label)
        if oracle in ("BUY", "SELL"):
            labels[idx] = oracle
        else:
            labels[idx] = compute_actual(candles, idx)

    train_valid = [i for i in train_sample if labels.get(i) in ("BUY", "SELL")]
    test_valid = [i for i in test_sample if labels.get(i) in ("BUY", "SELL")]
    log(f"Valid: {len(train_valid):,} train, {len(test_valid):,} test")

    buy_train = sum(1 for i in train_valid if labels[i] == "BUY")
    sell_train = len(train_valid) - buy_train
    buy_test = sum(1 for i in test_valid if labels[i] == "BUY")
    sell_test = len(test_valid) - buy_test
    log(f"  Train: {buy_train} BUY, {sell_train} SELL")
    log(f"  Test:  {buy_test} BUY, {sell_test} SELL")

    train_labels_list = [labels[i] for i in train_valid]
    test_labels_list = [labels[i] for i in test_valid]
    test_years = [candles[i].get("year") for i in test_valid]
    n_test = len(test_valid)

    def report_by_year(preds):
        by_year: Dict[int, List[bool]] = {}
        for y, p, a in zip(test_years, preds, test_labels_list):
            by_year.setdefault(y, []).append(p == a)
        for y in sorted(by_year):
            yr_acc = sum(by_year[y]) / len(by_year[y]) * 100
            log(f"    {y}: {yr_acc:.1f}% ({len(by_year[y]):,})")

    k_values = [5, 10, 20, 50]
    k_values = [k for k in k_values if k <= len(train_valid)]

    # ================================================================
    # PER-PANEL k-NN
    # ================================================================
    log(f"\n{'='*70}")
    log(f"PER-PANEL PIXEL k-NN")
    log(f"  k values: {k_values}")
    log(f"{'='*70}")

    panel_preds: Dict[str, dict] = {}
    panel_buy_s: Dict[str, dict] = {}
    panel_sell_s: Dict[str, dict] = {}

    for pname in PANEL_NAMES:
        ns = DEFAULT_PANEL_STRIPES[pname]
        log(f"\n  Panel: {pname} ({ns} stripes x {args.dims}D "
            f"= {ns * args.dims:,} dims)")

        p_train = np.stack([
            vec_cache[i][pname].reshape(-1).astype(np.float32)
            for i in train_valid
        ])
        p_test = np.stack([
            vec_cache[i][pname].reshape(-1).astype(np.float32)
            for i in test_valid
        ])
        log(f"    matrices: train={p_train.shape}, test={p_test.shape}")

        buy_mask = np.array([l == "BUY" for l in train_labels_list])
        buy_mean = p_train[buy_mask].mean(axis=0)
        sell_mean = p_train[~buy_mask].mean(axis=0)
        buy_mn = buy_mean / (np.linalg.norm(buy_mean) + 1e-10)
        sell_mn = sell_mean / (np.linalg.norm(sell_mean) + 1e-10)
        cos_bs = float(np.dot(buy_mn, sell_mn))
        log(f"    cosine(BUY, SELL means) = {cos_bs:.6f}")

        t0 = time.time()
        preds_d, buy_s_d, sell_s_d = knn_classify_with_scores(
            p_test, p_train, train_labels_list, k_values
        )
        log(f"    k-NN in {time.time() - t0:.1f}s")

        panel_preds[pname] = preds_d
        panel_buy_s[pname] = buy_s_d
        panel_sell_s[pname] = sell_s_d

        for k in k_values:
            correct = sum(
                1 for p, a in zip(preds_d[k], test_labels_list) if p == a
            )
            acc = correct / n_test * 100
            marker = " <<<" if acc > 55 else ""
            log(f"    k={k:3d}: {acc:.1f}% ({correct}/{n_test}){marker}")

        del p_train, p_test

    # ================================================================
    # COMBINED PREDICTIONS
    # ================================================================
    log(f"\n{'='*70}")
    log(f"COMBINED PREDICTIONS (cross-panel)")
    log(f"{'='*70}")

    best_combined_acc = 0.0
    best_combined_method = ""
    best_combined_preds: list = []

    for k in k_values:
        log(f"\n  k={k}:")

        # Majority vote (3+ of 4 panels agree)
        majority_preds = []
        for i in range(n_test):
            buy_votes = sum(
                1 for p in PANEL_NAMES if panel_preds[p][k][i] == "BUY"
            )
            majority_preds.append("BUY" if buy_votes >= 3 else "SELL")
        maj_correct = sum(
            1 for p, a in zip(majority_preds, test_labels_list) if p == a
        )
        maj_acc = maj_correct / n_test * 100
        log(f"    majority (3/4):      {maj_acc:.1f}% ({maj_correct}/{n_test})")

        # Unanimous vote (4/4 agree, abstain otherwise)
        unan_correct = 0
        unan_count = 0
        for i in range(n_test):
            buy_votes = sum(
                1 for p in PANEL_NAMES if panel_preds[p][k][i] == "BUY"
            )
            if buy_votes == 4:
                unan_count += 1
                if test_labels_list[i] == "BUY":
                    unan_correct += 1
            elif buy_votes == 0:
                unan_count += 1
                if test_labels_list[i] == "SELL":
                    unan_correct += 1
        if unan_count > 0:
            unan_acc = unan_correct / unan_count * 100
            log(f"    unanimous (4/4):     {unan_acc:.1f}% "
                f"({unan_correct}/{unan_count}, "
                f"coverage={unan_count/n_test*100:.0f}%)")

        # Similarity-weighted vote
        total_buy = sum(panel_buy_s[p][k] for p in PANEL_NAMES)
        total_sell = sum(panel_sell_s[p][k] for p in PANEL_NAMES)
        sim_preds = [
            "BUY" if b > s else "SELL"
            for b, s in zip(total_buy, total_sell)
        ]
        sim_correct = sum(
            1 for p, a in zip(sim_preds, test_labels_list) if p == a
        )
        sim_acc = sim_correct / n_test * 100
        log(f"    similarity-weighted: {sim_acc:.1f}% ({sim_correct}/{n_test})")

        for method, acc, pds in [
            (f"majority k={k}", maj_acc, majority_preds),
            (f"sim-weighted k={k}", sim_acc, sim_preds),
        ]:
            if acc > best_combined_acc:
                best_combined_acc = acc
                best_combined_method = method
                best_combined_preds = pds

    log(f"\n  Best combined: {best_combined_method} ({best_combined_acc:.1f}%)")
    log(f"  Per-year:")
    report_by_year(best_combined_preds)

    # ================================================================
    # SUMMARY
    # ================================================================
    log(f"\n{'='*70}")
    log(f"SUMMARY  [pixel-panel, window={args.window}, oracle={args.label}]")
    log(f"{'='*70}")
    for pname in PANEL_NAMES:
        best_pa = 0.0
        best_pk = 0
        for k in k_values:
            correct = sum(
                1 for p, a in zip(panel_preds[pname][k], test_labels_list)
                if p == a
            )
            acc = correct / n_test * 100
            if acc > best_pa:
                best_pa = acc
                best_pk = k
        log(f"  {pname:5s} panel (best k={best_pk:3d}): {best_pa:.1f}%")
    log(f"  combined ({best_combined_method}): {best_combined_acc:.1f}%")

    winner = best_combined_acc
    for pname in PANEL_NAMES:
        for k in k_values:
            correct = sum(
                1 for p, a in zip(panel_preds[pname][k], test_labels_list)
                if p == a
            )
            acc = correct / n_test * 100
            if acc > winner:
                winner = acc

    if winner > 55:
        log(f"\n  >>> SIGNAL FOUND ({winner:.1f}%)!")
    elif winner > 52.5:
        log(f"\n  Marginal signal ({winner:.1f}%) — might improve with scale.")
    else:
        log(f"\n  No signal ({winner:.1f}%). Barrier confirmed for this config.")


def main():
    global _g_candles, _g_window, _g_dim, _g_stripes, _g_encoding

    parser = argparse.ArgumentParser()
    parser.add_argument("--encoding",
                        choices=["categorical", "visual", "pixel", "pixel-panel"],
                        default="pixel")
    parser.add_argument("--n-train", type=int, default=10000)
    parser.add_argument("--n-test", type=int, default=5000)
    parser.add_argument("--window", type=int, default=48)
    parser.add_argument("--dims", type=int, default=1024)
    parser.add_argument("--stripes", type=int, default=16)
    parser.add_argument("--vol-threshold", type=float, default=0.002)
    parser.add_argument("--workers", type=int, default=6)
    parser.add_argument("--group-size", type=int, default=10,
                        help="Training vectors per engram group")
    parser.add_argument("--engram-k", type=int, default=4,
                        help="PCA components per engram subspace")
    parser.add_argument("--label", default="label_oracle_10")
    parser.add_argument("--skip-engrams", action="store_true",
                        help="Skip slow engram matching")
    args = parser.parse_args()

    # Auto-set sensible defaults for pixel encodings if user didn't override
    if args.encoding in ("pixel", "pixel-panel"):
        if args.dims == 1024:
            args.dims = 4096
    if args.encoding == "pixel" and args.stripes == 16:
        args.stripes = 32 if args.window <= 48 else 64

    log("=" * 70)
    log(f"ENGRAM k-NN: {args.encoding.upper()} ENCODING")
    log(f"  n_train={args.n_train}, n_test={args.n_test}")
    if args.encoding == "pixel-panel":
        ps = ", ".join(f"{p}={s}" for p, s in DEFAULT_PANEL_STRIPES.items())
        log(f"  per-panel stripes [{ps}] × {args.dims}D, window={args.window}")
    else:
        log(f"  {args.stripes} stripes × {args.dims}D, window={args.window}")
    log(f"  oracle={args.label}, group_size={args.group_size}")
    log("=" * 70)

    # ---- Load data ----
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

    # ---- Split by year + volatility filter ----
    train_indices, test_indices = [], []
    for i in range(args.window - 1, len(candles)):
        atr_r = candles[i].get("atr_r") or 0
        if atr_r <= args.vol_threshold:
            continue
        year = candles[i].get("year")
        if year in SUPERVISED_YEARS:
            train_indices.append(i)
        else:
            test_indices.append(i)

    log(f"Volatile: {len(train_indices):,} train (2019-2020), "
        f"{len(test_indices):,} test (2021+)")

    # ---- Sample ----
    np.random.seed(42)
    train_sample = sorted(np.random.choice(
        train_indices, size=min(args.n_train, len(train_indices)), replace=False
    ).tolist())
    test_sample = sorted(np.random.choice(
        test_indices, size=min(args.n_test, len(test_indices)), replace=False
    ).tolist())
    all_to_encode = train_sample + test_sample
    log(f"Sampled: {len(train_sample):,} train + {len(test_sample):,} test")

    if args.encoding == "pixel-panel":
        _run_panel_knn(args, candles, train_sample, test_sample)
        return

    # ---- Encode ----
    _g_candles = candles
    _g_window = args.window
    _g_dim = args.dims
    _g_stripes = args.stripes
    _g_encoding = args.encoding

    log(f"Encoding {len(all_to_encode):,} vectors "
        f"({args.encoding}, {args.workers} workers)...")
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
                eta = (len(all_to_encode) - done) / rate
                log(f"  {done:,}/{len(all_to_encode):,} "
                    f"({rate:.0f}/s) ETA {eta:.0f}s")
    vec_cache = dict(results)
    log(f"Encoded in {time.time() - t_enc:.1f}s")

    # ---- Labels ----
    labels: Dict[int, str] = {}
    for idx in vec_cache:
        oracle = candles[idx].get(args.label)
        if oracle in ("BUY", "SELL"):
            labels[idx] = oracle
        else:
            labels[idx] = compute_actual(candles, idx)

    train_valid = [i for i in train_sample if labels.get(i) in ("BUY", "SELL")]
    test_valid = [i for i in test_sample if labels.get(i) in ("BUY", "SELL")]
    log(f"Valid: {len(train_valid):,} train, {len(test_valid):,} test")

    buy_train = sum(1 for i in train_valid if labels[i] == "BUY")
    sell_train = len(train_valid) - buy_train
    buy_test = sum(1 for i in test_valid if labels[i] == "BUY")
    sell_test = len(test_valid) - buy_test
    log(f"  Train: {buy_train} BUY, {sell_train} SELL")
    log(f"  Test:  {buy_test} BUY, {sell_test} SELL")

    n_stripes = args.stripes
    dim = args.dims

    # ---- Build flat matrices for k-NN ----
    train_flat = np.stack([
        vec_cache[i].reshape(-1).astype(np.float32) for i in train_valid
    ])
    test_flat = np.stack([
        vec_cache[i].reshape(-1).astype(np.float32) for i in test_valid
    ])
    train_labels_list = [labels[i] for i in train_valid]
    test_labels_list = [labels[i] for i in test_valid]
    test_years = [candles[i].get("year") for i in test_valid]
    log(f"Matrices: train={train_flat.shape}, test={test_flat.shape}")

    def report_by_year(preds):
        by_year: Dict[int, List[bool]] = {}
        for y, p, a in zip(test_years, preds, test_labels_list):
            by_year.setdefault(y, []).append(p == a)
        for y in sorted(by_year):
            yr_acc = sum(by_year[y]) / len(by_year[y]) * 100
            log(f"    {y}: {yr_acc:.1f}% ({len(by_year[y]):,})")

    # ================================================================
    # 1. PROTOTYPE BASELINE
    # ================================================================
    log(f"\n{'='*70}")
    log("CLASSIFIER 1: PROTOTYPE BASELINE (class means)")
    log(f"{'='*70}")

    buy_mask = np.array([l == "BUY" for l in train_labels_list])
    buy_mean = train_flat[buy_mask].mean(axis=0)
    sell_mean = train_flat[~buy_mask].mean(axis=0)

    buy_mn = buy_mean / (np.linalg.norm(buy_mean) + 1e-10)
    sell_mn = sell_mean / (np.linalg.norm(sell_mean) + 1e-10)

    proto_cos = float(np.dot(buy_mn, sell_mn))
    log(f"  cosine(BUY_mean, SELL_mean) = {proto_cos:.6f}")

    tn = np.linalg.norm(test_flat, axis=1, keepdims=True)
    tn[tn == 0] = 1.0
    test_normed = test_flat / tn

    cos_buy = test_normed @ buy_mn
    cos_sell = test_normed @ sell_mn
    proto_preds = [
        "BUY" if cb > cs else "SELL"
        for cb, cs in zip(cos_buy, cos_sell)
    ]

    correct = sum(1 for p, a in zip(proto_preds, test_labels_list) if p == a)
    total = len(test_labels_list)
    proto_acc = correct / total * 100
    log(f"  OOS accuracy: {proto_acc:.1f}% ({correct}/{total})")
    report_by_year(proto_preds)

    # ================================================================
    # 2. k-NN
    # ================================================================
    k_values = [1, 3, 5, 10, 20, 50, 100, 200]
    k_values = [k for k in k_values if k <= len(train_valid)]

    log(f"\n{'='*70}")
    log(f"CLASSIFIER 2: k-NN (cosine similarity)")
    log(f"  k values: {k_values}")
    log(f"{'='*70}")

    t_knn = time.time()
    knn_results = knn_classify_batch(
        test_flat, train_flat, train_labels_list, k_values
    )
    log(f"  Computed in {time.time() - t_knn:.1f}s")

    best_k = None
    best_knn_acc = 0.0
    for k in k_values:
        preds = knn_results[k]
        correct = sum(
            1 for p, a in zip(preds, test_labels_list) if p == a
        )
        total = len(test_labels_list)
        acc = correct / total * 100

        buy_c = sum(
            1 for p, a in zip(preds, test_labels_list)
            if p == a and a == "BUY"
        )
        sell_c = sum(
            1 for p, a in zip(preds, test_labels_list)
            if p == a and a == "SELL"
        )
        marker = " <<<" if acc > 55 else ""
        log(f"  k={k:3d}: {acc:.1f}% ({correct}/{total}) "
            f"[BUY:{buy_c} SELL:{sell_c}]{marker}")

        if acc > best_knn_acc:
            best_knn_acc = acc
            best_k = k

    log(f"\n  Best k={best_k} ({best_knn_acc:.1f}%), per-year:")
    report_by_year(knn_results[best_k])

    # ---- Similarity distribution diagnostic ----
    log(f"\n  Nearest-neighbor similarity stats:")
    train_norms = np.linalg.norm(train_flat, axis=1, keepdims=True)
    train_norms[train_norms == 0] = 1.0
    train_normed = train_flat / train_norms

    sample_test = test_normed[:500]
    sample_sims = sample_test @ train_normed.T
    nn_sims = np.max(sample_sims, axis=1)
    log(f"    1-NN cosine: mean={nn_sims.mean():.4f}, "
        f"std={nn_sims.std():.4f}, "
        f"min={nn_sims.min():.4f}, max={nn_sims.max():.4f}")

    top10_sims = np.sort(sample_sims, axis=1)[:, -10:]
    log(f"    10-NN mean cosine: {top10_sims.mean():.4f}")
    log(f"    Gap (1NN - 10NN): {(nn_sims - top10_sims[:, 0]).mean():.4f}")

    # ================================================================
    # 3. ENGRAM LIBRARY (optional — slow)
    # ================================================================
    engram_acc = 0.0
    if args.skip_engrams:
        log(f"\n  Engram matching skipped (--skip-engrams)")
    else:
        log(f"\n{'='*70}")
        log(f"CLASSIFIER 3: ENGRAM LIBRARY")
        log(f"  {args.group_size} vectors/engram, k={args.engram_k} PCs")
        log(f"{'='*70}")

        library = EngramLibrary(dim=dim)

        buy_train_idx = [i for i in train_valid if labels[i] == "BUY"]
        sell_train_idx = [i for i in train_valid if labels[i] == "SELL"]

        engram_count = 0
        for lbl, indices in [("BUY", buy_train_idx), ("SELL", sell_train_idx)]:
            for g_start in range(0, len(indices), args.group_size):
                g_end = min(g_start + args.group_size, len(indices))
                group = indices[g_start:g_end]
                if len(group) < 3:
                    continue

                ss = StripedSubspace(
                    dim=dim, k=args.engram_k, n_stripes=n_stripes
                )
                for idx in group:
                    arr = vec_cache[idx]
                    stripe_vecs = [
                        arr[s].astype(np.float64) for s in range(n_stripes)
                    ]
                    ss.update(stripe_vecs)

                library.add_striped(
                    f"{lbl}_{engram_count}", ss, label=lbl,
                )
                engram_count += 1

        n_buy_eng = sum(
            1 for n in library.names(kind="striped")
            if library.get(n).metadata.get("label") == "BUY"
        )
        n_sell_eng = engram_count - n_buy_eng
        log(f"  Minted {engram_count} engrams "
            f"({n_buy_eng} BUY, {n_sell_eng} SELL)")

        log(f"  Warming up engram subspaces...")
        for name in library.names():
            _ = library.get(name).subspace

        log(f"  Matching {len(test_valid):,} test vectors...")
        t_engram = time.time()

        engram_preds = []
        vote_k = 5
        pf_k = min(100, engram_count)

        for i_test, idx in enumerate(test_valid):
            arr = vec_cache[idx]
            stripe_vecs = [arr[s].astype(np.float64) for s in range(n_stripes)]

            matches = library.match_striped(
                stripe_vecs, top_k=vote_k, prefilter_k=pf_k,
            )

            buy_v = sell_v = 0
            for name, _res in matches:
                eng = library.get(name)
                if eng and eng.metadata.get("label") == "BUY":
                    buy_v += 1
                else:
                    sell_v += 1

            engram_preds.append("BUY" if buy_v > sell_v else "SELL")

            if (i_test + 1) % 500 == 0:
                elapsed = time.time() - t_engram
                rate = (i_test + 1) / elapsed
                eta = (len(test_valid) - i_test - 1) / rate
                log(f"    {i_test+1:,}/{len(test_valid):,} "
                    f"({rate:.0f}/s) ETA {eta:.0f}s")

        correct = sum(
            1 for p, a in zip(engram_preds, test_labels_list) if p == a
        )
        total = len(test_labels_list)
        engram_acc = correct / total * 100
        log(f"  Engram matching in {time.time() - t_engram:.1f}s")
        log(f"  OOS accuracy: {engram_acc:.1f}% ({correct}/{total})")
        report_by_year(engram_preds)

    # ================================================================
    # SUMMARY
    # ================================================================
    log(f"\n{'='*70}")
    log(f"SUMMARY  [{args.encoding} encoding, window={args.window}, "
        f"oracle={args.label}]")
    log(f"{'='*70}")
    log(f"  Prototype baseline:       {proto_acc:.1f}%")
    log(f"  k-NN (best k={best_k:3d}):      {best_knn_acc:.1f}%")
    if not args.skip_engrams:
        log(f"  Engram library (top-5):   {engram_acc:.1f}%")

    winner = max(proto_acc, best_knn_acc, engram_acc)
    if winner > 55:
        log(f"\n  >>> SIGNAL FOUND ({winner:.1f}%)!")
        log(f"  >>> Scale up: more training data, more engrams.")
    elif winner > 52.5:
        log(f"\n  Marginal signal ({winner:.1f}%) — might improve with scale.")
    else:
        log(f"\n  No signal ({winner:.1f}%). Barrier confirmed for this config.")


if __name__ == "__main__":
    main()
