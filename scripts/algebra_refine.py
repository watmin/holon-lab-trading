"""Algebra Refinement Classifier.

Uses Holon algebra primitives (reject, difference, amplify, grover_amplify,
resonance) on per-stripe subspace means to extract discriminant signals
that separate BUY from SELL.

Architecture:
  1. Load cached striped vectors from disk, or encode inline with --quick N
  2. Train BUY/SELL StripedSubspaces on 2019-2020 (supervised)
  3. Extract per-stripe means from each subspace
  4. Apply 5 algebra refinement strategies per stripe
  5. Test classification on 2019-2020 (in-sample) and 2021+ (OOS) per year

Usage:
    # From cache:
    ./scripts/run_with_venv.sh python holon-lab-trading/scripts/algebra_refine.py \\
        --cache holon-lab-trading/data/vec_cache_48w_16s_1024d_ta.npz

    # Quick smoke test (N supervised + N adaptive, inline encode):
    ./scripts/run_with_venv.sh python holon-lab-trading/scripts/algebra_refine.py \\
        --quick 5000
"""

from __future__ import annotations

import argparse
import multiprocessing as mp
import sqlite3
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Tuple

import numpy as np

sys.path.insert(0, str(Path(__file__).parent.parent))

from holon import (
    DeterministicVectorManager,
    Encoder,
    LinearScale,
    OnlineSubspace,
    StripedSubspace,
    amplify,
    cosine_similarity,
    difference,
    grover_amplify,
    reject,
    resonance,
    similarity_profile,
)

DB_PATH = Path(__file__).parent.parent / "data" / "analysis.db"
SUPERVISED_YEARS = {2019, 2020}
RESOLUTION_CANDLES = 36
MIN_MOVE_PCT = 1.0

PRICE_CORE = ["open", "high", "low", "close", "sma20", "sma50", "sma200"]
PRICE_BB = ["bb_upper", "bb_lower"]
VOLUME = ["volume"]
RSI = ["rsi"]
MACD = ["macd_line", "macd_signal", "macd_hist"]
DMI = ["dmi_plus", "dmi_minus", "adx"]
ALL_FEATURES = PRICE_CORE + PRICE_BB + VOLUME + RSI + MACD + DMI

SCALE = 0.01


def log(msg: str):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def sf(v):
    return 0.0 if v is None else float(v)


def normalize_window(candles, idx, window_size):
    start = max(0, idx - window_size + 1)
    window = candles[start:idx + 1]
    if len(window) < window_size:
        window = [window[0]] * (window_size - len(window)) + list(window)

    price_feats = PRICE_CORE
    viewport_vals = []
    for c in window:
        for feat in price_feats:
            v = sf(c.get(feat))
            if v > 0:
                viewport_vals.append(v)

    vp_lo = min(viewport_vals) if viewport_vals else 0.0
    vp_hi = max(viewport_vals) if viewport_vals else 1.0
    vp_range = vp_hi - vp_lo if vp_hi - vp_lo > 1e-10 else 1.0
    margin = vp_range * 0.05
    vp_lo -= margin
    vp_hi += margin
    vp_range = vp_hi - vp_lo

    vol_vals = [sf(c.get("volume")) for c in window]
    v_lo, v_hi = min(vol_vals), max(vol_vals)
    v_range = v_hi - v_lo if v_hi - v_lo > 1e-10 else 1.0

    clamp = lambda v: max(0.0, min(1.0, v))

    macd_all = [sf(c.get(f)) for c in window for f in MACD]
    m_lo, m_hi = min(macd_all), max(macd_all)
    m_range = m_hi - m_lo if m_hi - m_lo > 1e-10 else 1.0

    normalized = []
    for c in window:
        entry = {}
        for feat in PRICE_CORE + PRICE_BB:
            entry[feat] = clamp((sf(c.get(feat)) - vp_lo) / vp_range)
        entry["volume"] = clamp((sf(c.get("volume")) - v_lo) / v_range)
        entry["rsi"] = clamp(sf(c.get("rsi")) / 100.0)
        for feat in MACD:
            entry[feat] = clamp((sf(c.get(feat)) - m_lo) / m_range)
        for feat in DMI:
            entry[feat] = clamp(sf(c.get(feat)) / 100.0)
        normalized.append(entry)
    return normalized


