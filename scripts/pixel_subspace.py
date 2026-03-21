#!/usr/bin/env python
"""pixel_subspace.py — Walk-forward pixel subspace + algebra pipeline.

Combines the best encoding (pixel chart raster) with subspace-based
classification, Holon algebra scoring methods, gated updates from the
spectral firewall, and engram-based regime detection.

Architecture:
  1. Warm-up: train BUY + SELL StripedSubspaces on labeled 2019-2020 data
  2. Walk-forward: for each volatile candle, score with 7 methods, predict,
     queue trade, resolve, gated-update correct subspace
  3. Engram snapshots every 5k candles for staleness monitoring

Usage:
    ./scripts/run_with_venv.sh python holon-lab-trading/scripts/pixel_subspace.py \\
        --workers 6
"""

from __future__ import annotations

import argparse
import collections
import multiprocessing as mp
import sqlite3
import sys
import time
from pathlib import Path
from typing import Dict, List, Optional, Tuple

import numpy as np

sys.path.insert(0, str(Path(__file__).parent.parent))

from holon import (
    DeterministicVectorManager,
    Encoder,
    StripedSubspace,
    amplify,
    cosine_similarity,
    difference,
    grover_amplify,
    negate,
    prototype,
    prototype_add,
    reject,
    resonance,
)
from holon.memory.engram import EngramLibrary

sys.path.insert(0, str(Path(__file__).parent))
from categorical_refine import build_pixel_data, ALL_DB_COLS

DB_PATH = Path(__file__).parent.parent / "data" / "analysis.db"

METHOD_NAMES = [
    "residual",
    "proto_cos",
    "grover",
    "reject",
    "resonance",
    "anom_xmatch",
    "res_profile",
    "disc_res",
    "disc_res_stripe",
    "disc_masked",
]


def log(msg: str):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def sf(v):
    return 0.0 if v is None else float(v)


# =========================================================================
# Multiprocessing encoding
# =========================================================================

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


# =========================================================================
# Scoring methods
# =========================================================================