def build_holon_data(candles, idx, window_size):
    normalized = normalize_window(candles, idx, window_size)
    data = {}
    for t, entry in enumerate(normalized):
        data[f"t{t}"] = {
            "price": {
                "open": LinearScale(entry["open"], scale=SCALE),
                "high": LinearScale(entry["high"], scale=SCALE),
                "low": LinearScale(entry["low"], scale=SCALE),
                "close": LinearScale(entry["close"], scale=SCALE),
                "sma20": LinearScale(entry["sma20"], scale=SCALE),
                "sma50": LinearScale(entry["sma50"], scale=SCALE),
                "sma200": LinearScale(entry["sma200"], scale=SCALE),
                "bb_upper": LinearScale(entry["bb_upper"], scale=SCALE),
                "bb_lower": LinearScale(entry["bb_lower"], scale=SCALE),
            },
            "volume": LinearScale(entry["volume"], scale=SCALE),
            "rsi": LinearScale(entry["rsi"], scale=SCALE),
            "macd": {
                "line": LinearScale(entry["macd_line"], scale=SCALE),
                "signal": LinearScale(entry["macd_signal"], scale=SCALE),
                "hist": LinearScale(entry["macd_hist"], scale=SCALE),
            },
            "dmi": {
                "plus": LinearScale(entry["dmi_plus"], scale=SCALE),
                "minus": LinearScale(entry["dmi_minus"], scale=SCALE),
                "adx": LinearScale(entry["adx"], scale=SCALE),
            },
        }
    return data


# Module-level globals for multiprocessing COW
_g_candles = None
_g_window = None
_g_dim = None
_g_stripes = None
_g_encoder = None


def _worker_init():
    global _g_encoder
    _g_encoder = Encoder(DeterministicVectorManager(dimensions=_g_dim))


def _worker_encode(idx):
    data = build_holon_data(_g_candles, idx, _g_window)
    stripe_list = _g_encoder.encode_walkable_striped(data, _g_stripes)
    return idx, np.stack(stripe_list)


def compute_actual(candles, queue_idx):
    entry_price = sf(candles[queue_idx].get("close"))
    if entry_price <= 0:
        return "QUIET"
    target_up = entry_price * (1 + MIN_MOVE_PCT / 100)
    target_down = entry_price * (1 - MIN_MOVE_PCT / 100)
    first_buy = first_sell = -1
    end = min(queue_idx + 1 + RESOLUTION_CANDLES, len(candles))
    for j in range(queue_idx + 1, end):
        close_j = sf(candles[j].get("close"))
        if first_buy < 0 and close_j >= target_up:
            first_buy = j
        if first_sell < 0 and close_j <= target_down:
            first_sell = j
        if first_buy >= 0 and first_sell >= 0:
            break
    if first_buy >= 0 and (first_sell < 0 or first_buy <= first_sell):
        return "BUY"
    elif first_sell >= 0:
        return "SELL"
    return "QUIET"


# =========================================================================
# Strategy definitions
# =========================================================================

@dataclass
class StripeSignals:
    """Per-stripe discriminant vectors and midpoints for one strategy."""
    discriminants: List[np.ndarray]
    midpoints: List[np.ndarray]
    name: str


def build_strategies(
    buy_means: List[np.ndarray],
    sell_means: List[np.ndarray],
    n_stripes: int,
) -> Dict[str, StripeSignals]:
    strategies = {}

    # Strategy 1: Raw mean discriminant
    # d_s = buy_mean_s - sell_mean_s; midpoint = average
    discs, mids = [], []
    for s in range(n_stripes):
        d = buy_means[s] - sell_means[s]
        mid = (buy_means[s] + sell_means[s]) / 2.0
        discs.append(d)
        mids.append(mid)
    strategies["1_raw_disc"] = StripeSignals(discs, mids, "Raw mean discriminant")

    # Strategy 2: Reject shared structure
    # market_s = midpoint, buy_unique = reject(buy, [market]), etc.
    buy_uniques, sell_uniques = [], []
    discs2, mids2 = [], []
    for s in range(n_stripes):
        market = (buy_means[s] + sell_means[s]) / 2.0
        bu = reject(buy_means[s], [market])
        su = reject(sell_means[s], [market])
        d = bu - su
        mid = (bu + su) / 2.0
        buy_uniques.append(bu)
        sell_uniques.append(su)
        discs2.append(d)
        mids2.append(mid)
    strategies["2_reject"] = StripeSignals(discs2, mids2, "Reject shared structure")

    # Strategy 3: Difference + amplify
    # disc = difference(buy, sell), then amplify unique with disc
    discs3, mids3 = [], []
    for s in range(n_stripes):
        disc = difference(buy_means[s], sell_means[s])
        buy_ref = amplify(buy_uniques[s], disc, strength=2.0)
        sell_ref = amplify(sell_uniques[s], disc, strength=2.0)
        d = buy_ref - sell_ref
        mid = (buy_ref + sell_ref) / 2.0
        discs3.append(d)
        mids3.append(mid)
    strategies["3_diff_amp"] = StripeSignals(discs3, mids3, "Difference + amplify")

    # Strategy 4: Grover amplification
    # Amplify buy_unique against sell background, and vice versa
    discs4, mids4 = [], []
    for s in range(n_stripes):
        buy_sig = grover_amplify(buy_uniques[s], sell_means[s], iterations=2)
        sell_sig = grover_amplify(sell_uniques[s], buy_means[s], iterations=2)
        d = buy_sig - sell_sig
        mid = (buy_sig + sell_sig) / 2.0
        discs4.append(d)
        mids4.append(mid)
    strategies["4_grover"] = StripeSignals(discs4, mids4, "Grover amplification")

    # Strategy 5: Resonance filtering
    # Keep only dimensions where unique signal resonates with discriminant
    discs5, mids5 = [], []
    for s in range(n_stripes):
        disc = difference(buy_means[s], sell_means[s])
        buy_res = resonance(buy_uniques[s], disc)
        sell_res = resonance(sell_uniques[s], disc)
        d = buy_res - sell_res
        mid = (buy_res + sell_res) / 2.0
        discs5.append(d)
        mids5.append(mid)
    strategies["5_resonance"] = StripeSignals(discs5, mids5, "Resonance filtering")

    return strategies


def classify_one(
    stripe_vecs: List[np.ndarray],
    signals: StripeSignals,
) -> str:
    """Classify a single sample by projecting onto per-stripe discriminants."""
    score = 0.0
    for s, (vec, disc, mid) in enumerate(
        zip(stripe_vecs, signals.discriminants, signals.midpoints)
    ):
        disc_norm = np.linalg.norm(disc)
        if disc_norm < 1e-12:
            continue
        centered = vec.astype(np.float64) - mid
        score += np.dot(centered, disc) / disc_norm
    return "BUY" if score > 0 else "SELL"


def evaluate(
    indices: List[int],
    vec_cache: Dict[int, np.ndarray],
    labels: Dict[int, str],
    signals: StripeSignals,
    n_stripes: int,
) -> Tuple[int, int, int, int]:
    """Returns (correct, wrong, buy_correct, sell_correct)."""
    correct = wrong = buy_correct = sell_correct = 0
    for idx in indices:
        actual = labels.get(idx)
        if actual not in ("BUY", "SELL"):
            continue
        arr = vec_cache[idx]
        svecs = [arr[s] for s in range(n_stripes)]
        pred = classify_one(svecs, signals)
        if pred == actual:
            correct += 1
            if actual == "BUY":
                buy_correct += 1
            else:
                sell_correct += 1
        else:
            wrong += 1
    return correct, wrong, buy_correct, sell_correct


def per_year_eval(
    indices: List[int],
    vec_cache: Dict[int, np.ndarray],
    labels: Dict[int, str],
    candles: List[dict],
    signals: StripeSignals,
    n_stripes: int,
) -> Dict[int, Tuple[float, int]]:
    """Per-year accuracy breakdown. Returns {year: (accuracy, total)}."""
    by_year: Dict[int, List[int]] = {}
    for idx in indices:
        if labels.get(idx) not in ("BUY", "SELL"):
            continue
        year = candles[idx].get("year")
        by_year.setdefault(year, []).append(idx)

    results = {}
    for year in sorted(by_year.keys()):
        yidx = by_year[year]
        c, w, _, _ = evaluate(yidx, vec_cache, labels, signals, n_stripes)
        total = c + w
        acc = c / total * 100 if total > 0 else 0
        results[year] = (acc, total)
    return results