def score_all_methods(
    stripe_vecs: List[np.ndarray],
    buy_sub: StripedSubspace,
    sell_sub: StripedSubspace,
    buy_proto_flat: np.ndarray,
    sell_proto_flat: np.ndarray,
    discriminant: np.ndarray,
    buy_res_profile_mean: Optional[np.ndarray],
    sell_res_profile_mean: Optional[np.ndarray],
    disc_per_stripe: Optional[List[np.ndarray]] = None,
    buy_stripe_protos: Optional[List[np.ndarray]] = None,
    sell_stripe_protos: Optional[List[np.ndarray]] = None,
) -> Dict[str, str]:
    """Score a vector with all methods, return predictions."""
    preds: Dict[str, str] = {}

    flat = np.concatenate([sv.astype(np.float64) for sv in stripe_vecs])
    n_stripes = len(stripe_vecs)

    # Method 1: Raw Residual
    res_buy = buy_sub.residual(stripe_vecs)
    res_sell = sell_sub.residual(stripe_vecs)
    preds["residual"] = "BUY" if res_buy < res_sell else "SELL"

    # Method 2: Prototype Cosine
    cos_buy = float(cosine_similarity(flat, buy_proto_flat))
    cos_sell = float(cosine_similarity(flat, sell_proto_flat))
    preds["proto_cos"] = "BUY" if cos_buy > cos_sell else "SELL"

    # Method 3: Grover-Amplified Discriminant
    amplified = grover_amplify(discriminant, flat, iterations=1)
    ga_buy = float(cosine_similarity(amplified, buy_proto_flat))
    ga_sell = float(cosine_similarity(amplified, sell_proto_flat))
    preds["grover"] = "BUY" if ga_buy > ga_sell else "SELL"

    # Method 4: Reject + Measure
    buy_rejected = reject(flat, [buy_proto_flat])
    sell_rejected = reject(flat, [sell_proto_flat])
    rj_buy_norm = float(np.linalg.norm(buy_rejected))
    rj_sell_norm = float(np.linalg.norm(sell_rejected))
    preds["reject"] = "BUY" if rj_sell_norm > rj_buy_norm else "SELL"

    # Method 5: Resonance Filter
    res_buy_vec = resonance(flat, buy_proto_flat)
    res_sell_vec = resonance(flat, sell_proto_flat)
    rf_buy = float(cosine_similarity(res_buy_vec, buy_proto_flat))
    rf_sell = float(cosine_similarity(res_sell_vec, sell_proto_flat))
    preds["resonance"] = "BUY" if rf_buy > rf_sell else "SELL"

    # Method 6: Anomalous Component Cross-Match
    anom_buy_parts = []
    anom_sell_parts = []
    for s in range(n_stripes):
        anom_buy_parts.append(buy_sub.anomalous_component(stripe_vecs, s))
        anom_sell_parts.append(sell_sub.anomalous_component(stripe_vecs, s))
    anom_buy_flat = np.concatenate(anom_buy_parts)
    anom_sell_flat = np.concatenate(anom_sell_parts)
    ax_buy = float(cosine_similarity(anom_buy_flat, sell_proto_flat))
    ax_sell = float(cosine_similarity(anom_sell_flat, buy_proto_flat))
    preds["anom_xmatch"] = "BUY" if ax_buy > ax_sell else "SELL"

    # Method 7: Residual Profile Cosine
    if buy_res_profile_mean is not None and sell_res_profile_mean is not None:
        rp = buy_sub.residual_profile(stripe_vecs)
        rp_buy_cos = float(cosine_similarity(rp, buy_res_profile_mean))
        rp_sell_cos = float(cosine_similarity(rp, sell_res_profile_mean))
        preds["res_profile"] = "SELL" if rp_buy_cos > rp_sell_cos else "BUY"
    else:
        preds["res_profile"] = "BUY"

    # Method 8: Discriminative Resonance (flat)
    filtered = resonance(flat, discriminant)
    dr_buy = float(cosine_similarity(filtered, buy_proto_flat))
    dr_sell = float(cosine_similarity(filtered, sell_proto_flat))
    preds["disc_res"] = "BUY" if dr_buy > dr_sell else "SELL"

    # Method 9: Discriminative Resonance (per-stripe)
    if disc_per_stripe is not None:
        filt_stripes = [resonance(stripe_vecs[s], disc_per_stripe[s])
                        for s in range(n_stripes)]
        filt_flat = np.concatenate(filt_stripes)
        drs_buy = float(cosine_similarity(filt_flat, buy_proto_flat))
        drs_sell = float(cosine_similarity(filt_flat, sell_proto_flat))
        preds["disc_res_stripe"] = "BUY" if drs_buy > drs_sell else "SELL"
    else:
        preds["disc_res_stripe"] = preds["disc_res"]

    # Method 10: Discriminative Masked Cosine
    buy_filt = resonance(buy_proto_flat, discriminant)
    sell_filt = resonance(sell_proto_flat, discriminant)
    filtered_input = resonance(flat, discriminant)
    dm_buy = float(cosine_similarity(filtered_input, buy_filt))
    dm_sell = float(cosine_similarity(filtered_input, sell_filt))
    preds["disc_masked"] = "BUY" if dm_buy > dm_sell else "SELL"

    return preds


# =========================================================================
# Main pipeline
# =========================================================================

def main():
    global _g_candles, _g_window, _g_dim, _g_stripes

    parser = argparse.ArgumentParser()
    parser.add_argument("--window", type=int, default=48)
    parser.add_argument("--dims", type=int, default=4096)
    parser.add_argument("--stripes", type=int, default=32)
    parser.add_argument("--sub-k", type=int, default=8,
                        help="PCA components per stripe subspace")
    parser.add_argument("--vol-threshold", type=float, default=0.002)
    parser.add_argument("--workers", type=int, default=6)
    parser.add_argument("--label", default="label_oracle_10")
    parser.add_argument("--warmup-months", type=int, default=6,
                        help="Months of labeled data for warm-up")
    parser.add_argument("--resolution", type=int, default=36,
                        help="Candles until trade resolves")
    parser.add_argument("--freeze-window", type=int, default=200)
    parser.add_argument("--freeze-threshold", type=float, default=0.45)
    parser.add_argument("--max-warmup", type=int, default=10000,
                        help="Max warm-up vectors to encode")
    parser.add_argument("--max-adaptive", type=int, default=20000,
                        help="Max adaptive vectors to process")
    parser.add_argument("--engram-interval", type=int, default=5000,
                        help="Candles between engram snapshots")
    parser.add_argument("--progress-interval", type=int, default=5000)
    parser.add_argument("--update-mode", default="selective",
                        choices=["classic", "selective"],
                        help="classic=prototype_add, selective=amplify discriminative")
    args = parser.parse_args()

    log("=" * 70)
    log("PIXEL SUBSPACE + ALGEBRA WALK-FORWARD")
    log(f"  {args.stripes} stripes x {args.dims}D, window={args.window}")
    log(f"  sub_k={args.sub_k}, oracle={args.label}")
    log(f"  warmup={args.warmup_months} months, resolution={args.resolution}")
    log(f"  freeze: window={args.freeze_window}, threshold={args.freeze_threshold}")
    log(f"  update_mode={args.update_mode}")
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

    # ---- Identify volatile candles with labels ----
    volatile_indices = []
    for i in range(args.window - 1, len(candles)):
        atr_r = candles[i].get("atr_r") or 0
        if atr_r > args.vol_threshold:
            volatile_indices.append(i)
    log(f"Volatile candles: {len(volatile_indices):,}")

    # ---- Split warm-up (2019-2020) vs adaptive (2021+) ----
    WARMUP_YEARS = {2019, 2020}
    warmup_indices = []
    adaptive_indices = []
    for i in volatile_indices:
        year = candles[i].get("year")
        if year in WARMUP_YEARS:
            warmup_indices.append(i)
        else:
            adaptive_indices.append(i)
    log(f"Warm-up: {len(warmup_indices):,}, Adaptive: {len(adaptive_indices):,}")

    # ---- Filter to labeled candles only ----
    warmup_labeled = []
    for i in warmup_indices:
        lbl = candles[i].get(args.label)
        if lbl in ("BUY", "SELL"):
            warmup_labeled.append((i, lbl))
    adaptive_labeled = []
    for i in adaptive_indices:
        lbl = candles[i].get(args.label)
        if lbl in ("BUY", "SELL"):
            adaptive_labeled.append(i)
    log(f"Warm-up labeled: {len(warmup_labeled):,} "
        f"({sum(1 for _, l in warmup_labeled if l == 'BUY')} BUY, "
        f"{sum(1 for _, l in warmup_labeled if l == 'SELL')} SELL)")
    log(f"Adaptive labeled: {len(adaptive_labeled):,}")

    # ---- Sample to manageable sizes ----
    np.random.seed(42)
    if len(warmup_labeled) > args.max_warmup:
        indices = np.random.choice(
            len(warmup_labeled), args.max_warmup, replace=False
        )
        indices.sort()
        warmup_labeled = [warmup_labeled[i] for i in indices]
        log(f"Sampled warm-up to {len(warmup_labeled):,}")
    if len(adaptive_labeled) > args.max_adaptive:
        sampled = sorted(np.random.choice(
            adaptive_labeled, args.max_adaptive, replace=False
        ).tolist())
        adaptive_labeled = sampled
        log(f"Sampled adaptive to {len(adaptive_labeled):,}")

    # ---- Batch-encode ALL labeled candles (deterministic, order-independent) ----
    all_to_encode = [i for i, _ in warmup_labeled] + adaptive_labeled
    _g_candles = candles
    _g_window = args.window
    _g_dim = args.dims
    _g_stripes = args.stripes

    log(f"Encoding {len(all_to_encode):,} vectors ({args.workers} workers)...")
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

    # ---- Train BUY/SELL subspaces ----
    buy_sub = StripedSubspace(
        dim=args.dims, k=args.sub_k, n_stripes=args.stripes
    )
    sell_sub = StripedSubspace(
        dim=args.dims, k=args.sub_k, n_stripes=args.stripes
    )

    buy_vecs_flat = []
    sell_vecs_flat = []
    buy_stripe_accum = [[] for _ in range(args.stripes)]
    sell_stripe_accum = [[] for _ in range(args.stripes)]
    buy_count = 0
    sell_count = 0

    for idx, lbl in warmup_labeled:
        arr = vec_cache[idx]
        stripe_vecs = [arr[s].astype(np.float64) for s in range(args.stripes)]
        flat = np.concatenate(stripe_vecs)

        if lbl == "BUY":
            buy_sub.update(stripe_vecs)
            buy_vecs_flat.append(flat)
            for s in range(args.stripes):
                buy_stripe_accum[s].append(stripe_vecs[s])
            buy_count += 1
        else:
            sell_sub.update(stripe_vecs)
            sell_vecs_flat.append(flat)
            for s in range(args.stripes):
                sell_stripe_accum[s].append(stripe_vecs[s])
            sell_count += 1

    log(f"Subspaces trained: BUY({buy_count}), SELL({sell_count})")

    # ---- Build prototypes and discriminants ----
    buy_proto_flat = prototype(buy_vecs_flat)
    sell_proto_flat = prototype(sell_vecs_flat)
    disc = difference(sell_proto_flat, buy_proto_flat)

    buy_stripe_protos = [prototype(vecs) for vecs in buy_stripe_accum]
    sell_stripe_protos = [prototype(vecs) for vecs in sell_stripe_accum]
    disc_per_stripe = [difference(sell_stripe_protos[s], buy_stripe_protos[s])
                       for s in range(args.stripes)]

    proto_cos = float(cosine_similarity(buy_proto_flat, sell_proto_flat))
    log(f"Prototype cosine(BUY, SELL) = {proto_cos:.6f}")
    disc_density = np.sum(disc != 0) / len(disc) * 100
    log(f"Discriminant density: {disc_density:.1f}%")

    # ---- Build residual profile baselines ----
    buy_res_profiles = []
    sell_res_profiles = []
    for idx, lbl in warmup_labeled:
        arr = vec_cache[idx]
        stripe_vecs = [arr[s].astype(np.float64) for s in range(args.stripes)]
        if lbl == "BUY":
            buy_res_profiles.append(buy_sub.residual_profile(stripe_vecs))
        else:
            sell_res_profiles.append(sell_sub.residual_profile(stripe_vecs))

    buy_rp_mean = np.mean(buy_res_profiles, axis=0) if buy_res_profiles else None
    sell_rp_mean = np.mean(sell_res_profiles, axis=0) if sell_res_profiles else None

    del buy_vecs_flat, sell_vecs_flat
    del buy_stripe_accum, sell_stripe_accum
    del buy_res_profiles, sell_res_profiles

    # ---- Snapshot initial engrams ----
    library = EngramLibrary(dim=args.dims)
    library.add_striped("buy_initial", buy_sub, label="BUY")
    library.add_striped("sell_initial", sell_sub, label="SELL")
    log("Initial engrams saved")

    # ================================================================
    # WALK-FORWARD ADAPTIVE PHASE
    # ================================================================
    log(f"\n{'='*70}")
    log("WALK-FORWARD ADAPTIVE PHASE")
    log(f"  {len(adaptive_labeled):,} labeled candles to process")
    log(f"{'='*70}")

    # Per-method tracking
    method_correct = {m: 0 for m in METHOD_NAMES}
    method_total = {m: 0 for m in METHOD_NAMES}
    method_by_year: Dict[str, Dict[int, List[bool]]] = {
        m: {} for m in METHOD_NAMES
    }

    # Trade queue: (resolve_idx, prediction_dict, stripe_vecs, actual_label)
    trade_queue = collections.deque()

    # Gated update tracking
    total_updates = 0
    total_skips = 0
    freeze_events = 0
    frozen = False
    recent_correct = collections.deque(maxlen=args.freeze_window)

    # Engram staleness
    engram_snapshots = 0
    staleness_log: List[Tuple[int, float, float]] = []

    t_walk = time.time()
    processed = 0
    last_progress = 0

    for candle_pos, ci in enumerate(adaptive_labeled):
        c = candles[ci]
        lbl = c.get(args.label)

        # ---- Load pre-encoded vector ----
        arr = vec_cache[ci]
        stripe_vecs = [arr[s].astype(np.float64) for s in range(args.stripes)]

        # ---- Resolve pending trades ----
        while trade_queue and trade_queue[0][0] <= ci:
            res_ci, pred_dict, trade_stripes, trade_lbl = trade_queue.popleft()

            if trade_lbl not in ("BUY", "SELL"):
                continue

            year = candles[res_ci].get("year") or 0

            for m in METHOD_NAMES:
                correct = pred_dict[m] == trade_lbl
                method_correct[m] += int(correct)
                method_total[m] += 1
                method_by_year[m].setdefault(year, []).append(correct)

            # Gated update: use residual method's prediction as the trigger
            primary_pred = pred_dict["residual"]
            is_correct = primary_pred == trade_lbl
            recent_correct.append(is_correct)

            # Freeze check
            if len(recent_correct) >= args.freeze_window:
                rolling_acc = sum(recent_correct) / len(recent_correct)
                if rolling_acc < args.freeze_threshold and not frozen:
                    frozen = True
                    freeze_events += 1
                    log(f"  *** FREEZE at candle {ci} "
                        f"(rolling acc {rolling_acc:.1%})")
                elif rolling_acc >= 0.50 and frozen:
                    frozen = False
                    log(f"  *** UNFREEZE at candle {ci} "
                        f"(rolling acc {rolling_acc:.1%})")

            if not frozen and is_correct:
                trade_flat = np.concatenate(trade_stripes)
                if args.update_mode == "selective":
                    filtered_input = resonance(trade_flat, disc)
                    if trade_lbl == "BUY":
                        buy_sub.update(trade_stripes)
                        buy_count += 1
                        buy_proto_flat = amplify(
                            buy_proto_flat, filtered_input, strength=1.0
                        )
                        for s in range(args.stripes):
                            fs = resonance(trade_stripes[s], disc_per_stripe[s])
                            buy_stripe_protos[s] = amplify(
                                buy_stripe_protos[s], fs, strength=1.0
                            )
                    else:
                        sell_sub.update(trade_stripes)
                        sell_count += 1
                        sell_proto_flat = amplify(
                            sell_proto_flat, filtered_input, strength=1.0
                        )
                        for s in range(args.stripes):
                            fs = resonance(trade_stripes[s], disc_per_stripe[s])
                            sell_stripe_protos[s] = amplify(
                                sell_stripe_protos[s], fs, strength=1.0
                            )
                else:
                    if trade_lbl == "BUY":
                        buy_sub.update(trade_stripes)
                        buy_count += 1
                        buy_proto_flat = prototype_add(
                            buy_proto_flat, trade_flat, buy_count
                        )
                    else:
                        sell_sub.update(trade_stripes)
                        sell_count += 1
                        sell_proto_flat = prototype_add(
                            sell_proto_flat, trade_flat, sell_count
                        )
                disc = difference(sell_proto_flat, buy_proto_flat)
                disc_per_stripe = [
                    difference(sell_stripe_protos[s], buy_stripe_protos[s])
                    for s in range(args.stripes)
                ]
                total_updates += 1
            elif not frozen and not is_correct and args.update_mode == "selective":
                trade_flat = np.concatenate(trade_stripes)
                filtered_input = resonance(trade_flat, disc)
                if trade_lbl == "BUY":
                    sell_proto_flat = negate(
                        sell_proto_flat, filtered_input
                    )
                else:
                    buy_proto_flat = negate(
                        buy_proto_flat, filtered_input
                    )
                disc = difference(sell_proto_flat, buy_proto_flat)
                disc_per_stripe = [
                    difference(sell_stripe_protos[s], buy_stripe_protos[s])
                    for s in range(args.stripes)
                ]
                total_skips += 1
            else:
                total_skips += 1

        # ---- Score and predict ----
        preds = score_all_methods(
            stripe_vecs, buy_sub, sell_sub,
            buy_proto_flat, sell_proto_flat, disc,
            buy_rp_mean, sell_rp_mean,
            disc_per_stripe, buy_stripe_protos, sell_stripe_protos,
        )

        resolve_at = ci + args.resolution
        trade_queue.append((resolve_at, preds, stripe_vecs, lbl))

        processed += 1

        # ---- Engram staleness check ----
        if processed % args.engram_interval == 0:
            engram_snapshots += 1
            buy_eigs = np.concatenate([
                buy_sub.stripe(s).eigenvalues for s in range(args.stripes)
            ])
            sell_eigs = np.concatenate([
                sell_sub.stripe(s).eigenvalues for s in range(args.stripes)
            ])

            buy_initial = library.get("buy_initial")
            sell_initial = library.get("sell_initial")
            if buy_initial and sell_initial:
                buy_eig_norm = buy_eigs / (np.linalg.norm(buy_eigs) + 1e-10)
                sell_eig_norm = sell_eigs / (np.linalg.norm(sell_eigs) + 1e-10)
                buy_spec_sim = float(cosine_similarity(
                    buy_eig_norm, buy_initial.eigenvalue_signature
                ))
                sell_spec_sim = float(cosine_similarity(
                    sell_eig_norm, sell_initial.eigenvalue_signature
                ))
                staleness_buy = 1.0 - buy_spec_sim
                staleness_sell = 1.0 - sell_spec_sim
                staleness_log.append((processed, staleness_buy, staleness_sell))
                log(f"  Engram staleness @ {processed:,}: "
                    f"BUY={staleness_buy:.4f}, SELL={staleness_sell:.4f}")

        # ---- Progress ----
        if processed - last_progress >= args.progress_interval:
            last_progress = processed
            elapsed = time.time() - t_walk
            rate = processed / elapsed
            eta = (len(adaptive_labeled) - processed) / rate if rate > 0 else 0

            res_acc = (method_correct["residual"] / method_total["residual"] * 100
                       if method_total["residual"] > 0 else 0)
            proto_acc = (method_correct["proto_cos"] / method_total["proto_cos"] * 100
                         if method_total["proto_cos"] > 0 else 0)
            dr_acc = (method_correct["disc_res"] / method_total["disc_res"] * 100
                      if method_total["disc_res"] > 0 else 0)
            dm_acc = (method_correct["disc_masked"] / method_total["disc_masked"] * 100
                      if method_total["disc_masked"] > 0 else 0)

            log(f"  {processed:,}/{len(adaptive_labeled):,} "
                f"({rate:.0f}/s, ETA {eta:.0f}s) "
                f"res={res_acc:.1f}% proto={proto_acc:.1f}% "
                f"disc_r={dr_acc:.1f}% disc_m={dm_acc:.1f}% "
                f"upd={total_updates} skip={total_skips} "
                f"n={method_total.get('residual', 0)}")

    # ---- Drain remaining trades ----
    while trade_queue:
        res_ci, pred_dict, trade_stripes, trade_lbl = trade_queue.popleft()
        if trade_lbl not in ("BUY", "SELL"):
            continue
        year = candles[min(res_ci, len(candles) - 1)].get("year") or 0
        for m in METHOD_NAMES:
            correct = pred_dict[m] == trade_lbl
            method_correct[m] += int(correct)
            method_total[m] += 1
            method_by_year[m].setdefault(year, []).append(correct)

    # ================================================================
    # RESULTS
    # ================================================================
    log(f"\n{'='*70}")
    log("RESULTS")
    log(f"{'='*70}")

    total_elapsed = time.time() - t_walk
    log(f"Walk-forward: {processed:,} candles in {total_elapsed:.0f}s "
        f"({processed/total_elapsed:.0f}/s)")
    log(f"Gated updates: {total_updates:,} correct updates, "
        f"{total_skips:,} skipped")
    log(f"Freeze events: {freeze_events}")
    log(f"Engram snapshots: {engram_snapshots}")

    log(f"\n  Per-method accuracy:")
    best_method = ""
    best_acc = 0.0
    for m in METHOD_NAMES:
        if method_total[m] > 0:
            acc = method_correct[m] / method_total[m] * 100
            marker = " <<<" if acc > 55 else ""
            log(f"    {m:15s}: {acc:.1f}% "
                f"({method_correct[m]:,}/{method_total[m]:,}){marker}")
            if acc > best_acc:
                best_acc = acc
                best_method = m

    log(f"\n  Best method: {best_method} ({best_acc:.1f}%)")
    log(f"\n  Per-year breakdown ({best_method}):")
    if best_method in method_by_year:
        for year in sorted(method_by_year[best_method]):
            yr_data = method_by_year[best_method][year]
            yr_acc = sum(yr_data) / len(yr_data) * 100 if yr_data else 0
            log(f"    {year}: {yr_acc:.1f}% ({len(yr_data):,})")

    log(f"\n  All methods per-year:")
    years = sorted(set(
        y for m in METHOD_NAMES for y in method_by_year[m]
    ))
    header = f"    {'method':15s}" + "".join(f" {y:>6d}" for y in years)
    log(header)
    for m in METHOD_NAMES:
        row = f"    {m:15s}"
        for y in years:
            if y in method_by_year[m] and method_by_year[m][y]:
                acc = sum(method_by_year[m][y]) / len(method_by_year[m][y]) * 100
                row += f" {acc:5.1f}%"
            else:
                row += "     - "
        log(row)

    # Staleness history
    if staleness_log:
        log(f"\n  Engram staleness history:")
        for pos, sb, ss in staleness_log:
            log(f"    candle {pos:>7,}: BUY={sb:.4f}, SELL={ss:.4f}")

    # Summary
    log(f"\n{'='*70}")
    log(f"SUMMARY")
    log(f"{'='*70}")
    log(f"  Best method: {best_method} = {best_acc:.1f}%")
    log(f"  Reference: k-NN pixel = 53.8%, previous best ~52%")

    if best_acc > 55:
        log(f"\n  >>> SIGNAL FOUND ({best_acc:.1f}%)!")
    elif best_acc > 52.5:
        log(f"\n  Marginal signal ({best_acc:.1f}%) — subspace + algebra helps.")
    else:
        log(f"\n  No signal ({best_acc:.1f}%). Subspace approach doesn't help.")


if __name__ == "__main__":
    main()