def discriminant_strength(
    buy_means: List[np.ndarray],
    sell_means: List[np.ndarray],
    signals: StripeSignals,
    n_stripes: int,
) -> List[float]:
    """Per-stripe discriminant strength (norm of discriminant)."""
    strengths = []
    for s in range(n_stripes):
        strengths.append(float(np.linalg.norm(signals.discriminants[s])))
    return strengths


# =========================================================================
# Feature attribution
# =========================================================================

def feature_attribution(
    indices: List[int],
    vec_cache: Dict[int, np.ndarray],
    labels: Dict[int, str],
    signals: StripeSignals,
    n_stripes: int,
    dim: int,
) -> np.ndarray:
    """Compute per-dimension importance across stripes.

    For the best strategy, identifies which dimensions in each stripe
    contribute most to the discriminant projection. Returns a
    (n_stripes, dim) array of per-dimension importance scores.
    """
    importance = np.zeros((n_stripes, dim), dtype=np.float64)
    for s in range(n_stripes):
        disc = signals.discriminants[s]
        disc_norm = np.linalg.norm(disc)
        if disc_norm < 1e-12:
            continue
        importance[s] = np.abs(disc / disc_norm)
    return importance


# =========================================================================
# Main
# =========================================================================

def main():
    global _g_candles, _g_window, _g_dim, _g_stripes

    parser = argparse.ArgumentParser(
        description="Algebra Refinement Classifier"
    )
    parser.add_argument("--cache", default=None,
                        help="Path to .npz encoded vector cache")
    parser.add_argument("--quick", type=int, default=None,
                        help="Quick mode: encode N supervised + N adaptive inline")
    parser.add_argument("--save-cache", type=str, default=None,
                        help="Save quick-encoded vectors to .npz for reuse")
    parser.add_argument("--label", default="label_oracle_10")
    parser.add_argument("--vol-threshold", type=float, default=0.002)
    parser.add_argument("--window", type=int, default=48)
    parser.add_argument("--dims", type=int, default=1024)
    parser.add_argument("--stripes", type=int, default=16)
    parser.add_argument("--k", type=int, default=20)
    parser.add_argument("--workers", type=int, default=mp.cpu_count())
    parser.add_argument("--attribution", action="store_true",
                        help="Run feature attribution on best strategy")
    args = parser.parse_args()

    if not args.cache and not args.quick:
        parser.error("Either --cache or --quick N is required")

    log("=" * 80)
    log("ALGEBRA REFINEMENT CLASSIFIER")
    if args.quick:
        log(f"  Mode: QUICK (inline encode {args.quick:,} per split)")
    else:
        log(f"  Mode: CACHED ({args.cache})")
    log("=" * 80)

    # ------------------------------------------------------------------
    # Load candle data from DB
    # ------------------------------------------------------------------
    conn = sqlite3.connect(str(DB_PATH))
    needed_cols = ["ts", "year", "close", args.label, "atr_r"]
    if args.quick:
        seen = set()
        for c in needed_cols + ALL_FEATURES + PRICE_BB:
            if c not in seen:
                seen.add(c)
        needed_cols = list(seen)
    cols = needed_cols
    all_rows = conn.execute(
        f"SELECT {', '.join(cols)} FROM candles ORDER BY ts"
    ).fetchall()
    conn.close()
    candles = [{cols[j]: r[j] for j in range(len(cols))} for r in all_rows]
    log(f"  {len(candles):,} candles from DB")

    # ------------------------------------------------------------------
    # Load or encode vectors
    # ------------------------------------------------------------------
    if args.cache:
        log(f"Loading cache: {args.cache}")
        t0 = time.time()
        cached = np.load(args.cache)
        cached_indices = cached["indices"]
        cached_vectors = cached["vectors"]
        vec_cache = {int(cached_indices[i]): cached_vectors[i]
                     for i in range(len(cached_indices))}
        n_stripes, dim = cached_vectors.shape[1], cached_vectors.shape[2]
        log(f"  {len(vec_cache):,} vectors, {n_stripes} stripes × {dim}D")
        log(f"  Loaded in {time.time() - t0:.1f}s")
    else:
        window_size = args.window
        dim = args.dims
        n_stripes = args.stripes
        leaves = window_size * len(ALL_FEATURES)
        per_stripe = leaves / n_stripes
        log(f"  Encoding: {n_stripes} stripes × {dim}D, "
            f"window={window_size}, ~{per_stripe:.0f} leaves/stripe")

        sup_all, adp_all = [], []
        for i in range(window_size - 1, len(candles)):
            atr_r = candles[i].get("atr_r") or 0
            if atr_r <= args.vol_threshold:
                continue
            year = candles[i].get("year")
            if year in SUPERVISED_YEARS:
                sup_all.append(i)
            else:
                adp_all.append(i)

        np.random.seed(42)
        n = args.quick
        sup_sample = sorted(np.random.choice(
            sup_all, size=min(n, len(sup_all)), replace=False
        ).tolist())
        adp_sample = sorted(np.random.choice(
            adp_all, size=min(n, len(adp_all)), replace=False
        ).tolist())
        all_to_encode = sup_sample + adp_sample
        log(f"  Quick sample: {len(sup_sample):,} supervised + "
            f"{len(adp_sample):,} adaptive = {len(all_to_encode):,}")

        _g_candles = candles
        _g_window = window_size
        _g_dim = dim
        _g_stripes = n_stripes

        log(f"  Encoding ({args.workers} workers) ...")
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
                    log(f"    {done:,}/{len(all_to_encode):,} ({rate:.0f}/s) "
                        f"ETA {remaining / rate / 60:.1f}min")

        vec_cache = dict(results)
        enc_elapsed = time.time() - t_enc
        log(f"  Encoded {len(vec_cache):,} vectors in {enc_elapsed:.1f}s "
            f"({len(vec_cache) / max(enc_elapsed, 0.01):.0f}/s)")

        if args.save_cache:
            indices_arr = np.array(sorted(vec_cache.keys()), dtype=np.int32)
            vectors_arr = np.stack([vec_cache[i] for i in indices_arr])
            np.savez(args.save_cache, indices=indices_arr, vectors=vectors_arr)
            log(f"  Saved cache: {args.save_cache} "
                f"({vectors_arr.nbytes / 1e6:.0f} MB)")

    # ------------------------------------------------------------------
    # Build labels (oracle for supervised, realized for all)
    # ------------------------------------------------------------------
    supervised_indices = []
    adaptive_indices = []
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
                actual = compute_actual(candles, idx)
                labels[idx] = actual
            supervised_indices.append(idx)
        else:
            actual = compute_actual(candles, idx)
            labels[idx] = actual
            adaptive_indices.append(idx)

    sup_buy = sum(1 for i in supervised_indices if labels.get(i) == "BUY")
    sup_sell = sum(1 for i in supervised_indices if labels.get(i) == "SELL")
    sup_quiet = sum(1 for i in supervised_indices if labels.get(i) == "QUIET")
    log(f"\nSupervised (2019-2020): {len(supervised_indices):,} "
        f"(BUY={sup_buy}, SELL={sup_sell}, QUIET={sup_quiet})")

    adp_buy = sum(1 for i in adaptive_indices if labels.get(i) == "BUY")
    adp_sell = sum(1 for i in adaptive_indices if labels.get(i) == "SELL")
    adp_quiet = sum(1 for i in adaptive_indices if labels.get(i) == "QUIET")
    log(f"Adaptive   (2021+):    {len(adaptive_indices):,} "
        f"(BUY={adp_buy}, SELL={adp_sell}, QUIET={adp_quiet})")

    # ------------------------------------------------------------------
    # Train BUY/SELL StripedSubspaces on 2019-2020
    # ------------------------------------------------------------------
    log(f"\n--- TRAINING SUBSPACES (K={args.k}) ---")
    t_train = time.time()

    buy_sub = StripedSubspace(dim=dim, k=args.k, n_stripes=n_stripes)
    sell_sub = StripedSubspace(dim=dim, k=args.k, n_stripes=n_stripes)

    buy_count = sell_count = 0
    for idx in supervised_indices:
        lbl = labels.get(idx)
        if lbl not in ("BUY", "SELL"):
            continue
        arr = vec_cache[idx]
        svecs = [arr[s] for s in range(n_stripes)]
        if lbl == "BUY":
            buy_sub.update(svecs)
            buy_count += 1
        else:
            sell_sub.update(svecs)
            sell_count += 1

    train_elapsed = time.time() - t_train
    log(f"  BUY:  {buy_count:,} samples trained")
    log(f"  SELL: {sell_count:,} samples trained")
    log(f"  Training took {train_elapsed:.1f}s")

    # ------------------------------------------------------------------
    # Extract per-stripe means
    # ------------------------------------------------------------------
    buy_means = [buy_sub._stripes[s].mean.copy() for s in range(n_stripes)]
    sell_means = [sell_sub._stripes[s].mean.copy() for s in range(n_stripes)]

    mean_cos = np.mean([
        cosine_similarity(buy_means[s], sell_means[s])
        for s in range(n_stripes)
    ])
    log(f"  Mean cosine(buy, sell) across stripes: {mean_cos:.4f}")

    # ------------------------------------------------------------------
    # Build and evaluate algebra strategies
    # ------------------------------------------------------------------
    log("\n--- ALGEBRA STRATEGIES ---")
    strategies = build_strategies(buy_means, sell_means, n_stripes)

    best_name = None
    best_oos_acc = -1.0

    for name, signals in sorted(strategies.items()):
        log(f"\n{'='*60}")
        log(f"Strategy: {signals.name} ({name})")
        log(f"{'='*60}")

        strengths = discriminant_strength(buy_means, sell_means, signals, n_stripes)
        log(f"  Disc. strength per stripe: "
            f"min={min(strengths):.2f}  max={max(strengths):.2f}  "
            f"mean={np.mean(strengths):.2f}")

        # In-sample (2019-2020)
        c, w, bc, sc = evaluate(
            supervised_indices, vec_cache, labels, signals, n_stripes
        )
        total = c + w
        acc = c / total * 100 if total > 0 else 0
        log(f"  IN-SAMPLE (2019-2020): {acc:.1f}% ({c}/{total})")
        if total > 0:
            buy_total = bc + (total - c - (total - bc - sc - w + bc + sc - c))
            log(f"    BUY correct: {bc}, SELL correct: {sc}")

        # OOS (2021+)
        c2, w2, bc2, sc2 = evaluate(
            adaptive_indices, vec_cache, labels, signals, n_stripes
        )
        total2 = c2 + w2
        acc2 = c2 / total2 * 100 if total2 > 0 else 0
        log(f"  OOS (2021+):           {acc2:.1f}% ({c2}/{total2})")
        log(f"    BUY correct: {bc2}, SELL correct: {sc2}")

        # Per-year breakdown
        all_indices = supervised_indices + adaptive_indices
        yearly = per_year_eval(
            all_indices, vec_cache, labels, candles, signals, n_stripes
        )
        log("  Per-year breakdown:")
        for year, (yacc, ytotal) in yearly.items():
            marker = " *" if year in SUPERVISED_YEARS else ""
            log(f"    {year}: {yacc:5.1f}% ({ytotal:,} trades){marker}")

        if acc2 > best_oos_acc:
            best_oos_acc = acc2
            best_name = name

    # ------------------------------------------------------------------
    # Summary
    # ------------------------------------------------------------------
    log(f"\n{'='*60}")
    log(f"BEST OOS: {best_name} — {strategies[best_name].name} "
        f"({best_oos_acc:.1f}%)")
    log(f"{'='*60}")

    # ------------------------------------------------------------------
    # Feature attribution (optional)
    # ------------------------------------------------------------------
    if args.attribution and best_name:
        log(f"\n--- FEATURE ATTRIBUTION ({best_name}) ---")
        best_signals = strategies[best_name]
        importance = feature_attribution(
            supervised_indices, vec_cache, labels,
            best_signals, n_stripes, dim
        )

        log("  Per-stripe discriminant energy:")
        stripe_energy = np.sum(importance, axis=1)
        ranked = np.argsort(-stripe_energy)
        for rank, s in enumerate(ranked):
            bar = "#" * int(stripe_energy[s] / stripe_energy.max() * 40)
            log(f"    Stripe {s:2d}: {stripe_energy[s]:.4f}  {bar}")

        top_k = 20
        log(f"\n  Top {top_k} dimensions by absolute discriminant weight:")
        flat_importance = importance.ravel()
        top_dims = np.argsort(-flat_importance)[:top_k]
        for rank, flat_idx in enumerate(top_dims):
            s_idx = flat_idx // dim
            d_idx = flat_idx % dim
            log(f"    #{rank+1}: stripe={s_idx}, dim={d_idx}, "
                f"weight={flat_importance[flat_idx]:.6f}")


if __name__ == "__main__":
    main()
